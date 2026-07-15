# EXPLAINED
Explanations of project concepts and parts created as a result of `/explain` skill invoking

## Cargo.toml
**Purpose**

This is the manifest file for a Rust project, read by `cargo` (Rust's build tool and package manager).

This particular project is a Language Server Protocol (LSP) server that wraps Google's `execute_query` binary (invoked with `--mode=parse`, per `src/parser.rs:55`) to turn GoogleSQL/BigQuery syntax errors into inline editor diagnostics.

**Section-by-section**

- **`[package]`** (lines 1–6) — identity metadata: name (`googlesql-lsp`), version, Rust edition (2021, a Rust-version-compatibility marker, not a package version), description, and license (Apache-2.0). None of this affects runtime behavior; it's informational and used if the crate is ever published.

- **`[[bin]]`** (lines 8–10) — tells `cargo` to build a binary target named `googlesql-lsp` from the entry point at `src/main.rs`. Rust projects can produce multiple binaries from one package; this declares just the one.

- **`[dependencies]`** (lines 12–18) — the external crates this project links against. Each was verified against actual usage in `src/`:
  - `tower-lsp = "0.20"` — implements the LSP protocol scaffolding (JSON-RPC framing, request/response types). `src/backend.rs` implements the `LanguageServer` trait it defines; `src/main.rs` wires up its `LspService`/`Server`.
  - `tokio` (with `macros`, `rt-multi-thread`, `io-std`, `time`) — the async runtime. `#[tokio::main]` in `src/main.rs:17` boots it; `io-std` lets it read/write LSP messages over stdin/stdout; `time` backs the debounce logic in `src/backend.rs:54` (delaying re-parses while the user is still typing); `rt-multi-thread` lets blocking work (spawning the `execute_query` subprocess) run off the async thread via `spawn_blocking` (`src/backend.rs:84`).
  - `dashmap = "5"` — a concurrent hash map, used in `src/backend.rs:8` to hold per-document state (e.g. open file contents) that multiple async tasks can touch without an explicit mutex.
  - `regex = "1"` — parses the `... [at L:C]` line/column suffix that `execute_query` prints on syntax errors (`src/diagnostics.rs:14`), so it can be turned into an LSP `Range`.
  - `once_cell = "1"` — used in `src/diagnostics.rs:13` to lazily compile that regex once and reuse it, instead of recompiling per call.
  - `dirs = "5"` — cross-platform lookup of the user's home directory, used in `src/parser.rs:8` to locate the `execute_query` binary at its default install path (`~/.local/share/googlesql-lsp/execute_query`).

- **`[profile.release]`** (lines 20–22) — build settings applied only to `cargo build --release`. `strip = true` strips debug symbols from the compiled binary, shrinking its size (irrelevant to `cargo build`/`cargo run` in debug mode).

**Non-obvious note**

The version constraints (e.g. `"1"`, `"0.20"`) are Cargo's default caret requirements — they allow any compatible semver-minor/patch update (e.g. `regex = "1"` accepts `1.x.y` but not `2.0.0`). Exact resolved versions are pinned separately in `Cargo.lock`.

## src/main.rs

**Purpose**

The binary's entry point. Its only job is wiring: start the async runtime, hook up stdin/stdout as the LSP (Language Server Protocol — the JSON-RPC protocol editors use to talk to language tooling) transport, and hand control to `Backend` (`src/backend.rs`), which implements the actual logic. It's ~15 lines of real code because everything project-specific lives elsewhere.

**Key pieces**

- **`mod backend; mod diagnostics; mod parser;`** (lines 10–12) — declares the crate's other source files as modules. Since `main.rs` is the crate root, every top-level module the binary uses must be declared here (or transitively inside one of these), even though `main` itself only directly calls into `backend`.
- **`use backend::Backend; use tower_lsp::{LspService, Server};`** (line 14–15) — `LspService` and `Server` are two separate layers from `tower-lsp`. `LspService` wraps `Backend` (which implements the `LanguageServer` trait — methods like `initialize`, `did_open`, `did_change`) into something that speaks JSON-RPC. `Server` is the transport: it owns the stdin/stdout byte streams and drives the read-request → dispatch → write-response loop, feeding messages into the `LspService`. They're split so either layer (protocol vs. transport) can be swapped independently — e.g. serving over TCP instead of stdio without touching `Backend`.
- **`#[tokio::main] async fn main()`** (lines 17–18) — `async fn` lets the function suspend at `.await` points instead of blocking a thread (needed here to read stdin, wait on debounce timers, and run subprocesses concurrently). But an `async fn main()` alone isn't runnable — something has to drive it to completion. `#[tokio::main]` is a procedural macro (compile-time code rewriting) from the `tokio` crate that expands roughly into a synchronous `main` which spins up a Tokio runtime and calls `.block_on(async { ... })` on the original body. This is the only place `tokio` is named in this file, but it's what makes every `.await` elsewhere in the crate actually execute.

**Flow**

1. `main` grabs `tokio::io::stdin()`/`stdout()` as the LSP transport — editors talk to this binary over these two streams rather than a network socket.
2. `LspService::new(Backend::new)` constructs a `Backend` (resolves the `execute_query` binary path, sets up empty document/version maps — see `backend.rs:31`) and wraps it as a JSON-RPC service, also returning a `socket` handle `Backend` uses to push notifications (like diagnostics) to the client independently of responding to a request.
3. `Server::new(stdin, stdout, socket).serve(service).await` runs the read-dispatch-write loop forever, routing incoming LSP messages to the matching `LanguageServer` trait method on `Backend` until the client disconnects.

**Non-obvious note**

There's no error handling here (no `Result`, no `.unwrap()`) — `serve().await` only returns once the connection closes, and per-request failures are expected to be handled inside `Backend`'s trait methods rather than crashing the process. The binary reads/writes over stdio rather than a network port, matching how most editors spawn a language server as a child process.

## zed-extension/src/lib.rs

**Purpose**

Entry point for a **Zed extension** — Zed (the code editor) supports third-party extensions compiled to WebAssembly (WASM) that plug into its editor via a defined API (the `zed_extension_api` crate). This extension's only job is to tell Zed how to launch the `googlesql-lsp` language server binary (the project's main crate) whenever Zed opens a SQL file. Per `zed-extension/extension.toml`, it deliberately doesn't define its own language/grammar — it attaches to Zed's built-in `SQL` language and only contributes the LSP (Language Server Protocol) integration, to avoid a `tree_sitter_sql` C-symbol collision with Zed's built-in SQL extension.

Per `zed-extension/Cargo.toml:8` (`crate-type = ["cdylib"]`), this crate compiles to a C-compatible dynamic library — for Zed extensions the target is `wasm32-wasi`, so the compiled artifact is a `.wasm` module Zed loads, not a native binary.

**Key pieces**

- **`GoogleSqlExtension`** (line 5) — a zero-field marker struct that exists purely to implement the `zed::Extension` trait; Zed's extension host needs some type to hold state across calls, but this extension is stateless.
- **`impl zed::Extension for GoogleSqlExtension`** (lines 7–33) — the trait Zed's extension host calls into:
  - **`new()`** (lines 8–10) — trivial constructor, called once when Zed instantiates the extension.
  - **`language_server_command(...)`** (lines 12–32) — called by Zed whenever it needs to start (or restart) the language server for a SQL file; must return a `Command` telling Zed what to execute.

**Flow**

1. Zed calls `worktree.which("googlesql-lsp")` (line 19) — searches `PATH` as seen from the worktree (a `Worktree` is Zed's handle to a project folder currently open in the editor — a "workspace root," unrelated to Git's own `git worktree` concept) for an executable named `googlesql-lsp`, rather than assuming a fixed install location. This assumes the user has already run `cargo install --path .` from the repo root, putting the binary on their normal `PATH`.
2. If not found, the extension fails fast with a descriptive error string (lines 20–22) telling the user exactly what to run.
3. If found, it returns a `Command` (lines 25–31) — a plain data struct describing how to spawn a subprocess (binary path, args, env vars; conceptually like `std::process::Command` but not directly executable by the extension itself, since WASM code can't spawn OS processes — it only describes the process and Zed's native host actually launches it) — with the resolved path, no arguments, and the worktree's shell environment attached.
4. Zed spawns that `Command` as a child process and speaks LSP to it over stdin/stdout — the rest of the protocol handling lives in the `googlesql-lsp` binary itself (`src/main.rs`, above), not in this extension.

**Non-obvious note**

`zed::register_extension!(GoogleSqlExtension);` (line 35) is a macro (compile-time code generation), not a runtime call into a central registry. It expands to the `extern "C"` exports Zed's WASM host looks for by name when it loads the compiled `.wasm` module. "Registration" happens implicitly at load time: Zed loads the module (per `extension.toml`'s `id = "googlesql"`), finds those macro-generated exports, and uses them to instantiate `GoogleSqlExtension` and call its trait methods — there's no separate registry file elsewhere in the repo.

## src/parser.rs

**Purpose**

The lowest layer: finds the `execute_query` binary on disk and shells out to it. This is the only file that knows anything about that external binary's invocation convention.

**Key pieces**

- **`find_binary()`** (lines 15–36) — implements the 3-tier lookup documented in the README's Configuration section: (1) the `$GOOGLESQL_EXECUTE_QUERY` env var, (2) the install script's default path (`~/.local/share/googlesql-lsp/execute_query`, via `default_install_path()`), (3) a `$PATH` scan for `execute_query` or `execute_query_macos`. Each tier is checked with `.is_file()` before being accepted, so a stale/misconfigured env var falls through to the next tier instead of failing outright. Returns `None` if nothing matches — callers (`Backend::new`, `src/backend.rs:36`) treat that as "the server runs but never produces diagnostics," not a fatal error.
- **`which(name)`** (lines 39–48) — a hand-rolled, minimal version of the Unix `which` command: splits `$PATH` on the OS-appropriate separator (`std::env::split_paths` handles `:` vs `;` per platform) and checks each directory for the named file. Inlined rather than pulled in as a dependency since it's only a few lines.
- **`run_parse(bin, sql)`** (lines 55–64) — spawns `execute_query --mode=parse <sql>` and returns stdout+stderr concatenated as one string.

**Non-obvious decisions**

- The SQL text is passed as `Command::new(bin).arg(...)` — a single argv element handed directly to the OS, not through a shell — so there's no shell-injection risk and no need to escape quotes/semicolons/etc. in the SQL itself.
- The doc comment on `run_parse` flags a real gotcha: `execute_query` exits with status 0 even when the SQL has a syntax error — it reports failures via text on stdout (an `ERROR: ...` line), not the process exit code. That's why `run_parse` returns the raw text and leaves error-detection entirely to `diagnostics.rs`, rather than checking `output.status`.
- Both stdout and stderr are captured and concatenated (lines 58–62) — defensive, in case a given build of the tool writes its error line to stderr instead of stdout.

## src/diagnostics.rs

**Purpose**

The translation layer: turns `execute_query`'s plain-text output into `Diagnostic` structs (LSP's data type for a single red-squiggle-and-message annotation) that `Backend` can hand to the editor.

**Key pieces**

- **`LOC_RE` / `PREFIX_RE`** (lines 18, 21) — two `Lazy<Regex>` statics (from `once_cell`, meaning the regex is compiled once on first use and reused after, rather than recompiled on every call). `LOC_RE` matches the trailing `[at <line>:<col>]` location; `PREFIX_RE` matches the leading `ERROR: ` plus an optional status code like `INVALID_ARGUMENT: `.
- **`parse_output(output, source)`** (lines 25–52) — the entry point, called from `Backend::compute_diagnostics` (`src/backend.rs:87`). Scans the tool's output line by line, and for every line starting with `ERROR:` (a successful parse produces AST dump lines instead, with no `ERROR:` prefix — see the module doc comment for a real example) it builds one `Diagnostic`. Multi-statement SQL (`SELECT 1; SELECT 2 FRM t;`) can produce one `ERROR:` line per failing statement, so this naturally yields multiple diagnostics.
- **`clean_message(line)`** (lines 56–59) — strips both the `ERROR: [CODE:] ` prefix and the `[at L:C]` suffix off a raw error line, leaving just the human-readable message (e.g. `Syntax error: Expected ";" ...`) to show the user.
- **`make_diagnostic(line, character, message, source)`** (lines 61–76) — builds the actual `Diagnostic`, converting the parser's 1-based line/column into LSP's 0-based `Position`. It extends the highlighted range to the end of that line (via `line_len_utf16`) rather than a single character, purely so the squiggle is visible in the editor — the parser only ever gives a single caret position, not a range.
- **`line_len_utf16(source, line)`** (lines 79–85) — LSP positions are specified in UTF-16 code units, not bytes or Unicode scalar values, per the LSP spec (editors historically used UTF-16 internally, e.g. VS Code/JavaScript strings). This computes a given line's length in that unit so the diagnostic's end position doesn't run past the actual line — relevant if the line contains non-ASCII characters, where UTF-16 length differs from byte length.

**Flow example**

Given `execute_query`'s output `ERROR: INVALID_ARGUMENT: Syntax error: Expected ";" ... [at 1:14]`, `parse_output` extracts line 1, column 14 → converts to 0-based `Position { line: 0, character: 13 }`, strips the prefix/suffix to get the message `Syntax error: Expected ";" ...`, and extends the range's end to the end of line 0 so VS Code/Zed draws a visible squiggle rather than a 1-character sliver.

**Non-obvious decision**

If a line starts with `ERROR:` but has no matching `[at L:C]` (line 46–48), the diagnostic is anchored at `(0, 0)` — the very start of the file — rather than being dropped, so the user still sees *something* went wrong even without a precise location. The module has thorough unit tests (lines 87–141) covering exactly this and the other edge cases (multi-statement input, non-ASCII-adjacent columns via UTF-16 length, missing location).

## src/backend.rs

**Purpose**

The orchestrator. Implements `tower-lsp`'s `LanguageServer` trait (the set of async methods a language server must handle — `initialize`, `did_open`, `did_change`, etc.) and owns all mutable state: which documents are open, their current text, and a debounce mechanism so a fresh parse isn't spawned on every keystroke.

**Key pieces**

- **`Backend` struct** (lines 20–28) — four fields, each `Arc`-wrapped (atomic reference-counted, so it can be cheaply cloned and shared across the `tokio::spawn`ed tasks below without copying the underlying data):
  - `client: Client` — `tower-lsp`'s handle back to the editor, used to send notifications like `publish_diagnostics` or log messages.
  - `documents: DashMap<Url, String>` — the concurrent hash map (from the `dashmap` crate — a `HashMap` that's safely mutable from multiple threads without an explicit external lock) holding each open file's latest full text.
  - `versions: DashMap<Url, Arc<AtomicU64>>` — a per-document edit counter, explained below under debouncing.
  - `binary: Arc<Option<PathBuf>>` — the `execute_query` path resolved once at startup via `parser::find_binary()` (line 36), or `None` if not found — checked at `initialized` (line 110) to warn the user, and again on every parse (line 78) to no-op instead of crashing.

- **`schedule_parse(uri)`** (lines 41–69) — the debounce logic, called after every `did_open`/`did_change`/`did_save`:
  1. It bumps a per-document `AtomicU64` counter (`versions`) and captures the *new* value as `ticket` (lines 43–47).
  2. It spawns a `tokio::task` (an async green-thread, not an OS thread) that sleeps 250ms (`DEBOUNCE`, line 18) — the constant chosen so a process isn't spawned on every keystroke, per the module doc comment.
  3. After waking, it re-checks the counter: if a *newer* edit bumped it past `ticket` while this task was asleep (line 57), this stale task just returns without doing anything — the newer task, sleeping in parallel, will do the real work when it wakes up. This is the actual debounce: many overlapping sleep-then-check tasks get spawned per burst of keystrokes, but only the very last one (whose ticket still matches when it wakes) survives to actually parse.
  4. If it's still current, it reads the latest document text (line 61 — note it re-reads from `documents`, not from a captured copy, so it always parses the current text even if `schedule_parse` was called with older text in between), runs `compute_diagnostics`, and pushes the result via `client.publish_diagnostics`.

- **`compute_diagnostics(binary, text)`** (lines 73–90) — the async bridge between LSP-land and the blocking subprocess call. Empty/whitespace-only text short-circuits to no diagnostics (line 74) and a missing binary short-circuits too (line 78–81, matching the `None` case from `find_binary()`). Otherwise it calls `parser::run_parse` inside `tokio::task::spawn_blocking` (line 84) — necessary because `run_parse` uses the blocking `std::process::Command::output()`, which would otherwise stall the whole async runtime's worker thread while waiting on the subprocess; `spawn_blocking` moves it to a dedicated thread pool for blocking work instead.

- **`impl LanguageServer for Backend`** (lines 92–161) — the trait methods `tower-lsp` dispatches into per the LSP spec:
  - `initialize` — declares capabilities; notably `TextDocumentSyncKind::FULL` (line 98), meaning the client sends the *entire* document text on every change rather than incremental diffs — simpler to implement, at the cost of more bytes over the wire (fine for typical SQL file sizes).
  - `initialized` — fires once after the handshake completes; used here purely to log/warn about whether the parser binary was found (lines 109–129), not to do any protocol work.
  - `did_open`/`did_change`/`did_save` — each stores the latest text (open/change) and calls `schedule_parse`. Note `did_change` (line 137–144) takes `.last()` of `content_changes` — safe specifically *because* sync mode is `FULL`, so there's exactly one change event carrying the whole new text; this would be wrong under incremental sync.
  - `did_close` — removes the document from both maps and explicitly publishes an empty diagnostics list (line 155) so stale red squiggles don't linger in the editor's UI after the file is closed (LSP diagnostics are "sticky" until explicitly cleared or replaced).
  - `shutdown` — a required trait method; there's nothing to clean up so it's a no-op `Ok(())`.

**Non-obvious decisions**

- The debounce is implemented without any cancellation API (no `AbortHandle`) — every scheduled task always runs to completion (including its full 250ms sleep), and staleness is detected cooperatively by comparing counters afterward, rather than actually cancelling the sleeping task. Simpler than wiring up cancellation, at the cost of harmless sleeping tasks accumulating during a fast typing burst.
- All shared state is `Arc`+`DashMap`/`AtomicU64` rather than behind a single `Mutex` — this lets concurrent `tokio::spawn`ed tasks for *different* documents proceed without contending on each other's locks; `dashmap` internally shards its locking per key rather than being a single map-wide lock.

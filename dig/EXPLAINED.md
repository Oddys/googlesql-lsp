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

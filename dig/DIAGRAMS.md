# DIAGRAMS
Diagrams of project structure and behavior created as a result of `/draw` skill invoking

## [`diagrams/editor-lsp-sequence.html`](diagrams/editor-lsp-sequence.html) — Editor ⇄ googlesql-lsp sequence diagram

An interactive sequence diagram tracing every method on `impl LanguageServer for Backend` (`src/backend.rs`), from the `initialize`/`initialized` handshake through the debounced edit → parse → `publishDiagnostics` cycle, save, close, and shutdown.

Key behavior it makes explicit:
- **Debounce**: `did_open`/`did_change` each call `schedule_parse`, which bumps a per-document ticket counter and sleeps 250ms (`backend.rs:18,41-69`) before parsing; a superseded ticket exits silently instead of running, so only the last edit in a burst triggers a parse.
- **Subprocess call**: the actual parse runs on `spawn_blocking` and shells out to `execute_query --mode=parse "<sql>"` (`parser.rs:55-63`), which exits 0 even on a syntax error — the caller must inspect stdout text, not the exit code.
- **Close** clears diagnostics by publishing an empty list, rather than leaving stale squiggles on a closed file.

## [`diagrams/internal-components-sequence.html`](diagrams/internal-components-sequence.html) — Internal call-graph sequence diagram (LspService, Server, Backend, parser, diagnostics)

Traces the actual Rust call graph inside the binary — how a decoded stdin message turns into a call on `Backend`, and how a diagnostic gets back out.

Covers construction (`LspService::new(Backend::new)` → `Backend::new` → `parser::find_binary()`), the `initialize` request/response path through `LspService`'s method router, a `did_change` notification (which returns `()` so `LspService` yields no response), and the background debounced-parse task (`compute_diagnostics` → `parser::run_parse` → `diagnostics::parse_output`).

Verified directly against the vendored `tower-lsp 0.20.0` source (`~/.cargo/registry/.../tower-lsp-0.20.0/src/{service,transport,service/client}.rs`), not assumed from the LSP spec. Two non-obvious facts it surfaces:
- `Backend`'s `client.publish_diagnostics(...)` call goes out through the `ClientSocket` loopback straight into `Server`'s write loop (`transport.rs`'s `print_output`) — it never re-enters `LspService`'s router. Drawn as a curved arrow that visibly arcs over the `LspService` lane, vs. straight arrows for calls that actually route through it.
- The debounced background task doesn't always reach the parser: `compute_diagnostics` (`backend.rs:73-90`) early-returns `Vec::new()` before calling `parser::run_parse` if the document text is blank or the `execute_query` binary was never found — and separately, `schedule_parse`'s per-document ticket counter (`backend.rs:57-59`) makes a superseded task return before it even gets that far, so only the last edit in a debounce burst does any work.

## [`diagrams/zed-extension-registration-sequence.html`](diagrams/zed-extension-registration-sequence.html) — Zed ⇄ googlesql extension: registration and low-level interaction

Traces how Zed loads this repo's `zed-extension` and later calls into it, across the WASM component-model boundary — not just the LSP-visible surface. Phase 1 covers extension discovery and language-server registration at Zed startup (`extension.toml` parsing → compiling `extension.wasm` → registering the `googlesql` adapter for the `SQL` language). Phase 2 traces one `language_server_command` call end to end, including the guest→host callbacks the extension makes to resolve the `googlesql-lsp` binary's path and environment.

Five lanes: `ExtensionStore`, `ExtensionLspAdapter`, `WasmHost`, a dedicated extension task, and the WASM guest (`zed-extension/src/lib.rs`, this repo's only lane not dashed). Grounded against `zed-industries/zed` fetched live from GitHub (commit `65e1c5af258d4c80036467d583691f3f9ded0897`, 2026-07-11) plus `zed_extension_api` 0.7.0's published source (the version this repo's `Cargo.lock` actually pins).

Non-obvious behavior it surfaces:
- **Version-gated WASM ABI**: `parse_wasm_extension_version` (`wasm_host.rs:807-844`) reads a custom wasm section literally named `zed:api-version` — 6 raw bytes, three big-endian `u16`s — to pick which WIT compatibility shim to instantiate against. For this repo's pinned `zed_extension_api = 0.7.0`, that's the `since_v0_6_0` shim (Zed has since added a newer `since_v0_8_0` shim above it, but 0.7.0 still falls in `since_v0_6_0`'s range) (`wit.rs:94-134`).
- **`call_init_extension` runs before the message loop exists**: unlike every later call into the extension, extension init is a direct call on `WasmHost`'s own async task — the dedicated `extension_task` (needed because a wasmtime `Store` isn't `Sync`) is only spawned right after (`wasm_host.rs:686-717`).
- **`language_name` is threaded almost all the way across the ABI, then dropped at the last step**: it flows as a real parameter from `extension_lsp_adapter.rs:173-176` through `wasm_host.rs:88-101` into `wit.rs`'s `call_language_server_command` dispatcher signature (`wit.rs:225-231`) — but every version-dispatch match arm for versions ≥0.1.0, including the `V0_6_0` arm this repo's 0.7.0 extension actually uses, calls the generated WIT binding with only the language-server ID and a worktree resource handle, silently discarding it (`wit.rs:232-264`). Only the legacy pre-0.1 arms still forward it, via a `LanguageServerConfig` struct (`wit.rs:265-284`). `language_server_command` in `zed-extension/src/lib.rs` therefore only ever receives the language-server ID and a worktree handle.
- **Guest→host callbacks are inline, not channel hops**: `worktree.which(...)` and `worktree.shell_env()` (`lib.rs:19,30`) are WIT imports resolved synchronously within the same task that's running the guest call, not routed back through the mpsc channel used to dispatch the call itself — drawn as curved loopback arrows to distinguish them from the mpsc-mediated hops.

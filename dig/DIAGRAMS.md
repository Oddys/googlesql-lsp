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

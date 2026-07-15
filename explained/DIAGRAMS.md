# DIAGRAMS
Diagrams of project structure and behavior created as a result of `/draw` skill invoking

## [`diagrams/editor-lsp-sequence.html`](diagrams/editor-lsp-sequence.html) — Editor ⇄ googlesql-lsp sequence diagram

Every method on `impl LanguageServer for Backend`, from the initialize handshake through the debounced edit → parse → publishDiagnostics cycle, save, close, and shutdown.

## [`diagrams/internal-components-sequence.html`](diagrams/internal-components-sequence.html) — Internal call-graph sequence diagram

The Rust call graph inside the binary (LspService, Server, Backend, parser, diagnostics): how a decoded stdin message turns into a call on `Backend` and how a diagnostic gets back out.

## [`diagrams/zed-extension-registration-sequence.html`](diagrams/zed-extension-registration-sequence.html) — Zed ⇄ googlesql extension registration & interaction

How Zed loads the `zed-extension` and calls into it across the WASM boundary: startup registration of the language server, then one `language_server_command` call end to end.

## [`diagrams/publishing-flow.html`](diagrams/publishing-flow.html) — Publishing / installed-state flow

Proposed distribution of the extension via the Zed extension registry: how it would reach a user from GitHub once it fetches its own server and parser (not current code).

//! GoogleSQL LSP server.
//!
//! A thin Language Server that wraps Google's official GoogleSQL parser. It shells
//! out to the prebuilt `execute_query --mode=parse` binary, scrapes the syntax-error
//! location from its output, and reports it back to the editor as LSP diagnostics.
//!
//! See `parser.rs` for how the backend binary is located/invoked and `diagnostics.rs`
//! for how its textual error output is turned into structured diagnostics.

mod backend;
mod diagnostics;
mod parser;

use backend::Backend;
use tower_lsp::{LspService, Server};

#[tokio::main]
async fn main() {
    let stdin = tokio::io::stdin();
    let stdout = tokio::io::stdout();

    let (service, socket) = LspService::new(Backend::new);
    Server::new(stdin, stdout, socket).serve(service).await;
}

//! The LSP `Backend`: document store, debounced re-parsing, and diagnostic publishing.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use dashmap::DashMap;
use tower_lsp::jsonrpc::Result;
use tower_lsp::lsp_types::*;
use tower_lsp::{Client, LanguageServer};

use crate::diagnostics::parse_output;
use crate::parser;

/// Delay after the last edit before we re-run the parser, to avoid spawning a process
/// on every keystroke.
const DEBOUNCE: Duration = Duration::from_millis(250);

pub struct Backend {
    client: Client,
    /// Latest full text of each open document.
    documents: Arc<DashMap<Url, String>>,
    /// Per-document edit counter; a scheduled parse runs only if it's still the latest.
    versions: Arc<DashMap<Url, Arc<AtomicU64>>>,
    /// Resolved `execute_query` binary, or `None` if it couldn't be found.
    binary: Arc<Option<PathBuf>>,
}

impl Backend {
    pub fn new(client: Client) -> Self {
        Backend {
            client,
            documents: Arc::new(DashMap::new()),
            versions: Arc::new(DashMap::new()),
            binary: Arc::new(parser::find_binary()),
        }
    }

    /// Schedule a debounced parse for `uri`. Later edits supersede earlier scheduled runs.
    fn schedule_parse(&self, uri: Url) {
        let version = self
            .versions
            .entry(uri.clone())
            .or_insert_with(|| Arc::new(AtomicU64::new(0)))
            .clone();
        let ticket = version.fetch_add(1, Ordering::SeqCst) + 1;

        let documents = self.documents.clone();
        let client = self.client.clone();
        let binary = self.binary.clone();

        tokio::spawn(async move {
            tokio::time::sleep(DEBOUNCE).await;

            // A newer edit came in during the debounce window; let its task handle it.
            if version.load(Ordering::SeqCst) != ticket {
                return;
            }

            let text = match documents.get(&uri) {
                Some(entry) => entry.clone(),
                None => return, // document was closed
            };

            let diagnostics = compute_diagnostics(&binary, text).await;
            client.publish_diagnostics(uri, diagnostics, None).await;
        });
    }
}

/// Run the parser (on a blocking thread) and convert its output to diagnostics.
async fn compute_diagnostics(binary: &Arc<Option<PathBuf>>, text: String) -> Vec<Diagnostic> {
    if text.trim().is_empty() {
        return Vec::new();
    }

    let bin = match binary.as_ref() {
        Some(b) => b.clone(),
        None => return Vec::new(),
    };

    let source = text.clone();
    let parsed = tokio::task::spawn_blocking(move || parser::run_parse(&bin, &text)).await;

    match parsed {
        Ok(Ok(output)) => parse_output(&output, &source),
        _ => Vec::new(),
    }
}

#[tower_lsp::async_trait]
impl LanguageServer for Backend {
    async fn initialize(&self, _: InitializeParams) -> Result<InitializeResult> {
        Ok(InitializeResult {
            capabilities: ServerCapabilities {
                text_document_sync: Some(TextDocumentSyncCapability::Kind(
                    TextDocumentSyncKind::FULL,
                )),
                ..Default::default()
            },
            server_info: Some(ServerInfo {
                name: "googlesql".to_string(),
                version: Some(env!("CARGO_PKG_VERSION").to_string()),
            }),
        })
    }

    async fn initialized(&self, _: InitializedParams) {
        match self.binary.as_ref() {
            Some(path) => {
                self.client
                    .log_message(
                        MessageType::INFO,
                        format!("googlesql-lsp: using parser binary at {}", path.display()),
                    )
                    .await;
            }
            None => {
                self.client
                    .show_message(
                        MessageType::ERROR,
                        "googlesql-lsp: could not find the `execute_query` binary. \
                         Run scripts/install-parser.sh or set $GOOGLESQL_EXECUTE_QUERY.",
                    )
                    .await;
            }
        }
    }

    async fn did_open(&self, params: DidOpenTextDocumentParams) {
        let uri = params.text_document.uri;
        self.documents.insert(uri.clone(), params.text_document.text);
        self.schedule_parse(uri);
    }

    async fn did_change(&self, params: DidChangeTextDocumentParams) {
        let uri = params.text_document.uri;
        // FULL sync: the last change carries the entire new document text.
        if let Some(change) = params.content_changes.into_iter().last() {
            self.documents.insert(uri.clone(), change.text);
        }
        self.schedule_parse(uri);
    }

    async fn did_save(&self, params: DidSaveTextDocumentParams) {
        self.schedule_parse(params.text_document.uri);
    }

    async fn did_close(&self, params: DidCloseTextDocumentParams) {
        let uri = params.text_document.uri;
        self.documents.remove(&uri);
        self.versions.remove(&uri);
        // Clear any diagnostics we published for the now-closed document.
        self.client.publish_diagnostics(uri, Vec::new(), None).await;
    }

    async fn shutdown(&self) -> Result<()> {
        Ok(())
    }
}

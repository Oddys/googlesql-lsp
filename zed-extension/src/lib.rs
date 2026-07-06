//! Zed extension that launches the `googlesql-lsp` language server for GoogleSQL files.

use zed_extension_api::{self as zed, Command, LanguageServerId, Result, Worktree};

struct GoogleSqlExtension;

impl zed::Extension for GoogleSqlExtension {
    fn new() -> Self {
        GoogleSqlExtension
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<Command> {
        // The server is a normal binary the user installs (e.g. `cargo install --path .`).
        // We resolve it on the worktree's PATH.
        let path = worktree.which("googlesql-lsp").ok_or_else(|| {
            "could not find `googlesql-lsp` on PATH. Build and install it with \
             `cargo install --path .` from the repository root, then restart Zed."
                .to_string()
        })?;

        Ok(Command {
            command: path,
            args: Vec::new(),
            // Propagate the user's shell environment so the server can locate the
            // execute_query binary via PATH if it isn't at the default install path.
            env: worktree.shell_env(),
        })
    }
}

zed::register_extension!(GoogleSqlExtension);

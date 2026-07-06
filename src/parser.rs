//! Locating and invoking the GoogleSQL `execute_query` binary in parse mode.

use std::path::PathBuf;
use std::process::Command;

/// Where `scripts/install-parser.sh` installs the binary by default.
fn default_install_path() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".local/share/googlesql-lsp/execute_query"))
}

/// Locate the `execute_query` binary. First match wins:
/// 1. `$GOOGLESQL_EXECUTE_QUERY`
/// 2. `~/.local/share/googlesql-lsp/execute_query` (the install script's target)
/// 3. `execute_query` / `execute_query_macos` on `$PATH`
pub fn find_binary() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("GOOGLESQL_EXECUTE_QUERY") {
        let pb = PathBuf::from(p);
        if pb.is_file() {
            return Some(pb);
        }
    }

    if let Some(pb) = default_install_path() {
        if pb.is_file() {
            return Some(pb);
        }
    }

    for name in ["execute_query", "execute_query_macos"] {
        if let Some(pb) = which(name) {
            return Some(pb);
        }
    }

    None
}

/// Minimal `$PATH` lookup (avoids pulling in the `which` crate).
fn which(name: &str) -> Option<PathBuf> {
    let paths = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&paths) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Run `execute_query --mode=parse <sql>` and return its combined stdout+stderr.
///
/// The tool prints parse errors to stdout with an `... [at L:C]` suffix and — notably —
/// exits 0 even on a syntax error, so callers must inspect the text, not the exit code.
/// The SQL is passed as a single argv element (no shell), so no quoting/escaping is needed.
pub fn run_parse(bin: &PathBuf, sql: &str) -> std::io::Result<String> {
    let output = Command::new(bin).arg("--mode=parse").arg(sql).output()?;

    let mut combined = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !stderr.is_empty() {
        combined.push_str(&stderr);
    }
    Ok(combined)
}

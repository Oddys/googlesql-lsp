//! Turning `execute_query --mode=parse` textual output into LSP diagnostics.
//!
//! Real output for a syntax error looks like:
//! ```text
//! ERROR: INVALID_ARGUMENT: Syntax error: Expected ";" or end of input but got identifier "t" [at 1:14]
//! SELECT 1 FRM t
//!              ^
//! ```
//! Successful parses print an AST (no `ERROR:` lines). Positions are 1-based and
//! absolute within the whole buffer; multi-statement input yields one `ERROR:` line
//! per failing statement, so we emit a diagnostic for each.

use once_cell::sync::Lazy;
use regex::Regex;
use tower_lsp::lsp_types::{Diagnostic, DiagnosticSeverity, Position, Range};

/// Trailing `[at <line>:<column>]` location (1-based).
static LOC_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\[at (\d+):(\d+)\]").unwrap());

/// Leading `ERROR: ` plus an optional uppercase status code like `INVALID_ARGUMENT: `.
static PREFIX_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^ERROR:\s+(?:[A-Z_]+:\s+)?").unwrap());

/// Parse the tool's output into diagnostics, using `source` (the document text) to size
/// each diagnostic's range to the offending line.
pub fn parse_output(output: &str, source: &str) -> Vec<Diagnostic> {
    let mut diagnostics = Vec::new();

    for line in output.lines() {
        if !line.starts_with("ERROR:") {
            continue;
        }

        let message = clean_message(line);

        match LOC_RE.captures(line) {
            Some(caps) => {
                let line_1 = caps[1].parse::<u32>().unwrap_or(1);
                let col_1 = caps[2].parse::<u32>().unwrap_or(1);
                diagnostics.push(make_diagnostic(
                    line_1.saturating_sub(1),
                    col_1.saturating_sub(1),
                    message,
                    source,
                ));
            }
            // Error with no parseable location — anchor it at the start of the file.
            None => diagnostics.push(make_diagnostic(0, 0, message, source)),
        }
    }

    diagnostics
}

/// Strip the `ERROR: [CODE:] ` prefix and the trailing ` [at L:C]` suffix, leaving the
/// human-readable message (typically `Syntax error: ...`).
fn clean_message(line: &str) -> String {
    let without_prefix = PREFIX_RE.replace(line, "");
    LOC_RE.replace(&without_prefix, "").trim().to_string()
}

fn make_diagnostic(line: u32, character: u32, message: String, source: &str) -> Diagnostic {
    // Extend the squiggle to end-of-line so it's visible even though the parser only
    // gives us a single caret position.
    let end_character = line_len_utf16(source, line).max(character + 1);

    Diagnostic {
        range: Range {
            start: Position { line, character },
            end: Position { line, character: end_character },
        },
        severity: Some(DiagnosticSeverity::ERROR),
        source: Some("googlesql".to_string()),
        message,
        ..Default::default()
    }
}

/// Length of a 0-based line, in UTF-16 code units (LSP's column unit).
fn line_len_utf16(source: &str, line: u32) -> u32 {
    source
        .lines()
        .nth(line as usize)
        .map(|l| l.encode_utf16().count() as u32)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrapes_single_error() {
        let out = "ERROR: INVALID_ARGUMENT: Syntax error: Expected \";\" or end of input but got identifier \"t\" [at 1:14]\nSELECT 1 FRM t\n             ^\n";
        let src = "SELECT 1 FRM t";
        let diags = parse_output(out, src);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].range.start.line, 0);
        assert_eq!(diags[0].range.start.character, 13);
        assert_eq!(diags[0].severity, Some(DiagnosticSeverity::ERROR));
        assert!(diags[0].message.starts_with("Syntax error:"));
        assert!(!diags[0].message.contains("[at "));
        assert!(!diags[0].message.contains("INVALID_ARGUMENT"));
    }

    #[test]
    fn no_error_for_valid_ast_output() {
        let out = "QueryStatement [0-8]\n  Query [0-8]\n    Select [0-8]\n";
        assert!(parse_output(out, "SELECT 1").is_empty());
    }

    #[test]
    fn handles_multiline_position() {
        let out = "ERROR: INVALID_ARGUMENT: Syntax error: Unexpected keyword WHERE [at 3:6]\nFROM WHERE x\n     ^\n";
        let src = "SELECT a,\n  b\nFROM WHERE x";
        let diags = parse_output(out, src);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].range.start.line, 2);
        assert_eq!(diags[0].range.start.character, 5);
        // End extends to the end of line 2 ("FROM WHERE x" == 12 chars).
        assert_eq!(diags[0].range.end.character, 12);
    }

    #[test]
    fn multiple_errors_across_statements() {
        let out = "QueryStatement [0-8]\nERROR: INVALID_ARGUMENT: Syntax error: Expected end of input [at 1:24]\nSELECT 1; SELECT 2 FRM t;\n                       ^\n";
        let src = "SELECT 1; SELECT 2 FRM t;";
        let diags = parse_output(out, src);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].range.start.line, 0);
        assert_eq!(diags[0].range.start.character, 23);
    }

    #[test]
    fn error_without_location_anchors_at_origin() {
        let out = "ERROR: INTERNAL: something went wrong\n";
        let diags = parse_output(out, "SELECT 1");
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].range.start, Position { line: 0, character: 0 });
        assert_eq!(diags[0].message, "something went wrong");
    }
}

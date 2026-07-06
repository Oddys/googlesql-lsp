#!/usr/bin/env bash
#
# Exercises the parser backend directly (no LSP, no editor) so you can confirm the
# `execute_query --mode=parse` output format the diagnostics scraper depends on.

set -uo pipefail

BIN="${GOOGLESQL_EXECUTE_QUERY:-$HOME/.local/share/googlesql-lsp/execute_query}"

if [ ! -x "$BIN" ]; then
    echo "Parser binary not found at: $BIN" >&2
    echo "Run scripts/install-parser.sh first (or set \$GOOGLESQL_EXECUTE_QUERY)." >&2
    exit 1
fi

run() {
    echo "===== $1 ====="
    echo "SQL: $2"
    echo "--- output ---"
    "$BIN" --mode=parse "$2"
    echo "--- exit=$? (note: always 0, even on error — scrape the text) ---"
    echo
}

run "valid query"        "SELECT 1"
run "typo (FRM)"         "SELECT 1 FRM t"
run "multi-statement"    "SELECT 1; SELECT 2 FRM t;"
run "multiline error"    $'SELECT a,\n  b\nFROM WHERE x'

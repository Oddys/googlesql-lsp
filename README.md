# googlesql-lsp

A Language Server + Zed extension that gives **live syntax-error highlighting for
BigQuery / GoogleSQL** files, using Google's *actual*
[GoogleSQL parser](https://github.com/google/googlesql) — so the errors match what
BigQuery itself reports, not an approximate third-party grammar.

It works by wrapping the prebuilt `execute_query` binary from the GoogleSQL release in
`--mode=parse` mode (which runs *only* the parser), scraping the error location, and
surfacing it to the editor as LSP diagnostics. **No C++/Bazel build and no Docker required.**

```
Zed ──stdio LSP──▶ googlesql-lsp ──▶ execute_query --mode=parse ──▶ "... [at L:C]"
        ▲                                                                  │
        └──────────────── red squiggle at line:col ◀──────────────────────┘
```

## Components

| Path | What it is |
| --- | --- |
| `src/` | The `googlesql-lsp` language server (Rust, [`tower-lsp`](https://crates.io/crates/tower-lsp)). |
| `zed-extension/` | The Zed extension (Rust → WASM) that registers the `GoogleSQL` language and launches the server. |
| `scripts/install-parser.sh` | Downloads the prebuilt `execute_query` binary. |
| `scripts/smoke-test.sh` | Runs the parser on sample SQL so you can see the raw output. |

## Install

### 1. Get the GoogleSQL parser binary

```bash
./scripts/install-parser.sh
```

Downloads `execute_query` for your OS (macOS/Linux) from release `2026.01.1` into
`~/.local/share/googlesql-lsp/execute_query`, clears the macOS quarantine flag, and
verifies it runs.

> On macOS the binary is unsigned; the script removes the Gatekeeper quarantine
> attribute. If macOS still blocks it, allow it once under
> **System Settings → Privacy & Security**.

### 2. Build & install the language server

```bash
cargo install --path .
```

Puts `googlesql-lsp` on your `PATH` (in `~/.cargo/bin`). The Zed extension finds it there.

### 3. Install the Zed extension

In Zed, open the command palette and run **`zed: install dev extension`**, then select
the `zed-extension/` directory in this repo. Zed compiles the WASM extension and loads it.

Open any `.sql` file and type an error (e.g. `SELECT 1 FRM t`) — you'll get a red squiggle
with GoogleSQL's message at the exact column. Fix it and the squiggle clears.

## Configuration

The server locates the parser binary in this order:

1. `$GOOGLESQL_EXECUTE_QUERY` (absolute path to the binary)
2. `~/.local/share/googlesql-lsp/execute_query` (install script's default)
3. `execute_query` / `execute_query_macos` on `$PATH`

## Testing

```bash
cargo test              # unit tests for the diagnostic scraper
./scripts/smoke-test.sh # see the parser's raw output on sample SQL
```

## File associations

The extension claims `.sql`, `.bqsql`, and `.googlesql`. If you have another SQL extension
that also claims `.sql`, either use `.bqsql`/`.googlesql`, or add a
[file association](https://zed.dev/docs/configuring-zed#file-types) in your Zed settings:

```json
"file_types": { "GoogleSQL": ["*.sql"] }
```

## Limitations

- **Syntax errors only.** The parser catches malformed SQL (bad keywords, unbalanced
  clauses, unexpected tokens). It does **not** catch semantic errors like unknown
  tables/columns, type mismatches, or bad function signatures — those require the
  GoogleSQL *analyzer* plus a schema catalog, which is out of scope here.
- Diagnostics update ~250 ms after you stop typing (debounced), each parse spawns the
  `execute_query` process once.
- Columns are reported in the parser's units; non-ASCII characters before an error on the
  same line may shift the highlight by a few columns.
- Depends on the prebuilt release binary (macOS/Linux). No Windows binary is published.

## Why wrap the binary instead of compiling the parser

GoogleSQL is a large Bazel/C++ project with only "experimental" macOS build support.
But each release ships a prebuilt native `execute_query` binary whose `--mode=parse`
exposes exactly the parser we need — so we wrap that instead of compiling the parser
ourselves. This keeps the whole thing build-free and Docker-free while still using
Google's real parser.

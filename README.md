# googlesql-lsp

A Language Server + Zed extension that gives **live syntax-error highlighting for
BigQuery / GoogleSQL** files, using Google's *actual*
[GoogleSQL parser](https://github.com/google/googlesql) — so the errors match what
BigQuery itself reports, not an approximate third-party grammar.

It works by wrapping GoogleSQL's `execute_query` tool in `--mode=parse` mode (which runs
*only* the parser), scraping the error location, and surfacing it to the editor as LSP
diagnostics. **No C++/Bazel build required** — the server provisions the parser itself by
downloading the GoogleSQL release's Docker image on first run, so the only prerequisite is
a running Docker daemon.

```
Zed ─stdio LSP─▶ googlesql-lsp ─docker exec─▶ execute_query --mode=parse ─▶ "... [at L:C]"
        ▲                                                                        │
        └──────────────────── red squiggle at line:col ◀────────────────────────┘
```

## Components

| Path | What it is |
| --- | --- |
| `src/` | The `googlesql-lsp` language server (Rust, [`tower-lsp`](https://crates.io/crates/tower-lsp)). |
| `zed-extension/` | The Zed extension (Rust → WASM) that attaches the server to Zed's `SQL` language. |
| `scripts/install-parser.sh` | Installs the `execute_query` parser — the prebuilt native binary, or (with `--docker`) a container wrapper. |
| `scripts/smoke-test.sh` | Runs the parser on sample SQL so you can see the raw output. |

## Install

### 1. Install Docker

The only prerequisite is **Docker** (or a Docker-compatible CLI like Podman) with a running
daemon. The server provisions the parser itself — there's no separate install step and no
host `execute_query` binary to manage.

On first parse the server:

1. resolves the latest GoogleSQL release (or `$GOOGLESQL_VERSION` if set),
2. downloads that release's `googlesql_docker.tar.gz` and `docker load`s it as image
   `googlesql_ubuntu:<version>`,
3. starts a long-lived helper container named `googlesql-lsp`, and
4. runs `execute_query --mode=parse` inside it via `docker exec` for each parse.

The image is cached by Docker and the container is reused across sessions, so only the first
run pays the download cost. This works identically on macOS, Linux, and Windows. If Docker
isn't installed or the daemon isn't running, the server reports an actionable error and
publishes no diagnostics until it's fixed.

> Stop and remove the helper container any time with `docker rm -f googlesql-lsp`; the next
> parse recreates it.

> **Prefer a native host binary?** `scripts/install-parser.sh` still downloads a native
> `execute_query` for CLI/standalone use, but the language server itself uses Docker.

### 2. Build & install the language server

```bash
cargo install --path .
```

Puts `googlesql-lsp` on your `PATH` (in `~/.cargo/bin`). The Zed extension finds it there.

### 3. Install the Zed extension

In Zed, open the command palette and run **`zed: install dev extension`**, then select
the `zed-extension/` directory in this repo. Zed compiles the WASM extension and loads it.

> **Requires the SQL extension.** This extension only adds a language server; it relies on
> Zed's **SQL** extension for the language definition and syntax highlighting. Install it from
> the extensions view if you don't have it (most Zed setups do).

Open any `.sql` file and type an error (e.g. `SELECT 1 FRM t`) — you'll get a red squiggle
with GoogleSQL's message at the exact column. Fix it and the squiggle clears.

## Configuration

The server runs the parser inside Docker (see **Install → 1**). Two environment variables
tune it:

- `$GOOGLESQL_VERSION` — pin a specific GoogleSQL release tag instead of resolving the latest
  (also useful offline once that version's image is loaded).
- Docker itself must be on `$PATH` with a reachable daemon.

The helper image (`googlesql_ubuntu:<version>`) and container (`googlesql-lsp`) are created on
first use and reused thereafter.

## Testing

```bash
cargo test              # unit tests for the diagnostic scraper
./scripts/smoke-test.sh # see the parser's raw output on sample SQL
```

## File associations

The server attaches to Zed's **SQL** language, which owns `.sql` by default — so BigQuery
files light up with no extra config. To also run the server on other suffixes (e.g. `.bqsql`,
`.googlesql`), map them to `SQL` via a
[file association](https://zed.dev/docs/configuring-zed#file-types) in your Zed settings:

```json
"file_types": { "SQL": ["bqsql", "googlesql"] }
```

## Limitations

- **Syntax errors only.** The parser catches malformed SQL (bad keywords, unbalanced
  clauses, unexpected tokens). It does **not** catch semantic errors like unknown
  tables/columns, type mismatches, or bad function signatures — those require the
  GoogleSQL *analyzer* plus a schema catalog, which is out of scope here.
- Diagnostics update ~250 ms after you stop typing (debounced); each parse runs
  `execute_query` once via `docker exec`.
- Columns are reported in the parser's units; non-ASCII characters before an error on the
  same line may shift the highlight by a few columns.
- Requires a running Docker daemon. The GoogleSQL image is linux/amd64, so on Apple Silicon
  it runs under emulation (the server passes `--platform linux/amd64` automatically).

## Why wrap the binary instead of compiling the parser

GoogleSQL is a large Bazel/C++ project with only "experimental" macOS build support.
But each release ships a prebuilt `execute_query` — in a Docker image whose `--mode=parse`
exposes exactly the parser we need — so we wrap that instead of compiling the parser
ourselves. Running it from the release image keeps the whole thing build-free and works on
any OS with Docker, while still using Google's real parser.

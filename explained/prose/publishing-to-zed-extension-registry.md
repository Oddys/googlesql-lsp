# Publishing to the Zed extension registry (loading "from GitHub" instead of as a dev extension)

## The key concept: Zed has no "install from a GitHub URL"

Unlike VS Code (`.vsix` files) or some other editors, **Zed does not let a user
paste a GitHub repo URL and install an extension from it.** There are only two
real installation paths:

1. **Dev extension** — `zed: install dev extension`, pointed at a local
   directory. Zed compiles the WASM on the user's machine. This is the flow we
   want to move away from.
2. **The Zed extension registry** — the searchable list in Zed's Extensions
   view. This is the *only* hands-off distribution channel, and it *is* backed by
   GitHub: the registry is the repo
   [`zed-industries/extensions`](https://github.com/zed-industries/extensions),
   and each extension in it points at a source GitHub repo (ours). When a user
   clicks "Install", Zed's infrastructure builds the extension's WASM from *our*
   GitHub repo and serves it.

So "load the extension from GitHub" concretely means **get it into the
`zed-industries/extensions` registry**, which then pulls source from
`github.com/Oddys/googlesql-lsp`.

## The registry publishing mechanics (the easy part)

Once the repo is ready, publish by opening a PR against
`zed-industries/extensions`:

1. Fork that repo.
2. Add our repo as a git submodule under its `extensions/` directory.
3. Add an entry to its root `extensions.toml`. Because our `extension.toml` lives
   in a **subdirectory** (`zed-extension/`), not the repo root, point at it with
   `path`:

   ```toml
   [googlesql]
   submodule = "extensions/googlesql-lsp"
   path = "zed-extension"
   version = "0.1.0"
   ```
4. Their CI validates and builds it; on merge it appears in everyone's
   Extensions view.

`zed-extension/extension.toml` already has the required fields (`id`, `name`,
`version`, `schema_version`, `authors`, `description`, `repository`), so the
metadata side is basically done. The subdirectory layout is fine — `path` exists
exactly for repos like ours where the root is something else (here, the LSP
server crate).

## The real blocker: the extension can't install the server on its own

Today, `zed-extension/src/lib.rs:20` locates the server with:

```rust
let path = worktree.which("googlesql-lsp").ok_or_else(|| { … "cargo install --path ." … })?;
```

That works for the author because they ran `cargo install --path .` and
`./scripts/install-parser.sh` by hand. But a registry user does neither. And
critically — **Zed only builds the WASM extension. It never builds or ships the
Rust `googlesql-lsp` server binary.** So for a stranger who clicks "Install",
`worktree.which("googlesql-lsp")` returns `None` and the extension immediately
errors out. The extension is responsible for getting its own language server onto
the machine.

The standard pattern (used by nearly every real Zed language extension) is to
**download a prebuilt server binary from GitHub releases** inside
`language_server_command`, using the `zed_extension_api` helpers:

- `zed::latest_github_release(...)` — find the newest release of
  `Oddys/googlesql-lsp`.
- `zed::download_file(...)` — pull the right asset for the user's OS/arch
  (`zed::current_platform()` tells you which).
- `zed::make_file_executable(...)` — mark it runnable.
- Cache it under the extension's work directory and return its path; re-download
  only when the release version changes.

Keep the existing `worktree.which(...)` as a *fast-path fallback* (so the dev
machine keeps using `~/.cargo/bin`), then fall through to the download path when
it's absent.

**This implies new infrastructure that doesn't exist yet:** we must actually
*publish* prebuilt `googlesql-lsp` binaries as GitHub release assets, per
platform (`aarch64-apple-darwin`, `x86_64-apple-darwin`,
`x86_64-unknown-linux-gnu`, …). That means adding a **GitHub Actions release
workflow** that builds the server for each target and attaches the binaries to a
tagged release. Without that, there's nothing for the extension to download.

## The second dependency: the `execute_query` parser binary

There's a subtler wrinkle unique to this project. The server is itself a
wrapper — `src/parser.rs:11` shows it locates Google's `execute_query` binary via
`$GOOGLESQL_EXECUTE_QUERY` → `~/.local/share/googlesql-lsp/execute_query` →
`$PATH`, and that binary is fetched by `scripts/install-parser.sh`. A registry
user won't run that script either, so even after the extension downloads the
server, the server will hit `src/backend.rs:123` — *"could not find the
`execute_query` binary."*

To make the install truly one-click, eliminate this manual step too:

- **Server-side (recommended):** have `googlesql-lsp` download `execute_query`
  itself on first run (port the logic from `install-parser.sh` — including the
  macOS quarantine-flag removal — into Rust). Then the extension→server→parser
  chain is fully automatic.
- **Extension-side:** have the extension download `execute_query` and pass its
  path to the server via the `GOOGLESQL_EXECUTE_QUERY` env var in the `Command`
  it returns.

Either works; the server-side approach keeps the extension thin and also benefits
non-Zed users of the server.

## Housekeeping for a clean published repo

- **`extension.wasm` must not be committed.** It's a ~582 KB build artifact in
  `zed-extension/`; `.gitignore` already ignores `*.wasm` and it's untracked.
  Leave it that way — Zed builds the WASM itself.
- **Consider committing `Cargo.lock`.** The global `.gitignore` ignores
  `Cargo.lock`, so neither the server's nor the extension's lockfile is tracked.
  For reproducible builds it's best practice to commit the lockfile for both a
  binary crate (the server) and the extension crate. Not strictly required, but
  recommended.
- **Check `zed_extension_api` currency.** `zed-extension/Cargo.toml` pins
  `0.7.0`. Before publishing, bump to the latest compatible version and confirm
  `schema_version = 1` in `extension.toml` still matches what that API expects
  (the download/release helpers above are the reason to be on a current version).
- **Version discipline.** The registry keys off the `version` in
  `extension.toml`; each store update is a new PR bumping that number. Keep the
  extension version, the server release tag, and what the extension downloads in
  sync.

## Summary of the work

| Change | Where | Why |
| --- | --- | --- |
| Rewrite `language_server_command` to download the server from GitHub releases (PATH as fallback) | `zed-extension/src/lib.rs:19` | Registry users never `cargo install`; Zed won't build the server |
| Add a CI release workflow that publishes prebuilt `googlesql-lsp` binaries per platform | new `.github/workflows/…` | Gives the extension something to download |
| Auto-fetch `execute_query` (in the server, on first run) | `src/parser.rs:11` / server startup | Removes the manual `install-parser.sh` step |
| Commit `Cargo.lock`, keep `*.wasm` ignored, bump `zed_extension_api` | `.gitignore`, `zed-extension/Cargo.toml` | Reproducible, clean registry build |
| Open a PR to `zed-industries/extensions` with a `path = "zed-extension"` entry | external repo | The actual publish step |

The load-bearing change is the first two rows: **the extension must fetch its own
server, and we must publish that server as release binaries.** Everything else is
packaging.

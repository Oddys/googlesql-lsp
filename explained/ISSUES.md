# Issues

## 2026-07-15 — `scripts/install-parser.sh` (full script + generated docker wrapper)

Scope: the full install script and the docker wrapper it generates. 5 findings:
1 high, 2 medium, 2 low. Invoked by `src/parser.rs::run_parse` as
`execute_query --mode=parse <sql>` (the tool exits 0 even on syntax errors).

### Bugs & uncovered edge cases

- **[High] `install-parser.sh:189` / wrapper `:171` — docker-mode verification can
  never fail.** The generated wrapper's last command is `printf '%s\n' "$output"`,
  which exits 0 regardless of whether `docker exec`/recreate succeeded. So the final
  `if "$DEST" --mode=parse "SELECT 1"` check is always true in docker mode and prints
  `OK: … is runnable.` even when Docker is broken; the WARNING/`exit 1` branch is dead
  code for docker mode. Verified: a wrapper ending in `printf` returns 0 even when the
  docker command doesn't exist. Fix: wrapper records the `docker exec` exit status and
  `exit`s with it.
  Status: FIXED (2026-07-15).

- **[Medium] wrapper `:169-171` — retry result unchecked; docker error text emitted as
  parse output.** The first `docker exec` is checked, but the post-recreate `docker exec`
  is not. On persistent failure `$output` holds Docker's error string and is printed to
  stdout as if it were parser output, which the diagnostics scraper then mis-parses.
  Fix: re-check status after retry; on failure emit to stderr and exit non-zero.
  Status: FIXED (2026-07-15).

### Robustness

- **[Medium] `install-parser.sh:40-46` — friendly "could not determine latest release"
  message is unreachable when curl fails.** Under `set -euo pipefail`, a failed GitHub
  API call (offline / 403 rate limit) fails the pipeline and aborts the script at the
  line-40 assignment, before the `[ -z "$VERSION" ]` check. Verified with a 404. User
  gets a raw `curl:` error instead of the `GOOGLESQL_VERSION` hint. Fix: let the pipeline
  fail softly so control reaches the friendly branch.
  Status: FIXED (2026-07-15).

- **[Low] `install-parser.sh:81` — macOS arch check is a fragile substring match.**
  `file "$DEST" | grep -qi "$host_arch"` can misattribute causes (non-Mach-O payloads,
  universal binaries; `arm64` matched inside `arm64e`). Low impact given `curl -f`.
  Fix: switched to `lipo -archs` with a `file -b` fallback and a whole-word `case`
  match, so only an exact arch token counts.
  Status: FIXED (2026-07-15).

### Security

- **[Low] `install-parser.sh:74`, `:126-129` — no integrity check on downloaded binary
  or docker tarball.** Downloaded assets are `chmod +x`'d / `docker load`ed without
  checksum or signature verification. Low risk (HTTPS to github.com). Note: the current
  google/googlesql releases publish no `.sha256` sidecars, so there is nothing to verify
  against today. Fix: added a best-effort `verify_checksum` helper that downloads a
  `<asset>.sha256` sidecar if present and fails closed on mismatch (deleting the file),
  and skips cleanly when no sidecar or no sha256 tool exists. Becomes real protection if
  upstream starts publishing checksums.
  Status: FIXED (2026-07-15, best-effort).

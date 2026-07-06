#!/usr/bin/env bash
#
# Downloads the prebuilt GoogleSQL `execute_query` binary and installs it where
# googlesql-lsp looks for it by default (~/.local/share/googlesql-lsp/execute_query).
#
# The binary is the same tool the LSP invokes with `--mode=parse`. No build required.

set -euo pipefail

VERSION="${GOOGLESQL_VERSION:-2026.01.1}"
INSTALL_DIR="${GOOGLESQL_INSTALL_DIR:-$HOME/.local/share/googlesql-lsp}"
DEST="$INSTALL_DIR/execute_query"

# Pick the asset for this OS.
case "$(uname -s)" in
    Darwin) ASSET="execute_query_macos" ;;
    Linux)  ASSET="execute_query_linux" ;;
    *)
        echo "Unsupported OS: $(uname -s). Only macOS and Linux prebuilt binaries exist." >&2
        exit 1
        ;;
esac

URL="https://github.com/google/googlesql/releases/download/${VERSION}/${ASSET}"

echo "Installing GoogleSQL parser binary"
echo "  version: $VERSION"
echo "  asset:   $ASSET"
echo "  dest:    $DEST"

mkdir -p "$INSTALL_DIR"
curl -fL --retry 2 "$URL" -o "$DEST"

# Clear the macOS quarantine flag so Gatekeeper allows the unsigned binary to run.
xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true
chmod +x "$DEST"

echo
echo "Installed. Verifying..."
if "$DEST" --mode=parse "SELECT 1" >/dev/null 2>&1; then
    echo "OK: $DEST is runnable."
else
    echo "WARNING: the binary was installed but a test parse failed. On macOS you may need to" >&2
    echo "allow it once under System Settings > Privacy & Security." >&2
    exit 1
fi

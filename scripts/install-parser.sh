#!/usr/bin/env bash
#
# Downloads the prebuilt GoogleSQL `execute_query` binary and installs it where
# googlesql-lsp looks for it by default (~/.local/share/googlesql-lsp/execute_query).
#
# The binary is the same tool the LSP invokes with `--mode=parse`. No build required.

set -euo pipefail

INSTALL_DIR="${GOOGLESQL_INSTALL_DIR:-$HOME/.local/share/googlesql-lsp}"
DEST="$INSTALL_DIR/execute_query"

# Resolve the version to install. Honor an explicit GOOGLESQL_VERSION override;
# otherwise ask GitHub for the latest published release tag.
# For MacOs on Intel use 2026.01.1 since in version 2026.7.2 the MacOS build is targeted for Arm64
VERSION="${GOOGLESQL_VERSION:-}"
if [ -z "$VERSION" ]; then
    echo "Resolving latest GoogleSQL release..."
    VERSION="$(curl -fsSL "https://api.github.com/repos/google/googlesql/releases/latest" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n1)"
    if [ -z "$VERSION" ]; then
        echo "Could not determine the latest release. Set GOOGLESQL_VERSION to install a specific version." >&2
        exit 1
    fi
fi

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

# On macOS the published asset's architecture has varied between releases (x86_64
# in older builds, arm64 in newer ones). Verify the downloaded binary can run on
# this CPU and fail early with a clear message if it can't.
if [ "$(uname -s)" = "Darwin" ]; then
    HOST_ARCH="$(uname -m)"
    if ! file "$DEST" | grep -qi "$HOST_ARCH"; then
        echo >&2
        echo "The downloaded $ASSET is not built for this Mac ($HOST_ARCH):" >&2
        echo "  $(file -b "$DEST")" >&2
        echo "Pin a matching release via GOOGLESQL_VERSION (e.g. 2026.01.1 is x86_64)," >&2
        echo "use the googlesql_docker image, or run on a matching architecture." >&2
        rm -f "$DEST"
        exit 1
    fi
fi

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

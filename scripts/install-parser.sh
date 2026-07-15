#!/usr/bin/env bash
#
# Installs the GoogleSQL `execute_query` parser where googlesql-lsp looks for it
# by default (~/.local/share/googlesql-lsp/execute_query).
#
# Two modes:
#   native (default) - downloads the prebuilt binary for this OS/CPU.
#   docker           - loads the release's Linux image and installs a small
#                      wrapper at the same path that runs the parser in a
#                      container. Use this when no native binary matches your CPU
#                      (e.g. Intel macOS, where recent releases are arm64-only).
#
# Enable docker mode with `--docker` or GOOGLESQL_USE_DOCKER=1. Either way the LSP
# invokes the same path with `--mode=parse`; the wrapper is transparent to it.

set -euo pipefail

INSTALL_DIR="${GOOGLESQL_INSTALL_DIR:-$HOME/.local/share/googlesql-lsp}"
DEST="$INSTALL_DIR/execute_query"

# Name/tag the docker helpers use. The release tarball loads as
# googlesql_ubuntu:latest; we re-tag it per version for reproducibility.
DOCKER_IMAGE_REPO="googlesql_ubuntu"
DOCKER_CONTAINER="googlesql-lsp"

# Select mode: --docker flag or GOOGLESQL_USE_DOCKER=1.
USE_DOCKER="${GOOGLESQL_USE_DOCKER:-0}"
for arg in "$@"; do
    case "$arg" in
        --docker) USE_DOCKER=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# Resolve the version to install. Honor an explicit GOOGLESQL_VERSION override;
# otherwise ask GitHub for the latest published release tag.
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

release_url() {
    echo "https://github.com/google/googlesql/releases/download/${VERSION}/$1"
}

# --- native install -----------------------------------------------------------
# Downloads the prebuilt binary for this OS and drops it at $DEST.
install_native() {
    local asset url host_arch
    case "$(uname -s)" in
        Darwin) asset="execute_query_macos" ;;
        Linux)  asset="execute_query_linux" ;;
        *)
            echo "Unsupported OS: $(uname -s). Only macOS and Linux prebuilt binaries exist." >&2
            echo "Try docker mode instead: GOOGLESQL_USE_DOCKER=1 $0" >&2
            exit 1
            ;;
    esac
    url="$(release_url "$asset")"

    echo "Installing GoogleSQL parser binary (native)"
    echo "  version: $VERSION"
    echo "  asset:   $asset"
    echo "  dest:    $DEST"

    mkdir -p "$INSTALL_DIR"
    curl -fL --retry 2 "$url" -o "$DEST"

    # On macOS the published asset's architecture has varied between releases
    # (x86_64 in older builds, arm64 in newer ones). Verify the downloaded binary
    # can run on this CPU and fail early with a clear message if it can't.
    if [ "$(uname -s)" = "Darwin" ]; then
        host_arch="$(uname -m)"
        if ! file "$DEST" | grep -qi "$host_arch"; then
            echo >&2
            echo "The downloaded $asset is not built for this Mac ($host_arch):" >&2
            echo "  $(file -b "$DEST")" >&2
            echo "Options: pin a matching release via GOOGLESQL_VERSION (e.g. 2026.01.1 is" >&2
            echo "x86_64), or install the latest via docker: GOOGLESQL_USE_DOCKER=1 $0" >&2
            rm -f "$DEST"
            exit 1
        fi
    fi

    # Clear the macOS quarantine flag so Gatekeeper allows the unsigned binary to run.
    xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true
    chmod +x "$DEST"
}

# --- docker install -----------------------------------------------------------
# Loads the release's Linux image and installs a wrapper at $DEST that runs the
# parser inside a long-lived container. Lets Intel macOS (and anything else
# without a native binary) run the latest parser.
install_docker() {
    local IMAGE TARBALL

    if ! command -v docker >/dev/null 2>&1; then
        echo "docker mode requires the Docker CLI, which was not found on PATH." >&2
        echo "Install Docker Desktop (macOS) or docker engine (Linux) and retry." >&2
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "The Docker daemon is not reachable. Start Docker Desktop (or the docker" >&2
        echo "service) and retry." >&2
        exit 1
    fi

    IMAGE="${DOCKER_IMAGE_REPO}:${VERSION}"
    TARBALL="$INSTALL_DIR/googlesql_docker.tar.gz"

    echo "Installing GoogleSQL parser via Docker"
    echo "  version:   $VERSION"
    echo "  image:     $IMAGE"
    echo "  container: $DOCKER_CONTAINER"
    echo "  wrapper:   $DEST"

    mkdir -p "$INSTALL_DIR"
    echo "Downloading image tarball..."
    curl -fL --retry 2 "$(release_url googlesql_docker.tar.gz)" -o "$TARBALL"

    echo "Loading image (this can take a moment)..."
    docker load -i "$TARBALL"
    # The tarball always loads as googlesql_ubuntu:latest; pin it to this version
    # so the wrapper references an exact tag rather than a moving :latest.
    docker tag "${DOCKER_IMAGE_REPO}:latest" "$IMAGE"
    rm -f "$TARBALL"

    # Drop any container from a previous install so the next parse recreates it
    # against the image we just loaded.
    docker rm -f "$DOCKER_CONTAINER" >/dev/null 2>&1 || true

    # Write the wrapper. The LSP calls it as `execute_query --mode=parse <sql>`;
    # we forward "$@" into a persistent container via `docker exec` for speed
    # (avoids per-parse container cold starts). The image entrypoint is
    # /googlesql/execute_query.
    #
    # Hot path is a single `docker exec` (each round-trips to the Docker/Podman
    # VM, so extra calls are the dominant cost). execute_query exits 0 even on
    # syntax errors, so a non-zero exit reliably means the container isn't up —
    # only then do we (re)create it and retry once.
    cat > "$DEST" <<EOF
#!/usr/bin/env bash
#
# Auto-generated by scripts/install-parser.sh (docker mode). Runs GoogleSQL's
# execute_query inside a long-lived container so hosts without a native binary
# (e.g. Intel macOS) can use the latest parser.
#
# The helper container persists across sessions for speed. Remove it with:
#   docker rm -f $DOCKER_CONTAINER
set -uo pipefail

IMAGE="$IMAGE"
CONTAINER="$DOCKER_CONTAINER"

output="\$(docker exec "\$CONTAINER" /googlesql/execute_query "\$@" 2>&1)"
if [ \$? -ne 0 ]; then
    # Container not running (execute_query itself never exits non-zero). Start an
    # existing one or create a fresh detached container, then retry once.
    docker start "\$CONTAINER" >/dev/null 2>&1 \\
        || docker run -d --name "\$CONTAINER" --entrypoint sleep \\
             "\$IMAGE" infinity >/dev/null 2>&1 || true
    output="\$(docker exec "\$CONTAINER" /googlesql/execute_query "\$@" 2>&1)"
fi
printf '%s\\n' "\$output"
EOF
    chmod +x "$DEST"
}

# --- run ----------------------------------------------------------------------
if [ "$USE_DOCKER" = "1" ]; then
    install_docker
else
    install_native
fi

echo
if [ "$USE_DOCKER" = "1" ]; then
    echo "Installed. Verifying (first run also warms the helper container)..."
else
    echo "Installed. Verifying..."
fi
if "$DEST" --mode=parse "SELECT 1" >/dev/null 2>&1; then
    echo "OK: $DEST is runnable."
else
    echo "WARNING: installed but a test parse failed." >&2
    if [ "$USE_DOCKER" = "1" ]; then
        echo "Check that Docker is running: docker info" >&2
    else
        echo "On macOS you may need to allow it once under System Settings > Privacy & Security." >&2
    fi
    exit 1
fi

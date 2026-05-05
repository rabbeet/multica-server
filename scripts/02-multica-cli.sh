#!/usr/bin/env bash
# 02-multica-cli.sh — install multica CLI binary on Linux from GitHub releases.
#
# Multica daemon is a NATIVE Go binary, not a container. It scans the host's
# $PATH for AI CLIs (claude, codex, etc.) to spawn. So we install it on the
# host, not inside docker.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root

INSTALL_PATH=/usr/local/bin/multica

# ---- Idempotent ----
if [[ -x "$INSTALL_PATH" ]]; then
    current_ver=$("$INSTALL_PATH" version 2>/dev/null | head -1 || echo "unknown")
    log_skip "multica already installed: $current_ver"
    exit 0
fi

# ---- Detect arch ----
arch=$(uname -m)
case "$arch" in
    x86_64) MULTICA_ARCH=amd64 ;;
    aarch64) MULTICA_ARCH=arm64 ;;
    *) log_error "Unsupported arch: $arch"; exit 1 ;;
esac

# ---- Find latest release tag ----
log_info "Detecting latest multica release..."
latest_tag=$(curl -sI https://github.com/multica-ai/multica/releases/latest \
    | awk -F'/' '/^location:/ {print $NF}' | tr -d '\r\n')

if [[ -z "$latest_tag" ]]; then
    log_error "Could not determine latest multica release"
    exit 1
fi

version="${latest_tag#v}"
log_info "Latest: $latest_tag (version $version)"

# ---- Download ----
url="https://github.com/multica-ai/multica/releases/download/${latest_tag}/multica-cli-${version}-linux-${MULTICA_ARCH}.tar.gz"
log_info "Downloading from $url..."
curl -sSL --fail "$url" -o /tmp/multica.tar.gz

# ---- Extract + install ----
tar -xzf /tmp/multica.tar.gz -C /tmp multica
mv /tmp/multica "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
rm -f /tmp/multica.tar.gz

# ---- Verify ----
log_ok "Installed: $("$INSTALL_PATH" version | head -1)"
log_ok "02-multica-cli complete"

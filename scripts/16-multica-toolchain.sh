#!/usr/bin/env bash
# 16-multica-toolchain.sh — install host toolchain that multica's own repos
# (rabbeet/multica and rabbeet/multica-server) need when agents take tasks on
# them.
#
# Why this script exists (PUL-163): without these tools on the host PATH,
# every agent that picks up a multica-flavoured task wastes ~1h re-installing
# Go/sqlc/pnpm into $HOME by hand, then re-discovering migration numbering
# already in use by a parallel branch. Putting them on the host once means:
#   1. `go build`, `sqlc generate`, `pnpm install` work out of the box for
#      any agent process spawned by the daemon (it sees /usr/local/bin
#      read-only through ProtectSystem=strict but the binaries are accessible).
#   2. Caches still live under /home/multica which is in ReadWritePaths.
#
# Versions track what multica HEAD currently requires:
#   - Go      from `server/go.mod` (`go 1.26.1`)
#   - pnpm    from root `package.json` (`packageManager: pnpm@10.28.2`)
#   - sqlc    pinned to v1.31.1 — matches the trimmed output currently
#             checked in under server/pkg/db/generated/. v1.30.0 regenerates
#             extra cascade columns that aren't in the committed snapshot,
#             so do not regress (issue PUL-163 §1).
#
# Idempotent. Re-running upgrades to the pinned version, never downgrades
# silently.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root

GO_VERSION="${GO_VERSION:-1.26.1}"
SQLC_VERSION="${SQLC_VERSION:-1.31.1}"
PNPM_VERSION="${PNPM_VERSION:-10.28.2}"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  GO_ARCH="amd64"; SQLC_ARCH="amd64" ;;
    aarch64) GO_ARCH="arm64"; SQLC_ARCH="arm64" ;;
    *) log_error "Unsupported arch: $ARCH"; exit 1 ;;
esac

# ---- Go ---------------------------------------------------------------------
# Install to /usr/local/go (matches the upstream go.dev tarball layout) and
# symlink `go` + `gofmt` into /usr/local/bin so they end up on the default
# PATH inherited by multica-daemon's spawned agents (PATH=/usr/local/bin:...).
GO_TARBALL_URL="https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
GO_INSTALL_DIR="/usr/local/go"

current_go=""
if command -v go >/dev/null 2>&1; then
    current_go=$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
fi

if [[ "$current_go" == "$GO_VERSION" ]]; then
    log_skip "Go $GO_VERSION already installed at $(command -v go)"
else
    log_info "Installing Go $GO_VERSION (current: ${current_go:-none})..."
    tmp_tar=$(mktemp --suffix=.tar.gz)
    trap 'rm -f "$tmp_tar"' EXIT
    curl -fsSL "$GO_TARBALL_URL" -o "$tmp_tar"
    rm -rf "$GO_INSTALL_DIR"
    tar -C /usr/local -xzf "$tmp_tar"
    ln -sf "$GO_INSTALL_DIR/bin/go"     /usr/local/bin/go
    ln -sf "$GO_INSTALL_DIR/bin/gofmt"  /usr/local/bin/gofmt
    rm -f "$tmp_tar"
    trap - EXIT
    log_ok "Go installed: $(/usr/local/bin/go version)"
fi

# ---- sqlc -------------------------------------------------------------------
# sqlc ships pre-compiled tarballs; pin the version so generated SQL matches
# what's already checked into the multica repo.
SQLC_TARBALL_URL="https://github.com/sqlc-dev/sqlc/releases/download/v${SQLC_VERSION}/sqlc_${SQLC_VERSION}_linux_${SQLC_ARCH}.tar.gz"
SQLC_BIN="/usr/local/bin/sqlc"

current_sqlc=""
if [[ -x "$SQLC_BIN" ]]; then
    current_sqlc=$("$SQLC_BIN" version 2>/dev/null | head -1 | sed 's/^v//')
fi

if [[ "$current_sqlc" == "$SQLC_VERSION" ]]; then
    log_skip "sqlc v$SQLC_VERSION already installed at $SQLC_BIN"
else
    log_info "Installing sqlc v$SQLC_VERSION (current: ${current_sqlc:-none})..."
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT
    curl -fsSL "$SQLC_TARBALL_URL" -o "$tmp_dir/sqlc.tar.gz"
    tar -C "$tmp_dir" -xzf "$tmp_dir/sqlc.tar.gz"
    install -m 0755 "$tmp_dir/sqlc" "$SQLC_BIN"
    rm -rf "$tmp_dir"
    trap - EXIT
    log_ok "sqlc installed: $("$SQLC_BIN" version | head -1)"
fi

# ---- pnpm via corepack ------------------------------------------------------
# Requires Node.js 22+ for corepack support. We DON'T install Node here —
# pulse-stack / multica-stack scripts already provision it via nvm under
# /home/multica. If node isn't on PATH yet, fall back to standalone pnpm
# binary install so agents still get a working pnpm.
PNPM_BIN="/usr/local/bin/pnpm"

current_pnpm=""
if command -v pnpm >/dev/null 2>&1; then
    current_pnpm=$(pnpm --version 2>/dev/null)
fi

if [[ "$current_pnpm" == "$PNPM_VERSION" ]]; then
    log_skip "pnpm $PNPM_VERSION already installed at $(command -v pnpm)"
else
    log_info "Installing pnpm $PNPM_VERSION (current: ${current_pnpm:-none})..."
    if command -v corepack >/dev/null 2>&1; then
        # Preferred path — corepack ships with Node.js >= 16.9, and pins the
        # version per-project from packageManager. Activate the global shim too.
        corepack enable --install-directory /usr/local/bin >/dev/null
        corepack prepare "pnpm@${PNPM_VERSION}" --activate
        log_ok "pnpm installed via corepack: $(pnpm --version)"
    else
        # Standalone fallback — single statically-linked binary, no Node needed
        # to launch (pnpm bundles its own runtime).
        case "$ARCH" in
            x86_64)  pnpm_arch="x64" ;;
            aarch64) pnpm_arch="arm64" ;;
        esac
        url="https://github.com/pnpm/pnpm/releases/download/v${PNPM_VERSION}/pnpm-linux-${pnpm_arch}"
        curl -fsSL "$url" -o "$PNPM_BIN"
        chmod +x "$PNPM_BIN"
        log_ok "pnpm installed (standalone): $($PNPM_BIN --version)"
    fi
fi

# ---- Sanity: emit final versions so bootstrap output is self-documenting ---
log_info "Toolchain ready:"
log_info "  go    $(/usr/local/bin/go version 2>/dev/null || echo MISSING)"
log_info "  sqlc  $($SQLC_BIN version 2>/dev/null | head -1 || echo MISSING)"
log_info "  pnpm  $(command -v pnpm >/dev/null 2>&1 && pnpm --version || echo MISSING)"

#!/usr/bin/env bash
# 07-claude-cli.sh — install Claude Code on host so multica daemon can spawn it.
#
# Multica daemon (a host process) detects available AI CLIs by scanning $PATH.
# It looks for `claude`, `codex`, `opencode`, etc. We install `claude` here.
#
# Installed system-wide for both `multica` and `claude` users to find.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root

CLAUDE_INSTALL_PATH=/usr/local/bin/claude

# ---- Idempotent ----
if [[ -x "$CLAUDE_INSTALL_PATH" ]] || command -v claude >/dev/null 2>&1; then
    existing=$(command -v claude)
    log_skip "claude already at $existing"
    log_info "  version: $($existing --version 2>/dev/null | head -1 || echo 'unknown')"
    exit 0
fi

# ---- Install via official curl script (Anthropic's recommended) ----
log_info "Installing Claude Code from official installer..."
# This installs to /usr/local/bin/claude system-wide when run as root.
if curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh; then
    bash /tmp/claude-install.sh
    rm -f /tmp/claude-install.sh
else
    log_error "Could not download Claude Code installer"
    log_error "Manual install: download from https://github.com/anthropics/claude-code/releases"
    exit 1
fi

# ---- Verify ----
if ! command -v claude >/dev/null 2>&1; then
    # Installer may have put it in /root/.local/bin or similar. Search.
    found=$(find /root/.local /usr/local /opt -maxdepth 3 -name claude -type f -executable 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        ln -sf "$found" "$CLAUDE_INSTALL_PATH"
        log_info "Linked $found -> $CLAUDE_INSTALL_PATH"
    else
        log_error "claude binary not found after install"
        exit 1
    fi
fi

log_ok "Installed: $(claude --version 2>/dev/null | head -1)"
log_ok "07-claude-cli complete"

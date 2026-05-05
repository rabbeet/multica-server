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

# ---- Locate the installed binary ----
# Anthropic's installer puts it under ~/.local/bin (= /root/.local/bin when
# running as root). Symlink to /usr/local/bin/claude so all users (including
# the `multica` user the daemon runs as) can find it without PATH tricks.
CLAUDE_BIN=""
for cand in /root/.local/bin/claude /usr/local/bin/claude /opt/claude/claude; do
    if [[ -e "$cand" ]]; then
        CLAUDE_BIN="$cand"
        break
    fi
done

if [[ -z "$CLAUDE_BIN" ]]; then
    # Broader search — covers symlinks too (no -type f restriction)
    CLAUDE_BIN=$(find /root /usr/local /opt -maxdepth 4 -name claude -executable 2>/dev/null | grep -v '/skills/' | head -1)
fi

if [[ -z "$CLAUDE_BIN" || ! -e "$CLAUDE_BIN" ]]; then
    log_error "claude binary not found after install"
    log_error "Check: ls -la /root/.local/bin/ /usr/local/bin/"
    exit 1
fi

# ---- Symlink to /usr/local/bin so any user can find it ----
if [[ "$CLAUDE_BIN" != "$CLAUDE_INSTALL_PATH" ]]; then
    ln -sf "$CLAUDE_BIN" "$CLAUDE_INSTALL_PATH"
    log_info "Symlinked $CLAUDE_BIN -> $CLAUDE_INSTALL_PATH"
fi

# ---- Verify accessible from PATH ----
if ! command -v claude >/dev/null 2>&1; then
    log_error "claude still not in PATH after symlink"
    exit 1
fi

log_ok "Installed: $(claude --version 2>/dev/null | head -1)"
log_ok "07-claude-cli complete"

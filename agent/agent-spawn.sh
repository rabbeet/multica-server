#!/usr/bin/env bash
# agent-spawn.sh — spawn one claude process inside agent-host container.
# Called by multica daemon as: docker exec agent-host /usr/local/bin/agent-spawn.sh <agent-id>
#
# Each agent gets its own CLAUDE_CONFIG_DIR + git worktree, providing
# OAuth-state and filesystem isolation between concurrent claude sessions.
#
# Design ref: ~/.gstack/projects/rabbeet-multica-server/rabbeeet-main-design-20260507-224221.md (A-lite)

set -euo pipefail

# shellcheck source=lib.sh
source /usr/local/bin/agent-lib.sh

if [ "$#" -lt 1 ]; then
  log_error "usage: agent-spawn.sh <agent-id> [task-slug]"
  exit 2
fi

AGENT_ID="$1"
# Eng Issue 2.2 — collision-proof slug: timestamp + PID + 4-byte random.
# Defaults to scratch-* when daemon does not pass TASK_SLUG via env.
TASK_SLUG="${TASK_SLUG:-${2:-scratch-$(date +%Y%m%d-%H%M%S)-$$-$(openssl rand -hex 2)}}"

export CLAUDE_CONFIG_DIR="/home/agent/.claude/$AGENT_ID"
WT="/home/agent/worktrees/$AGENT_ID"
BARE="/srv/pulse-bare.git"

mkdir -p "$CLAUDE_CONFIG_DIR" /var/log/agent

# Eng Issue 2.3 — settings.json shared via symlink (one source of truth, N agents).
ln -sf /etc/agent-settings.json "$CLAUDE_CONFIG_DIR/settings.json"

# Sync bare clone before worktree creation (Eng Issue 1.1 — bare/mirror drift).
# Best-effort: a transient fetch failure should not block spawn; the agent will
# work against last-known-good HEAD rather than refusing to start.
if [ -d "$BARE" ]; then
  log_info "fetching origin main into $BARE"
  if ! git -C "$BARE" fetch --quiet origin main; then
    log_skip "git fetch failed; continuing with last-known-good"
  fi
else
  log_error "bare clone not found at $BARE — has bootstrap been run?"
  exit 3
fi

# Cleanup stale worktree (Error-map GAP #1 — idempotency).
if [ -d "$WT" ]; then
  log_skip "removing stale worktree $WT"
  git -C "$BARE" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
fi

# Per-task branch (Error-map GAP #2 — avoids non-fast-forward race).
BRANCH="agent-$AGENT_ID/$TASK_SLUG"
log_info "creating worktree $WT on branch $BRANCH"
git -C "$BARE" worktree add -B "$BRANCH" "$WT" main

cd "$WT"
log_ok "agent-$AGENT_ID ready: branch=$BRANCH config=$CLAUDE_CONFIG_DIR"
exec claude

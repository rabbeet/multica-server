#!/usr/bin/env bash
# 14-agent-host-prep.sh — prepare host filesystem for the multica.ai-native
# agent worker model.
#
# Architecture: multica daemon spawns claude as user multica with per-agent
# custom_env (CLAUDE_CONFIG_DIR=/home/multica/.claude/agent-N/). Each agent
# gets its own OAuth state + git worktree. Hard limits enforced server-side
# in postgres role + clickhouse user (CH side is on Pulse Forge, separate).
#
# This script creates the on-disk shape multica.ai expects:
#   /srv/pulse-bare.git                       — bare clone (write-PAT) for worktrees
#   /srv/agent-worktrees/agent-{1..N}/        — per-agent git worktrees
#   /home/multica/.claude/agent-{1..N}/       — per-agent claude config dirs
#   /home/multica/.claude/agent-N/settings.json → symlink to repo's agent/agent-settings.json
#
# Idempotent. Safe to re-run.
#
# Skips cleanly if AGENT_PULSE_PAT not set.
#
# Design ref: agent/README.md (multica.ai-native pattern, no Docker).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

USERNAME="${MULTICA_USER:-multica}"
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
AGENT_COUNT="${AGENT_COUNT:-2}"   # number of agents to provision; default 2
AGENT_SETTINGS_SRC="$(repo_root)/agent/agent-settings.json"

# Optional feature: skip cleanly if PATs not yet provisioned.
if [[ -z "${AGENT_PULSE_PAT:-}" ]]; then
    log_skip "Agent host prep skipped: AGENT_PULSE_PAT not set in .env"
    log_info "  To enable agent worker host setup:"
    log_info "    1. Generate fine-grained PATs for the projects you want agents to ship to"
    log_info "       (contents:read+write, repo-scoped, 90d expiry)"
    log_info "    2. Add to .env: AGENT_PULSE_PAT=...  AGENT_PLANS_PAT=..."
    log_info "       Optional: AGENT_MULTICA_PAT, AGENT_COUNT (default 2)"
    log_info "    3. Re-run: sudo ./bootstrap.sh 14"
    exit 0
fi

require_vars AGENT_PULSE_PAT

# Sanity: multica user must already exist (04-multica-user.sh ran).
if ! id -u "$USERNAME" >/dev/null 2>&1; then
    log_error "User '$USERNAME' does not exist — run 04-multica-user.sh first"
    exit 1
fi

# Sanity: settings.json source file present.
if [[ ! -f "$AGENT_SETTINGS_SRC" ]]; then
    log_error "$AGENT_SETTINGS_SRC not found — repo state inconsistent"
    exit 1
fi

# ---- Bare clone of Pulse repo for worktree creation ----

PULSE_BARE=/srv/pulse-bare.git
if [[ ! -d "$PULSE_BARE" ]]; then
    log_info "Cloning bare Pulse repo to $PULSE_BARE..."
    PULSE_REPO_HTTPS="${PULSE_REPO_HTTPS:-https://github.com/rabbeet/Pulse.git}"
    pulse_path=${PULSE_REPO_HTTPS#https://github.com/}
    pulse_path=${pulse_path%.git}
    GH_USER="${GITHUB_USER:-rabbeet}"
    git clone --bare "https://${GH_USER}:${AGENT_PULSE_PAT}@github.com/${pulse_path}.git" "$PULSE_BARE"
    chown -R "$USERNAME":"$USERNAME" "$PULSE_BARE"
    chmod -R u+rwX,g+rX,o-rwx "$PULSE_BARE"
    log_ok "bare clone created at $PULSE_BARE (owned by $USERNAME)"
else
    log_skip "$PULSE_BARE already exists"
    # Ensure ownership is right even on re-run.
    chown -R "$USERNAME":"$USERNAME" "$PULSE_BARE" 2>/dev/null || true
fi

# Hourly fetch via systemd timer (reuse the existing context-pull pattern but for the bare clone).
TIMER=/etc/systemd/system/multica-pulse-bare-fetch.timer
SERVICE=/etc/systemd/system/multica-pulse-bare-fetch.service

cat > "$SERVICE" <<EOF
[Unit]
Description=Hourly fetch of Pulse bare clone for agent worktrees
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$USERNAME
ExecStart=/usr/bin/git -C $PULSE_BARE fetch origin main
EOF

cat > "$TIMER" <<EOF
[Unit]
Description=Hourly fetch of Pulse bare clone

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now multica-pulse-bare-fetch.timer >/dev/null
log_ok "multica-pulse-bare-fetch.timer enabled (hourly)"

# ---- Per-agent worktrees + .claude/ dirs ----

WORKTREES_BASE=/srv/agent-worktrees
mkdir -p "$WORKTREES_BASE"
chown "$USERNAME":"$USERNAME" "$WORKTREES_BASE"
chmod 750 "$WORKTREES_BASE"

# ---- multica-daemon ReadWritePaths drop-in ----
#
# multica-daemon.service runs with ProtectSystem=strict, so the daemon and
# every agent it spawns inherit a mount namespace where rootfs is ro and only
# paths in ReadWritePaths= are bind-mounted rw. The base unit (09-multica-
# daemon.sh) covers /home/multica /tmp /run, but the agent worktree paths
# created above must be added explicitly — otherwise `git checkout -b`,
# `git commit`, and `git worktree add` from inside the daemon ns fail with
# EROFS even though root (host ns) can write to them.
DAEMON_DROPIN_DIR=/etc/systemd/system/multica-daemon.service.d
DAEMON_DROPIN="$DAEMON_DROPIN_DIR/agent-worktree-rw.conf"
mkdir -p "$DAEMON_DROPIN_DIR"
DAEMON_DROPIN_CONTENT="[Service]
ReadWritePaths=$WORKTREES_BASE $PULSE_BARE
"
if [[ ! -f "$DAEMON_DROPIN" ]] || ! diff -q <(printf '%s' "$DAEMON_DROPIN_CONTENT") "$DAEMON_DROPIN" >/dev/null 2>&1; then
    printf '%s' "$DAEMON_DROPIN_CONTENT" > "$DAEMON_DROPIN"
    systemctl daemon-reload
    if systemctl is-active --quiet multica-daemon.service; then
        systemctl restart multica-daemon.service
        log_ok "multica-daemon restarted to pick up new ReadWritePaths"
    fi
    log_ok "drop-in installed: $DAEMON_DROPIN"
else
    log_skip "$DAEMON_DROPIN already up to date"
fi

CLAUDE_BASE="$USER_HOME/.claude"
mkdir -p "$CLAUDE_BASE"
chown "$USERNAME":"$USERNAME" "$CLAUDE_BASE"

for n in $(seq 1 "$AGENT_COUNT"); do
    agent_id="agent-$n"

    # Per-agent claude config dir (OAuth state lives here)
    agent_claude_dir="$CLAUDE_BASE/$agent_id"
    sudo -u "$USERNAME" mkdir -p "$agent_claude_dir"

    # Symlink shared settings.json into the per-agent dir (one source of truth)
    settings_link="$agent_claude_dir/settings.json"
    if [[ -L "$settings_link" || -e "$settings_link" ]]; then
        rm -f "$settings_link"
    fi
    sudo -u "$USERNAME" ln -sf "$AGENT_SETTINGS_SRC" "$settings_link"

    # Per-agent worktree (created from bare clone main branch)
    wt="$WORKTREES_BASE/$agent_id"
    if [[ -d "$wt" ]]; then
        log_skip "$wt already exists"
    else
        sudo -u "$USERNAME" git -C "$PULSE_BARE" worktree add -B "$agent_id/scratch" "$wt" main
        log_ok "worktree created at $wt on branch $agent_id/scratch"
    fi

    log_info "  $agent_id: claude=$agent_claude_dir worktree=$wt"
done

# ---- Sanity check: agents NOT yet OAuth-logged-in ----

log_info ""
log_info "Filesystem ready for $AGENT_COUNT agents. OAuth login is the next step:"
for n in $(seq 1 "$AGENT_COUNT"); do
    log_info "  sudo -u $USERNAME CLAUDE_CONFIG_DIR=$CLAUDE_BASE/agent-$n claude /login"
done
log_info ""
log_info "Then in multica.ai web UI, create $AGENT_COUNT agents in your workspace with:"
log_info "  custom_env: CLAUDE_CONFIG_DIR=$CLAUDE_BASE/agent-N"
log_info "  custom_args: (cwd or argv as multica.ai expects, see agent/README.md)"
log_info "  provider: claude"

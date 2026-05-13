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
#   /srv/pulse-bare.git                       — bare clone (write-PAT) for worktrees [required]
#   /srv/multica-bare.git                     — bare clone of rabbeet/multica         [optional, PUL-94]
#   /srv/agent-context-bare.git               — bare clone of rabbeet/agent-context   [optional, PUL-94]
#   /srv/agent-worktrees/agent-{1..N}/        — per-agent git worktrees (legacy schema)
#   /srv/agent-worktrees/agent-N-<uuid>/      — per-task git worktrees (new schema, daemon-created)
#   /home/multica/.claude/agent-{1..N}/       — per-agent claude config dirs
#   /home/multica/.claude/agent-N/settings.json → symlink to repo's agent/agent-settings.json
#
# Idempotent. Safe to re-run.
#
# Skips cleanly if AGENT_PULSE_PAT not set.
# Non-Pulse bares (multica, agent-context) are provisioned only if their
# matching PAT is set in .env. Daemon's per-task-worktree feature (PUL-94)
# needs these to support tasks with target_repo != Pulse.
#
# Design refs:
#   agent/README.md  — multica.ai-native pattern, no Docker.
#   plans://Multica/2026-05-12-pul-94-agent-worktree-per-task.md — multi-repo bares.

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
GH_USER="${GITHUB_USER:-rabbeet}"

# Optional feature: skip cleanly if PATs not yet provisioned.
if [[ -z "${AGENT_PULSE_PAT:-}" ]]; then
    log_skip "Agent host prep skipped: AGENT_PULSE_PAT not set in .env"
    log_info "  To enable agent worker host setup:"
    log_info "    1. Generate fine-grained PATs for the projects you want agents to ship to"
    log_info "       (contents:read+write, repo-scoped, 90d expiry)"
    log_info "    2. Add to .env:"
    log_info "         AGENT_PULSE_PAT=...          (required, for Pulse bare clone)"
    log_info "         AGENT_PLANS_PAT=...          (required, for plans repo access)"
    log_info "         AGENT_MULTICA_PAT=...        (optional, PUL-94 — for rabbeet/multica bare)"
    log_info "         AGENT_AGENT_CONTEXT_PAT=...  (optional, PUL-94 — for rabbeet/agent-context bare)"
    log_info "         AGENT_COUNT=2                (optional, default 2)"
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

# ---- Bare-repo provisioning (multi-repo, PUL-94) ----
#
# provision_bare creates a bare clone of <github_owner>/<repo_name> at
# /srv/<slug>-bare.git and installs an hourly systemd timer for `git fetch
# origin main`. Idempotent. Caller passes the PAT value (already checked
# non-empty by the caller).
#
# Adds the bare path to the global BARE_PATHS array for downstream use
# (ReadWritePaths drop-in needs the full list).
BARE_PATHS=()

provision_bare() {
    local slug="$1"          # e.g. "pulse", "multica", "agent-context"
    local repo_path="$2"     # e.g. "rabbeet/Pulse" — <owner>/<name>
    local pat="$3"           # PAT value (caller-checked non-empty)
    local bare_path="/srv/${slug}-bare.git"

    if [[ ! -d "$bare_path" ]]; then
        log_info "Cloning bare $repo_path to $bare_path..."
        git clone --bare "https://${GH_USER}:${pat}@github.com/${repo_path}.git" "$bare_path"
        chown -R "$USERNAME":"$USERNAME" "$bare_path"
        chmod -R u+rwX,g+rX,o-rwx "$bare_path"
        log_ok "bare clone created at $bare_path (owned by $USERNAME)"
    else
        log_skip "$bare_path already exists"
        # Ensure ownership is right even on re-run.
        chown -R "$USERNAME":"$USERNAME" "$bare_path" 2>/dev/null || true
    fi

    # Hourly fetch via systemd timer.
    local unit_name="multica-${slug}-bare-fetch"
    local service="/etc/systemd/system/${unit_name}.service"
    local timer="/etc/systemd/system/${unit_name}.timer"

    cat > "$service" <<EOF
[Unit]
Description=Hourly fetch of $repo_path bare clone for agent worktrees
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$USERNAME
ExecStart=/usr/bin/git -C $bare_path fetch origin main
EOF

    cat > "$timer" <<EOF
[Unit]
Description=Hourly fetch of $repo_path bare clone

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${unit_name}.timer" >/dev/null
    log_ok "${unit_name}.timer enabled (hourly)"

    BARE_PATHS+=("$bare_path")
}

# Pulse — required (script exits above if AGENT_PULSE_PAT not set).
PULSE_REPO_HTTPS="${PULSE_REPO_HTTPS:-https://github.com/rabbeet/Pulse.git}"
pulse_path=${PULSE_REPO_HTTPS#https://github.com/}
pulse_path=${pulse_path%.git}
provision_bare "pulse" "$pulse_path" "$AGENT_PULSE_PAT"

# Pin canonical Pulse bare path for the per-agent (legacy) worktree section below.
# Per-task worktrees (PUL-94, daemon-created) use whichever bare matches the task's
# target_repo and live alongside the legacy per-agent worktrees in /srv/agent-worktrees/.
PULSE_BARE="${BARE_PATHS[0]}"

# multica — optional (PUL-94, daemon target_repo=rabbeet/multica).
if [[ -n "${AGENT_MULTICA_PAT:-}" ]]; then
    provision_bare "multica" "rabbeet/multica" "$AGENT_MULTICA_PAT"
else
    log_info "AGENT_MULTICA_PAT not set — skipping /srv/multica-bare.git (per-task tasks for rabbeet/multica will fail to spawn until provisioned)"
fi

# agent-context — optional (PUL-94, daemon target_repo=rabbeet/agent-context).
if [[ -n "${AGENT_AGENT_CONTEXT_PAT:-}" ]]; then
    provision_bare "agent-context" "rabbeet/agent-context" "$AGENT_AGENT_CONTEXT_PAT"
else
    log_info "AGENT_AGENT_CONTEXT_PAT not set — skipping /srv/agent-context-bare.git"
fi

# ---- Worktree base + per-agent worktrees (legacy schema, preserved during PUL-94 rollout) ----

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
# and every bare repo must be added explicitly — otherwise `git checkout -b`,
# `git commit`, and `git worktree add` from inside the daemon ns fail with
# EROFS even though root (host ns) can write to them.
#
# Bare repos need RW because `git worktree add` writes to <bare>/worktrees/<name>.
DAEMON_DROPIN_DIR=/etc/systemd/system/multica-daemon.service.d
DAEMON_DROPIN="$DAEMON_DROPIN_DIR/agent-worktree-rw.conf"
mkdir -p "$DAEMON_DROPIN_DIR"
DAEMON_DROPIN_CONTENT="[Service]
ReadWritePaths=$WORKTREES_BASE ${BARE_PATHS[*]}
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

    # Per-agent worktree (created from Pulse bare clone main branch).
    # Legacy schema — used by the daemon when MULTICA_USE_PER_TASK_WORKTREE=false
    # OR for tasks that pre-date the per-task-worktree column (target_repo_id NULL).
    # Per-task worktrees (PUL-94) are created by the daemon at task spawn time
    # under /srv/agent-worktrees/<agent>-<task_uuid[:8]>/ — same parent dir, distinct
    # naming pattern, covered by the same ReadWritePaths above.
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
log_info "Filesystem ready for $AGENT_COUNT agents. Bare repos provisioned:"
for bp in "${BARE_PATHS[@]}"; do
    log_info "  $bp"
done
log_info ""
log_info "OAuth login is the next step:"
for n in $(seq 1 "$AGENT_COUNT"); do
    log_info "  sudo -u $USERNAME CLAUDE_CONFIG_DIR=$CLAUDE_BASE/agent-$n claude /login"
done
log_info ""
log_info "Then in multica.ai web UI, create $AGENT_COUNT agents in your workspace with:"
log_info "  custom_env: CLAUDE_CONFIG_DIR=$CLAUDE_BASE/agent-N"
log_info "  custom_args: (cwd or argv as multica.ai expects, see agent/README.md)"
log_info "  provider: claude"

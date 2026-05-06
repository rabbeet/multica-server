#!/usr/bin/env bash
# 13-context-clones.sh — clone Pulse code + agent-context (DB schema dumps) for
# brainstorm-Claude to read. Adds host-side hourly `git fetch + reset --hard`
# via systemd timer. Read-only at the user-permission level.
#
# Architecture note: brainstorm-Claude runs as user 'multica' on the host
# (NOT in a sandboxed container — see commit 0e9f447 pivot to host-process
# daemon). Read-only-ness is provided by:
#   1. Linux file mode (clones owned root:multica, 750 — multica reads, root writes)
#   2. ~multica/.claude/settings.json — only Read() is allowed on these paths,
#      no Edit/Write/Bash mutating commands
#
# The `agent-context` repo is auto-populated by Pulse Forge's
# `agent-context:dump pulse` artisan command (separate work, in Pulse repo).
# This script only handles the multica-server side: clone + hourly pull.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

USERNAME="${MULTICA_USER:-multica}"

# Defaults — override via .env if your owner/repo differs.
PULSE_REPO_HTTPS="${PULSE_REPO_HTTPS:-https://github.com/rabbeet/Pulse.git}"
AGENT_CONTEXT_REPO_HTTPS="${AGENT_CONTEXT_REPO_HTTPS:-https://github.com/rabbeet/agent-context.git}"

# Optional feature: skip cleanly if PATs not yet provisioned. Lets bootstrap
# complete on a fresh deploy where the user hasn't added these PATs to .env yet.
if [[ -z "${PULSE_READONLY_PAT:-}" || -z "${AGENT_CONTEXT_READONLY_PAT:-}" || -z "${GITHUB_USER:-}" ]]; then
    log_skip "Context-clones skipped: PULSE_READONLY_PAT and/or AGENT_CONTEXT_READONLY_PAT not set in .env"
    log_info "  To enable Pulse-code + DB-context for brainstorm Claude:"
    log_info "    1. Generate fine-grained PATs (contents:read) for rabbeet/Pulse and rabbeet/agent-context"
    log_info "    2. Add to .env: PULSE_READONLY_PAT=...  AGENT_CONTEXT_READONLY_PAT=..."
    log_info "    3. Re-run: sudo ./bootstrap.sh 13"
    exit 0
fi

PULSE_DIR=/srv/pulse-code
CTX_DIR=/srv/agent-context

# Sanity: multica user must already exist (04-multica-user.sh ran).
if ! id -u "$USERNAME" >/dev/null 2>&1; then
    log_error "User '$USERNAME' does not exist — run 04-multica-user.sh first"
    exit 1
fi

# ---- Set up root's git credential store ----
# Both PATs land in /root/.git-credentials (mode 600 root:root) — never readable
# by user 'multica'. We use credential.useHttpPath so two different PATs on the
# same host (github.com) can be disambiguated by repo path.
ROOT_GIT_CRED=/root/.git-credentials

# Strip "https://" prefix and any trailing ".git" — store helper matches by
# (host, path) tuple. Write both with-.git and without-.git forms to be safe.
pulse_path=${PULSE_REPO_HTTPS#https://github.com/}
ctx_path=${AGENT_CONTEXT_REPO_HTTPS#https://github.com/}
pulse_path_nogit=${pulse_path%.git}
ctx_path_nogit=${ctx_path%.git}

umask 077
{
    echo "https://${GITHUB_USER}:${PULSE_READONLY_PAT}@github.com/${pulse_path}"
    echo "https://${GITHUB_USER}:${PULSE_READONLY_PAT}@github.com/${pulse_path_nogit}"
    echo "https://${GITHUB_USER}:${AGENT_CONTEXT_READONLY_PAT}@github.com/${ctx_path}"
    echo "https://${GITHUB_USER}:${AGENT_CONTEXT_READONLY_PAT}@github.com/${ctx_path_nogit}"
} > "$ROOT_GIT_CRED"
chmod 600 "$ROOT_GIT_CRED"
chown root:root "$ROOT_GIT_CRED"
umask 022
log_ok "/root/.git-credentials configured (2 PATs, useHttpPath scoped)"

# ---- Helper: clone a repo, strip creds from URL, configure per-repo helper ----
clone_readonly() {
    local target="$1" repo_https="$2" pat="$3" label="$4"; shift 4
    local extra_args=("$@")

    if [[ -d "$target/.git" ]]; then
        log_skip "$label already cloned at $target"
        return 0
    fi

    log_info "Cloning $label into $target..."
    local auth_url="${repo_https/https:\/\//https://${GITHUB_USER}:${pat}@}"
    git clone "${extra_args[@]}" "$auth_url" "$target"

    # Strip creds from saved remote URL.
    git -C "$target" remote set-url origin "$repo_https"

    # Per-repo credential helper (NOT --system, NOT --global) — root only.
    git -C "$target" config credential.helper "store --file=$ROOT_GIT_CRED"
    git -C "$target" config credential.useHttpPath true

    # Ownership: root:multica, files g+r so multica can READ but never WRITE.
    chown -R root:"$USERNAME" "$target"
    chmod -R u=rwX,g=rX,o= "$target"

    log_ok "Cloned $label"
}

# ---- Clone Pulse (shallow, single-branch — we only need main for code reading) ----
mkdir -p "$PULSE_DIR"
clone_readonly "$PULSE_DIR" "$PULSE_REPO_HTTPS" "$PULSE_READONLY_PAT" "Pulse" \
    --depth 1 --single-branch --branch main

# ---- Clone agent-context (full history — AUDIT.md diff needs it) ----
mkdir -p "$CTX_DIR"
clone_readonly "$CTX_DIR" "$AGENT_CONTEXT_REPO_HTTPS" "$AGENT_CONTEXT_READONLY_PAT" "agent-context"

# ---- Pull script (called by systemd timer) ----
PULL_SCRIPT=/usr/local/sbin/multica-context-pull
cat > "$PULL_SCRIPT" <<EOF
#!/usr/bin/env bash
# Auto-generated by 13-context-clones.sh — do not edit.
#
# Pulls fresh main into /srv/pulse-code and /srv/agent-context. Runs hourly
# via multica-context-pull.timer. Logs to journalctl.
#
# Local mods are NOT expected on these mirrors (no one writes to them — only
# this script does). If git status --porcelain is non-empty before fetch, log
# a warning before reset --hard so silent corruption doesn't go unnoticed.

set -uo pipefail   # not -e: we want to retry the second dir if first fails
exec 2>&1

for dir in $PULSE_DIR $CTX_DIR; do
    if [[ ! -d "\$dir/.git" ]]; then
        logger -t multica-context-pull -p user.err "\$dir is not a git clone — skipping"
        continue
    fi

    if [[ -n "\$(git -C "\$dir" status --porcelain 2>/dev/null)" ]]; then
        logger -t multica-context-pull -p user.warning "\$dir has unexpected local changes; resetting"
    fi

    if ! git -C "\$dir" fetch --quiet origin; then
        logger -t multica-context-pull -p user.err "\$dir: git fetch failed"
        continue
    fi

    # Default branch is main for both repos
    if ! git -C "\$dir" reset --hard --quiet origin/main; then
        logger -t multica-context-pull -p user.err "\$dir: git reset --hard origin/main failed"
        continue
    fi

    logger -t multica-context-pull -p user.info "\$dir: pulled to \$(git -C "\$dir" rev-parse --short HEAD)"
done
EOF
chmod 750 "$PULL_SCRIPT"
chown root:root "$PULL_SCRIPT"
log_ok "Installed $PULL_SCRIPT"

# ---- systemd service ----
cat > /etc/systemd/system/multica-context-pull.service <<EOF
[Unit]
Description=Pull fresh main for /srv/pulse-code + /srv/agent-context
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$PULL_SCRIPT
User=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

# ---- systemd timer (hourly + on boot) ----
cat > /etc/systemd/system/multica-context-pull.timer <<EOF
[Unit]
Description=Hourly pull for multica context clones (Pulse code + agent-context)

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now multica-context-pull.timer
log_ok "systemd timer enabled (hourly + on boot)"

# ---- Run one pull now to confirm ----
log_info "Running one pull now to verify..."
if systemctl start multica-context-pull.service; then
    log_ok "Initial pull succeeded"
    pulse_sha=$(git -C "$PULSE_DIR" rev-parse --short HEAD 2>/dev/null || echo "?")
    ctx_sha=$(git -C "$CTX_DIR" rev-parse --short HEAD 2>/dev/null || echo "?")
    log_info "  /srv/pulse-code     @ $pulse_sha"
    log_info "  /srv/agent-context  @ $ctx_sha"
else
    log_warn "Initial pull failed — check: journalctl -t multica-context-pull"
fi

# ---- Surface staleness of pulse-context dump ----
INDEX="$CTX_DIR/pulse/INDEX.md"
if [[ -f "$INDEX" ]]; then
    if last_dump=$(grep -m1 -E '^last_dump_at:' "$INDEX" | sed 's/^last_dump_at:[[:space:]]*//'); then
        log_info "agent-context/pulse last_dump_at: $last_dump"
    fi
else
    log_warn "$INDEX not present yet — Pulse Forge artisan command may not have run yet"
    log_info "  (this is expected on first deploy; cron on Forge populates it daily)"
fi

log_ok "13-context-clones complete"

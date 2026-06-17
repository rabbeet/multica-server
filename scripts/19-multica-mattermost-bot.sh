#!/usr/bin/env bash
# 19-multica-mattermost-bot.sh — install the multica-mattermost-bot daemon
# on the brainstorm-VPS. Bridges a Mattermost channel into multica issues in
# the marimo project (PUL-328).
#
# What this script does:
#   1. Installs chromium-headless + xvfb (Lane C screenshot pipeline).
#   2. Drops the systemd unit, EnvironmentFile, and op-read-env wrapper.
#   3. Creates /var/lib/multica-mattermost-bot with the right owner.
#   4. Enables (but does NOT start) the service — start requires the
#      operator to populate /etc/multica-mattermost-bot.env first.
#
# The bot binary itself is produced by `make build` in rabbeet/multica
# (lands at server/bin/multica-mattermost-bot). Symlinking it into
# /usr/local/bin is outside this script — the brainstorm host bootstrap
# already handles binary deployment for the multica suite via
# scripts/02-multica-cli.sh; see runbook for the manual symlink path.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root

USERNAME="${MULTICA_USER:-multica}"
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
STATE_DIR=/var/lib/multica-mattermost-bot
ENV_FILE=/etc/multica-mattermost-bot.env
UNIT_FILE=/etc/systemd/system/multica-mattermost-bot.service
OP_READ=/usr/local/bin/multica-mattermost-bot-op-read

# ---- 1. host dependencies (chromium-headless for screenshot pipeline) ----
log_info "Installing chromium-headless + xvfb for screenshot pipeline..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    chromium \
    fonts-noto-color-emoji \
    fonts-noto-cjk
log_ok "chromium installed"

# 1Password CLI is required to resolve MM_BOT_TOKEN at startup time.
# It is provided by 01-host-deps.sh on this VPS; we just verify presence.
if ! command -v op >/dev/null 2>&1; then
    log_error "1Password CLI (op) not found — install via 01-host-deps.sh first"
    exit 1
fi

# ---- 2. state dir + env file scaffold ----
mkdir -p "$STATE_DIR"
chown "$USERNAME:$USERNAME" "$STATE_DIR"
chmod 0750 "$STATE_DIR"
log_ok "state dir $STATE_DIR owned by $USERNAME"

if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<'EOF'
# /etc/multica-mattermost-bot.env — populated by the operator before
# `systemctl start multica-mattermost-bot`. NEVER commit this file.
#
# After editing, restart: `systemctl restart multica-mattermost-bot`.
#
# Required:
MM_HOST=https://mattermost.example.com
MM_BOT_USER_ID=REPLACE_ME_with_bot_user_id_from_MM
MM_ALLOWED_CHANNELS=REPLACE_ME_with_channel_ids_csv
MM_ALLOWED_USER_IDS=REPLACE_ME_with_lina_and_vadim_user_ids_csv
MMBOT_ASSIGNEE_AGENT_ID=a7fd2cf7-c767-4427-9632-d1e79ce10e17

# Optional — defaults documented in server/cmd/multica-mattermost-bot/config.go:
# MMBOT_AGENT_AUTHOR_ID=
# MMBOT_STATE_DB_PATH=/var/lib/multica-mattermost-bot/state.db
# MARIMO_LOCAL_URL=http://127.0.0.1:2718
# MARIMO_TAILNET_HOSTNAME_HINT=ts.net
# MMBOT_POLL_INTERVAL=5s

# MM_BOT_TOKEN is resolved at startup by /usr/local/bin/multica-mattermost-bot-op-read
# from 1Password (op://Pulse-Dev/Pulse-env/MM_BOT_TOKEN). Do NOT set it here.
EOF
    chown root:"$USERNAME" "$ENV_FILE"
    chmod 0640 "$ENV_FILE"
    log_ok "scaffold env file at $ENV_FILE (operator must fill REPLACE_ME values)"
else
    log_skip "$ENV_FILE already exists"
fi

# ---- 3. op-read wrapper ----
cat > "$OP_READ" <<'EOF'
#!/usr/bin/env bash
# Read MM_BOT_TOKEN from 1Password and write a tmpfs env file the systemd unit
# will source via EnvironmentFile=. Runs as ExecStartPre before the daemon.
#
# Assumes OP_SERVICE_ACCOUNT_TOKEN is exported in the unit Environment= line
# (already injected for the multica user by other scripts).
set -euo pipefail
out="$1"
if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    echo "ERROR: OP_SERVICE_ACCOUNT_TOKEN not set; cannot resolve MM_BOT_TOKEN" >&2
    exit 1
fi
tok=$(op read "op://Pulse-Dev/Pulse-env/MM_BOT_TOKEN")
if [[ -z "$tok" ]]; then
    echo "ERROR: op returned empty MM_BOT_TOKEN" >&2
    exit 1
fi
umask 077
printf 'MM_BOT_TOKEN=%s\n' "$tok" > "$out"
EOF
chmod 0755 "$OP_READ"
log_ok "op-read wrapper installed at $OP_READ"

# ---- 4. systemd unit ----
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Multica Mattermost Bot (bridges marimo project to a Mattermost channel)
Documentation=https://github.com/rabbeet/multica-server/blob/main/docs/mattermost-bot.md
Documentation=https://github.com/rabbeet/plans/blob/main/Multica/2026-06-17-pul-328-mattermost-bot-marimo.md
After=network-online.target
Wants=network-online.target
ConditionPathExists=$ENV_FILE
ConditionPathExists=/usr/local/bin/multica-mattermost-bot

[Service]
Type=simple
User=$USERNAME
Group=$USERNAME
WorkingDirectory=$STATE_DIR

# Operator-supplied env (non-secret) + 1Password-resolved MM_BOT_TOKEN.
EnvironmentFile=$ENV_FILE
EnvironmentFile=-/run/multica-mattermost-bot/secrets.env
Environment=HOME=$USER_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin
# OP_SERVICE_ACCOUNT_TOKEN is read from the OP file (managed by host bootstrap).
EnvironmentFile=-/etc/multica/op-service-account.env

# Resolve MM_BOT_TOKEN from 1Password into tmpfs before launch.
RuntimeDirectory=multica-mattermost-bot
RuntimeDirectoryMode=0750
ExecStartPre=$OP_READ /run/multica-mattermost-bot/secrets.env

ExecStart=/usr/local/bin/multica-mattermost-bot
Restart=on-failure
RestartSec=10s

# Security hardening — keep the blast radius small if the bot is ever exploited.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$STATE_DIR
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
SystemCallArchitectures=native
# Outbound networking only — there are no listeners.
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Memory and process caps.
MemoryMax=1G
MemoryHigh=512M
TasksMax=128

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable multica-mattermost-bot.service
log_ok "Installed and enabled systemd unit (not started yet — operator action required)"

# ---- 5. next steps ----
log_info ""
log_info "==================================================================="
log_info "  multica-mattermost-bot installed. Next steps (operator):"
log_info "==================================================================="
log_info ""
log_info "  1. Build & place the binary on this host:"
log_info "     (from rabbeet/multica checkout)"
log_info "       make build"
log_info "       sudo install -m 0755 server/bin/multica-mattermost-bot \\"
log_info "         /usr/local/bin/multica-mattermost-bot"
log_info ""
log_info "  2. In Mattermost (one-time):"
log_info "     - Create bot account 'multica-bot' (System Console → Bot Accounts)."
log_info "     - Generate a Personal Access Token; copy the value."
log_info "     - Add bot to the #data-requests channel."
log_info "     - Collect bot's user_id and the channel_id."
log_info ""
log_info "  3. Store MM_BOT_TOKEN in 1Password:"
log_info "     op item edit Pulse-env MM_BOT_TOKEN='<token-here>' --vault Pulse-Dev"
log_info ""
log_info "  4. Edit $ENV_FILE and replace every REPLACE_ME value."
log_info ""
log_info "  5. Start:"
log_info "       systemctl start multica-mattermost-bot"
log_info "       systemctl status multica-mattermost-bot"
log_info "       journalctl -u multica-mattermost-bot -f"
log_info ""
log_info "  Full runbook: docs/mattermost-bot.md"
log_info "==================================================================="

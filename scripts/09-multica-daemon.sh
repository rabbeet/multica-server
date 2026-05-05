#!/usr/bin/env bash
# 09-multica-daemon.sh — install systemd unit for `multica daemon` running as
# user multica. The daemon scans $PATH for AI CLIs (claude, codex, ...) and
# orchestrates them on behalf of the multica web UI.
#
# We do NOT autostart `multica daemon` here — it requires interactive `multica login`
# first (browser OAuth or PAT). Bootstrap prints the next step.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

USERNAME="${MULTICA_USER:-multica}"
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)

# ---- systemd unit ----
UNIT_FILE=/etc/systemd/system/multica-daemon.service
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Multica daemon (orchestrates AI CLIs spawned via multica web UI)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=$USERNAME
Group=$USERNAME
WorkingDirectory=$USER_HOME
Environment=HOME=$USER_HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$USER_HOME/.local/bin
ExecStart=/usr/local/bin/multica daemon start --foreground
Restart=on-failure
RestartSec=10

# Security hardening (host process; not as strong as containerization)
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$USER_HOME /tmp /run
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
SystemCallArchitectures=native

# Memory limits
MemoryMax=4G
MemoryHigh=2G

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
log_ok "Installed systemd unit: multica-daemon.service"

# ---- Enable but don't start (needs login first) ----
systemctl enable multica-daemon.service
log_ok "Enabled multica-daemon.service (start after `multica login`)"

# ---- Print next steps ----
log_info ""
log_info "==================================================================="
log_info "Next: interactive setup (one-time)"
log_info "==================================================================="
log_info ""
log_info "  1. Auth Claude Code as the multica user:"
log_info "     sudo -u $USERNAME -i"
log_info "     claude /login   # opens browser flow"
log_info "     exit"
log_info ""
log_info "  2. Auth multica CLI as the multica user:"
log_info "     sudo -u $USERNAME -i"
log_info "     multica login   # opens browser flow"
log_info "     exit"
log_info ""
log_info "  3. Start the daemon:"
log_info "     systemctl start multica-daemon"
log_info "     systemctl status multica-daemon"
log_info ""
log_info "  4. (Or test interactively first):"
log_info "     sudo -u $USERNAME -i multica daemon start"
log_info ""
log_ok "09-multica-daemon complete"

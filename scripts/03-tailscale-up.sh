#!/usr/bin/env bash
# 03-tailscale-up.sh — join tailnet, advertise tag, enable SSH.
#
# Idempotent: skips if already running and authenticated.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env
require_vars TAILSCALE_AUTHKEY TAILNET_NAME

# ---- Verify daemon installed -------------------------------------------------
if ! command -v tailscale >/dev/null 2>&1; then
    log_error "tailscale not installed. Run 01-host-deps.sh first."
    exit 1
fi

# ---- Skip if already authenticated -------------------------------------------
# Use --json + jq because text output format may change.
if tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null 2>&1; then
    current_user=$(tailscale status --json | jq -r '.Self.UserID // .CurrentTailnet.Name // "unknown"')
    log_skip "Tailscale already running (BackendState=Running)"
    log_info "  Current node: $(tailscale status --json | jq -r '.Self.HostName // "unknown"')"
    log_info "  Tailnet:      $(tailscale status --json | jq -r '.MagicDNSSuffix // "unknown"')"
    exit 0
fi

# ---- Bring up daemon if needed -----------------------------------------------
if ! systemctl is-active tailscaled >/dev/null 2>&1; then
    log_info "Starting tailscaled..."
    systemctl enable --now tailscaled
fi

# ---- Tailscale up with auth key ---------------------------------------------
HOSTNAME_ARG="${TAILSCALE_HOSTNAME:-multica}"

log_info "Joining tailnet ${TAILNET_NAME} as '${HOSTNAME_ARG}'..."
tailscale up \
    --authkey="${TAILSCALE_AUTHKEY}" \
    --hostname="${HOSTNAME_ARG}" \
    --advertise-tags=tag:multica-host \
    --ssh \
    --accept-dns=true

# ---- Verify ------------------------------------------------------------------
sleep 2
if ! tailscale status --json | jq -e '.BackendState == "Running"' >/dev/null 2>&1; then
    log_error "Tailscale up did not result in Running state"
    tailscale status
    exit 1
fi

assigned_ip=$(tailscale ip -4 2>/dev/null | head -1)
magic_dns=$(tailscale status --json | jq -r '.MagicDNSSuffix')

log_ok "Joined tailnet"
log_info "  Tailnet:    ${magic_dns}"
log_info "  IP (v4):    ${assigned_ip}"
log_info "  IP (v6):    $(tailscale ip -6 2>/dev/null | head -1 || echo 'n/a')"
log_info "  Hostname:   ${HOSTNAME_ARG}.${magic_dns}"

# ---- Cert provisioning (Caddy will use these via tailscale serve) ------------
# Pre-fetch cert so Caddy doesn't block on first request.
log_info "Pre-fetching Tailscale TLS cert..."
tailscale cert "${HOSTNAME_ARG}.${magic_dns}" 2>/dev/null || \
    log_warn "Cert fetch failed; will retry on first https request"

log_ok "03-tailscale-up complete"

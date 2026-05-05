#!/usr/bin/env bash
# 10-tailscale-serve.sh — expose multica frontend over HTTPS on tailnet only.
#
# Tailscale Serve handles TLS termination via MagicDNS cert (auto-renewed).
# Result: https://multica.<tailnet>.ts.net works from any tailnet device,
# multica's plain http://localhost:3000 stays local-only.
#
# This replaces the Caddy reverse proxy from the original design.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

# ---- Sanity ----
if ! tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null; then
    log_error "Tailscale not in Running state — run 03-tailscale-up.sh first"
    exit 1
fi

# ---- Idempotent: check current serve config ----
current=$(tailscale serve status --json 2>/dev/null || echo '{}')
if echo "$current" | jq -e '.Web."${TAILSCALE_HOSTNAME:-multica}:443"' >/dev/null 2>&1; then
    log_skip "tailscale serve already configured for HTTPS:443"
    tailscale serve status
    exit 0
fi

# ---- Reset any existing serve config ----
log_info "Clearing any existing tailscale serve config..."
tailscale serve reset || true

# ---- Configure HTTPS:443 → multica frontend (localhost:3000) ----
log_info "Configuring tailscale serve: HTTPS:443 -> localhost:3000 (multica frontend)..."
# Try simplest form first (1.94+); fall back to verbose syntax for older.
if ! tailscale serve --bg http://localhost:3000 2>/dev/null; then
    log_info "Simple form failed; trying explicit https:443 form..."
    if ! tailscale serve --bg https:443 / http://localhost:3000 2>/dev/null; then
        log_info "Both forms failed; trying --tls-terminated-tcp..."
        tailscale serve --bg --tls-terminated-tcp=443 tcp://localhost:3000
    fi
fi

# ---- Show config ----
log_info ""
log_info "Tailscale serve configuration:"
tailscale serve status

# ---- Print URL ----
hostname=$(tailscale status --json | jq -r '.Self.HostName')
magic_dns=$(tailscale status --json | jq -r '.MagicDNSSuffix')
log_info ""
log_info "Multica accessible at:"
log_info "  https://${hostname}.${magic_dns}"
log_info "  (only from devices in tailnet ${magic_dns})"

log_ok "10-tailscale-serve complete"

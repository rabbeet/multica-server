#!/usr/bin/env bash
# 10-tailscale-serve.sh — expose multica frontend over HTTPS on tailnet only.
#
# Tailscale Serve handles TLS termination via MagicDNS cert (auto-renewed).
# Result: https://multica.<tailnet>.ts.net works from any tailnet device,
# multica's plain http://localhost:3000 stays local-only.
#
# This replaces the Caddy reverse proxy from the original design.
#
# PUL-166 invariant (added in PR4 of the polling cutover): NO Funnel.
# Tailscale Funnel publishes the host's tailnet hostname in PUBLIC DNS,
# which breaks iCloud Private Relay on iPhone Safari (PUL-160 root
# cause). The webhook ingress that used Funnel has been replaced by
# outbound polling (server/internal/githubpoll in rabbeet/multica).
# This script now explicitly tears any Funnel route down on every
# re-run so an operator that flipped Funnel back on by mistake gets
# it cleared at next deploy.

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

# ---- PUL-166: enforce no-Funnel invariant on every run ----
# `tailscale funnel ... off` is idempotent — no-op if Funnel was
# already off. We hit the documented ports (:8443 is what PUL-166
# was using; :443 is included for belt-and-braces if a future
# config ever published frontend on Funnel). Errors are tolerated
# because older tailscaled versions return non-zero when the port
# was already off; the post-run check below is the source of truth.
log_info "Enforcing PUL-166 invariant: Funnel must be off..."
tailscale funnel --bg=false 8443 off 2>/dev/null || true
tailscale funnel --bg=false 443 off 2>/dev/null || true
if tailscale serve status 2>/dev/null | grep -qi "Funnel on"; then
    log_error "Funnel still on after explicit off — manual intervention required."
    log_error "Run: tailscale funnel reset; tailscale serve status"
    log_error "See docs/PUL-166-CUTOVER.md for the canonical cutover sequence."
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

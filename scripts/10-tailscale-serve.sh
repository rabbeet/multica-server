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
# `tailscale funnel reset` clears all funnel routes for this node.
# Idempotent: when no funnels are configured, the command is a
# no-op. Reset rather than per-port `... off` because the CLI
# shape changed in tailscale 1.94 — `funnel <port> off` is no
# longer valid (the new shape is `tailscale funnel <target>` for
# enable; `reset` for disable-everything).
log_info "Enforcing PUL-166 invariant: Funnel must be off..."
tailscale funnel reset 2>&1 || {
    log_error "tailscale funnel reset failed — see error above."
    log_error "Manual check: tailscale serve status --json | jq .AllowFunnel"
    exit 1
}

# Post-check via JSON, not text grep. Text output contains a
# literal `# Funnel on:` comment header even when Funnel is off
# (in some tailscaled versions), which makes `grep "Funnel on"`
# a false-positive landmine. AllowFunnel is the source of truth.
if tailscale serve status --json 2>/dev/null \
    | jq -e '(.AllowFunnel // {}) | to_entries | length > 0' >/dev/null; then
    log_error "Funnel still configured after reset — manual intervention required."
    log_error "Inspect: tailscale serve status --json | jq .AllowFunnel"
    log_error "See docs/PUL-166-CUTOVER.md for the canonical cutover sequence."
    exit 1
fi

# ---- Idempotent: check current serve config ----
# Build the FQDN key from the runtime config so jq sees the actual
# string. Earlier versions of this check used '${TAILSCALE_HOSTNAME:-multica}'
# inside single-quoted jq, which left the literal placeholder in the
# expression — guaranteed false. The key in `tailscale serve status
# --json` is the FQDN ("multica.tail38d0e3.ts.net:443"), not the
# bare hostname.
ts_fqdn="$(tailscale status --json | jq -r '.Self.DNSName | sub("\\.$"; "")' 2>/dev/null || echo '')"
current=$(tailscale serve status --json 2>/dev/null || echo '{}')
if [[ -n "$ts_fqdn" ]] && echo "$current" | \
    jq -e --arg key "${ts_fqdn}:443" '.Web[$key]' >/dev/null 2>&1; then
    log_skip "tailscale serve already configured for HTTPS:443 on $ts_fqdn"
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

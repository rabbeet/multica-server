#!/usr/bin/env bash
# 99-verify.sh — comprehensive health check after bootstrap.
# Can be run anytime to validate that everything is still working.
# Exit code: 0 = all good, non-zero = at least one check failed.

set -uo pipefail   # NOTE: not -e — we want all checks to run even if one fails
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_env

REPO=$(repo_root)
FAILS=0

check() {
    local name="$1"; shift
    if "$@"; then
        log_ok "$name"
    else
        log_error "$name FAILED"
        FAILS=$((FAILS+1))
    fi
}

# =============================================================================
# Section 1: Host services we depend on
# =============================================================================
log_info "=== Host services ==="
check "postgresql active"   systemctl is-active --quiet postgresql
check "redis-server active" systemctl is-active --quiet redis-server
check "docker active"       systemctl is-active --quiet docker
check "tailscaled active"   systemctl is-active --quiet tailscaled

# =============================================================================
# Section 2: Tailscale
# =============================================================================
log_info ""
log_info "=== Tailscale ==="
check "tailscale BackendState=Running" \
    bash -c "tailscale status --json | jq -e '.BackendState == \"Running\"' >/dev/null"

# Cert ready?
HOSTNAME_FQDN="${TAILSCALE_HOSTNAME:-multica}.${TAILNET_NAME}"
if tailscale cert "$HOSTNAME_FQDN" >/dev/null 2>&1; then
    log_ok "tailscale cert for $HOSTNAME_FQDN ready"
else
    log_warn "tailscale cert for $HOSTNAME_FQDN not yet provisioned (will fetch on first request)"
fi

# Key expiry warning
if tailscale status --json 2>/dev/null | jq -e '.Self.KeyExpiry' >/dev/null 2>&1; then
    expiry_ts=$(tailscale status --json | jq -r '.Self.KeyExpiry')
    expiry_epoch=$(date -d "$expiry_ts" +%s 2>/dev/null || echo 0)
    now=$(date +%s)
    days_left=$(( (expiry_epoch - now) / 86400 ))
    if [[ $days_left -lt 14 ]]; then
        log_warn "Tailscale key expires in $days_left days! Re-auth in admin console."
    else
        log_ok "Tailscale key valid for $days_left more days"
    fi
fi

# =============================================================================
# Section 3: Postgres (multica DB connectivity)
# =============================================================================
log_info ""
log_info "=== Postgres ==="
check "multica role exists" \
    bash -c "sudo -u postgres psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'\" | grep -q 1"
check "multica database exists" \
    bash -c "sudo -u postgres psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'\" | grep -q 1"
check "multica DB reachable from local" \
    bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h 127.0.0.1 -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -tAc 'SELECT 1' | grep -q 1"

# =============================================================================
# Section 4: Docker stack
# =============================================================================
log_info ""
log_info "=== Docker stack ==="
cd "$REPO"
for svc in multica tinyproxy caddy; do
    check "$svc container running" \
        bash -c "docker ps --filter 'name=$svc' --format '{{.Names}}' | grep -q '^$svc\$'"
done

# =============================================================================
# Section 5: Container internals — REAL write+read+delete test
# =============================================================================
log_info ""
log_info "=== Container internals ==="

# Per Eng Review Reviewer Concern #3: don't just check `claude --version`,
# write+read+delete on the writable mount.
TEST_FILE="/home/claude/.claude/.verify-$$"
if docker exec multica bash -c "echo verify > $TEST_FILE && cat $TEST_FILE | grep -q verify && rm $TEST_FILE" >/dev/null 2>&1; then
    log_ok "container can write+read+delete in /home/claude/.claude/"
else
    log_error "container CANNOT write to /home/claude/.claude/ — mount problem"
    FAILS=$((FAILS+1))
fi

# Pulse-docs read-only mount (if configured)
if docker exec multica test -d /workdir/pulse-docs 2>/dev/null; then
    log_ok "pulse-docs mounted (read-only)"
else
    log_warn "pulse-docs not mounted (skipped if Pulse not on this host)"
fi

# Plans-репо writable
if docker exec multica bash -c "test -w /srv/plans-multica && cd /srv/plans-multica && git status --short" >/dev/null 2>&1; then
    log_ok "plans-multica writable from container"
else
    log_error "plans-multica NOT writable from container"
    FAILS=$((FAILS+1))
fi

# claude binary present
if docker exec multica which claude >/dev/null 2>&1; then
    log_ok "claude binary available in container"
else
    log_error "claude binary NOT in container PATH"
    FAILS=$((FAILS+1))
fi

# =============================================================================
# Section 6: Egress allowlist (negative test — should be BLOCKED)
# =============================================================================
log_info ""
log_info "=== Egress allowlist (negative test) ==="
# The container should NOT be able to reach arbitrary internet, only allowlist.
if docker exec multica curl -sS -o /dev/null -w "%{http_code}" --max-time 5 https://api.clickavia.com 2>/dev/null | grep -qE '^(0|7)'; then
    log_ok "container cannot reach api.clickavia.com (egress blocked)"
elif docker exec multica curl -sS -o /dev/null -w "%{http_code}" --max-time 5 https://api.clickavia.com 2>/dev/null | grep -qE '^[2-5]'; then
    log_error "container CAN reach api.clickavia.com — egress allowlist failed"
    FAILS=$((FAILS+1))
else
    log_warn "egress test inconclusive"
fi

# Positive test: github.com:443 must work (for git push)
if docker exec multica curl -sS -o /dev/null -w "%{http_code}" --max-time 5 https://api.github.com 2>/dev/null | grep -qE '^2'; then
    log_ok "container can reach api.github.com (allowlist works)"
else
    log_error "container CANNOT reach api.github.com — allowlist too strict"
    FAILS=$((FAILS+1))
fi

# =============================================================================
# Section 7: Plans repo — deploy access
# =============================================================================
log_info ""
log_info "=== Plans repo connectivity ==="
if [[ -d /srv/plans-multica/.git ]]; then
    if sudo -u "${MULTICA_USER:-multica}" git -C /srv/plans-multica ls-remote >/dev/null 2>&1; then
        log_ok "plans repo HTTPS ls-remote OK (PAT works)"
    else
        log_error "plans repo ls-remote failed — check BRAINSTORM_PAT in .env"
        FAILS=$((FAILS+1))
    fi
else
    log_warn "/srv/plans-multica not yet cloned"
fi

# =============================================================================
# Summary
# =============================================================================
log_info ""
log_info "==================================================================="
if [[ $FAILS -eq 0 ]]; then
    log_ok "ALL CHECKS PASSED"
    exit 0
else
    log_error "$FAILS check(s) FAILED"
    exit 1
fi

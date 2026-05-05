#!/usr/bin/env bash
# 99-verify.sh — comprehensive health check after bootstrap.
# Can be run anytime to validate that everything is still working.
# Exit code: 0 = all good, non-zero = at least one check failed.

set -uo pipefail   # NOTE: not -e — we want all checks to run even if one fails
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_env

USERNAME="${MULTICA_USER:-multica}"
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
MULTICA_REPO="$USER_HOME/multica"
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
# Section 1: Host services + binaries
# =============================================================================
log_info "=== Host environment ==="
check "docker active"        systemctl is-active --quiet docker
check "tailscaled active"    systemctl is-active --quiet tailscaled
check "multica binary"       command -v multica
check "claude binary"        command -v claude
check "multica user exists"  id -u "$USERNAME"
check "multica home present" test -d "$USER_HOME"

# =============================================================================
# Section 2: Tailscale
# =============================================================================
log_info ""
log_info "=== Tailscale ==="
check "tailscale BackendState=Running" \
    bash -c "tailscale status --json | jq -e '.BackendState == \"Running\"' >/dev/null"

if tailscale status --json 2>/dev/null | jq -e '.Self.KeyExpiry' >/dev/null 2>&1; then
    expiry_ts=$(tailscale status --json | jq -r '.Self.KeyExpiry')
    expiry_epoch=$(date -d "$expiry_ts" +%s 2>/dev/null || echo 0)
    now=$(date +%s)
    days_left=$(( (expiry_epoch - now) / 86400 ))
    if [[ $days_left -lt 14 ]]; then
        log_warn "Tailscale key expires in $days_left days"
    else
        log_ok "Tailscale key valid for $days_left more days"
    fi
fi

# Check tailscale serve config
if tailscale serve status 2>/dev/null | grep -q ':443'; then
    log_ok "tailscale serve configured (HTTPS:443 → multica)"
else
    log_warn "tailscale serve not configured (10-tailscale-serve.sh may not have run)"
fi

# =============================================================================
# Section 3: multica stack (docker compose services)
# =============================================================================
log_info ""
log_info "=== Multica stack ==="

if [[ -d "$MULTICA_REPO" ]]; then
    log_ok "multica repo at $MULTICA_REPO"

    cd "$MULTICA_REPO"

    # Check expected containers
    for svc in postgres backend frontend; do
        container=$(docker ps --filter "label=com.docker.compose.project=multica" \
                              --filter "label=com.docker.compose.service=$svc" \
                              --format '{{.Names}}' | head -1)
        if [[ -n "$container" ]]; then
            state=$(docker inspect -f '{{.State.Status}}' "$container")
            if [[ "$state" == "running" ]]; then
                log_ok "$svc container running ($container)"
            else
                log_error "$svc container state: $state"
                FAILS=$((FAILS+1))
            fi
        else
            log_error "$svc container not found"
            FAILS=$((FAILS+1))
        fi
    done

    # Backend health endpoint
    if curl -sf http://localhost:8080/health >/dev/null 2>&1; then
        log_ok "backend /health endpoint responsive"
    else
        log_error "backend /health endpoint NOT responsive"
        FAILS=$((FAILS+1))
    fi

    # Frontend reachable
    if curl -sf http://localhost:3000/ >/dev/null 2>&1; then
        log_ok "frontend reachable on :3000"
    else
        log_error "frontend NOT reachable on :3000"
        FAILS=$((FAILS+1))
    fi
else
    log_error "multica repo not cloned (06-multica-stack.sh did not run)"
    FAILS=$((FAILS+1))
fi

# =============================================================================
# Section 4: multica daemon (systemd unit)
# =============================================================================
log_info ""
log_info "=== Multica daemon ==="

if systemctl list-unit-files multica-daemon.service >/dev/null 2>&1; then
    log_ok "multica-daemon.service unit installed"

    if systemctl is-active --quiet multica-daemon.service; then
        log_ok "multica-daemon running"
    else
        log_warn "multica-daemon NOT running (interactive login needed first)"
        log_info "  $ sudo -u $USERNAME -i multica login"
        log_info "  $ systemctl start multica-daemon"
    fi
else
    log_error "multica-daemon.service not installed"
    FAILS=$((FAILS+1))
fi

# =============================================================================
# Section 5: Skills + Claude config
# =============================================================================
log_info ""
log_info "=== Brainstorm Claude config ==="
SKILLS_DIR="$USER_HOME/.claude/skills"
if [[ -d "$SKILLS_DIR" ]]; then
    n=$(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
    log_ok "$n skill(s) deployed in $SKILLS_DIR"
    for d in "$SKILLS_DIR"/*/; do
        [[ -f "$d/SKILL.md" ]] && log_info "  /$(basename "$d")"
    done
else
    log_warn "no skills deployed"
fi

if [[ -f "$USER_HOME/.claude/settings.json" ]]; then
    log_ok "claude settings.json present (deny/allow rules)"
else
    log_warn "claude settings.json NOT present — brainstorm Claude has default permissions"
fi

# =============================================================================
# Section 6: Plans repo
# =============================================================================
log_info ""
log_info "=== Plans repo ==="
PLANS_DIR=/srv/plans-multica
if [[ -d "$PLANS_DIR/.git" ]]; then
    log_ok "$PLANS_DIR cloned"

    # Check connectivity (uses fine-grained PAT in git-credentials)
    if sudo -u "$USERNAME" git -C "$PLANS_DIR" ls-remote >/dev/null 2>&1; then
        log_ok "plans repo HTTPS ls-remote OK (PAT works)"
    else
        log_error "plans repo ls-remote failed — check BRAINSTORM_PAT in .env"
        FAILS=$((FAILS+1))
    fi
else
    log_warn "$PLANS_DIR not cloned (04-multica-user.sh may not have run)"
fi

# =============================================================================
# Summary
# =============================================================================
log_info ""
log_info "==================================================================="
if [[ $FAILS -eq 0 ]]; then
    log_ok "ALL CRITICAL CHECKS PASSED"
    log_info ""
    hostname=$(tailscale status --json 2>/dev/null | jq -r '.Self.HostName // "multica"')
    magic_dns=$(tailscale status --json 2>/dev/null | jq -r '.MagicDNSSuffix // "tailnet.ts.net"')
    log_info "Multica accessible at: https://${hostname}.${magic_dns}"
    log_info ""
    log_info "Final manual steps:"
    log_info "  1. sudo -u $USERNAME -i claude /login   # brainstorm Claude OAuth"
    log_info "  2. sudo -u $USERNAME -i multica login   # multica web account"
    log_info "  3. systemctl start multica-daemon       # start daemon as service"
    exit 0
else
    log_error "$FAILS check(s) FAILED"
    exit 1
fi

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
# Section 7: Context clones (Pulse code + agent-context)
# =============================================================================
log_info ""
log_info "=== Context clones ==="

PULSE_DIR=/srv/pulse-code
CTX_DIR=/srv/agent-context

for d in "$PULSE_DIR" "$CTX_DIR"; do
    if [[ -d "$d/.git" ]]; then
        sha=$(git -C "$d" rev-parse --short HEAD 2>/dev/null || echo "?")
        log_ok "$d cloned @ $sha"
    else
        log_warn "$d not cloned (13-context-clones.sh did not run yet)"
    fi
done

if systemctl list-unit-files multica-context-pull.timer >/dev/null 2>&1; then
    if systemctl is-active --quiet multica-context-pull.timer; then
        next=$(systemctl show multica-context-pull.timer -p NextElapseUSecRealtime --value)
        log_ok "multica-context-pull.timer active (next: $next)"
    else
        log_warn "multica-context-pull.timer installed but not active"
    fi
else
    log_warn "multica-context-pull.timer not installed (13-context-clones.sh did not run)"
fi

# Staleness check on agent-context/pulse/INDEX.md
INDEX="$CTX_DIR/pulse/INDEX.md"
STALE_HOURS_THRESHOLD=30

if [[ -f "$INDEX" ]]; then
    last_dump=$(grep -m1 -E '^last_dump_at:' "$INDEX" 2>/dev/null | sed 's/^last_dump_at:[[:space:]]*//' | tr -d '"')
    if [[ -n "$last_dump" ]]; then
        last_epoch=$(date -d "$last_dump" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        if [[ "$last_epoch" -gt 0 ]]; then
            age_hours=$(( (now_epoch - last_epoch) / 3600 ))
            if [[ $age_hours -ge $STALE_HOURS_THRESHOLD ]]; then
                log_error "agent-context/pulse stale: last_dump_at=$last_dump (${age_hours}h ago, threshold=${STALE_HOURS_THRESHOLD}h)"
                FAILS=$((FAILS+1))
            else
                log_ok "agent-context/pulse fresh: ${age_hours}h ago"
            fi
        else
            log_warn "Could not parse last_dump_at='$last_dump'"
        fi
    else
        log_warn "INDEX.md present but no last_dump_at field"
    fi
else
    log_warn "$INDEX not present yet (Pulse Forge dump may not have run)"
fi

# =============================================================================
# Section 8: Agent toolchain (Go / sqlc / pnpm / node) on PATH
# =============================================================================
# Defensive: catches the class of regression where someone edits
# 01-host-deps.sh and quietly breaks an install. Without this, the failure
# only shows up later when an agent's `make setup` dies with "command not found".
log_info ""
log_info "=== Agent toolchain ==="
for tool in go sqlc pnpm node; do
    if command -v "$tool" >/dev/null 2>&1; then
        log_ok "$tool present: $(command -v "$tool")"
    else
        log_error "$tool NOT on PATH (01-host-deps did not install it)"
        FAILS=$((FAILS+1))
    fi
done

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

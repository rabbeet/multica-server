#!/usr/bin/env bash
# 12-validate-resources.sh — sanity-check that the server has headroom
# after the multica stack started.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# ---- Memory ------------------------------------------------------------------
mem_info=$(free -m | awk '/^Mem:/ {print $2,$7}')
total_mb=$(echo "$mem_info" | awk '{print $1}')
avail_mb=$(echo "$mem_info" | awk '{print $2}')

log_info "Memory: total=${total_mb}MB available=${avail_mb}MB"
if [[ $avail_mb -lt 4000 ]]; then
    log_warn "<4GB available memory. Stack is tight; consider scaling down."
elif [[ $avail_mb -lt 6000 ]]; then
    log_info "Memory OK (4-6GB available — workable)"
else
    log_ok "Memory healthy (${avail_mb}MB available)"
fi

# ---- Disk --------------------------------------------------------------------
disk_avail=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')
log_info "Disk: ${disk_avail}GB available on /"
if [[ $disk_avail -lt 20 ]]; then
    log_warn "<20GB free disk — running tight"
elif [[ $disk_avail -lt 50 ]]; then
    log_info "Disk OK (${disk_avail}GB free)"
else
    log_ok "Disk healthy (${disk_avail}GB free)"
fi

# ---- Swap activity -----------------------------------------------------------
swap_used=$(free -m | awk '/^Swap:/ {print $3}')
swap_total=$(free -m | awk '/^Swap:/ {print $2}')
if [[ $swap_total -eq 0 ]]; then
    log_warn "Swap not configured! 05-swapfile.sh should have run."
elif [[ $swap_used -gt 100 ]]; then
    log_warn "Swap in use: ${swap_used}MB / ${swap_total}MB. Memory pressure."
else
    log_ok "Swap configured (${swap_total}MB), barely used (${swap_used}MB)"
fi

# ---- Docker container memory ------------------------------------------------
log_info ""
log_info "Container memory (top consumers):"
docker stats --no-stream --format "  {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}" 2>/dev/null | head -10 || log_skip "docker stats not available (may need root)"

# ---- Agent stack scaling check (design Eng Issue 4.1) ------------------------
# When N=3 concurrent claude processes are anticipated, agent-host needs 6G not 4G.
# Detect the configured limit + the OAuth-config dirs that exist, warn on mismatch.
if docker ps --filter "name=^agent-host$" --format '{{.Names}}' 2>/dev/null | grep -q agent-host; then
    log_info ""
    log_info "Agent stack (A-lite) scaling:"

    # Container memory limit (HostConfig.Memory is bytes; 0 = unlimited)
    mem_limit_bytes=$(docker inspect agent-host --format '{{.HostConfig.Memory}}' 2>/dev/null || echo 0)
    if [[ $mem_limit_bytes -eq 0 ]]; then
        log_skip "  agent-host has no memory limit set"
    else
        mem_limit_g=$(( mem_limit_bytes / 1073741824 ))
        log_info "  agent-host memory limit: ${mem_limit_g}G"

        # Count agents with OAuth configured (each has its own subdir under ~/.claude/)
        n_agents=$(docker exec agent-host bash -c \
            'find /home/agent/.claude -maxdepth 1 -mindepth 1 -type d \
                ! -name backups ! -name projects ! -name sessions \
                -exec test -f "{}/.claude.json" \; -print 2>/dev/null | wc -l' 2>/dev/null || echo 0)
        log_info "  agents with OAuth configured: $n_agents"

        if [[ $n_agents -ge 3 && $mem_limit_g -lt 6 ]]; then
            log_warn "N=$n_agents agents but agent-host memory limit is only ${mem_limit_g}G."
            log_warn "Per design Eng Issue 4.1: bump compose memory to 6G for N=3 (each claude ~1G under load)."
            log_warn "Edit agent/compose.yml: agent-host -> deploy.resources.limits.memory: 6G"
        elif [[ $n_agents -le 2 && $mem_limit_g -ge 4 ]]; then
            log_ok "N=$n_agents agents fit in ${mem_limit_g}G ceiling"
        fi
    fi

    # Free memory check (must remain >= 8 GiB after agent stack runs)
    if [[ $avail_mb -lt 8000 ]]; then
        log_warn "<8GB available with agent stack running. If N grows, consider:"
        log_warn "  - Reduce N (kill an agent's OAuth, restart container)"
        log_warn "  - Bump host RAM (Contabo plan upgrade)"
    fi
fi

log_ok "12-validate-resources complete"

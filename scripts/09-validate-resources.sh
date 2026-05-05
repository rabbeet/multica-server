#!/usr/bin/env bash
# 09-validate-resources.sh — sanity-check that the server has headroom
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

log_ok "09-validate-resources complete"

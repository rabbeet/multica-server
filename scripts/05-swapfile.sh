#!/usr/bin/env bash
# 05-swapfile.sh — add a swapfile (Contabo VPS ships with 0 swap).
#
# Provides safety margin if multica + happy + native postgres + redis spike
# memory simultaneously. 8GB default; configurable via SWAPFILE_SIZE_GB in .env.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

SIZE_GB="${SWAPFILE_SIZE_GB:-8}"
SWAPFILE="${SWAPFILE_PATH:-/swapfile}"

# ---- Skip if already active --------------------------------------------------
if swapon --show=NAME --noheadings | grep -qF "$SWAPFILE"; then
    current_size=$(swapon --show=SIZE --noheadings | head -1)
    log_skip "Swapfile $SWAPFILE active (size=$current_size)"
    exit 0
fi

# ---- Skip if file already exists but not enabled (likely partial run) -------
if [[ -f "$SWAPFILE" ]]; then
    log_warn "$SWAPFILE exists but is not active. Activating..."
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null 2>&1 || true
    swapon "$SWAPFILE"
    log_ok "Activated existing swapfile"
else
    # ---- Disk space sanity check --------------------------------------------
    available_kb=$(df / --output=avail | tail -1 | tr -d ' ')
    needed_kb=$((SIZE_GB * 1024 * 1024))
    if [[ $available_kb -lt $((needed_kb + 5 * 1024 * 1024)) ]]; then
        log_error "Not enough free disk: have $((available_kb/1024/1024))GB, need $((SIZE_GB+5))GB"
        exit 1
    fi

    log_info "Creating ${SIZE_GB}GB swapfile at $SWAPFILE..."
    fallocate -l "${SIZE_GB}G" "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"
    log_ok "Swapfile created and activated"
fi

# ---- Persist across reboots via /etc/fstab ----------------------------------
if grep -qF "$SWAPFILE" /etc/fstab; then
    log_skip "fstab entry already exists for $SWAPFILE"
else
    echo "$SWAPFILE  none  swap  sw  0  0" >> /etc/fstab
    log_ok "Added fstab entry"
fi

# ---- Tune swappiness — prefer RAM, swap only when needed --------------------
if [[ "$(cat /proc/sys/vm/swappiness)" != "10" ]]; then
    sysctl -w vm.swappiness=10 >/dev/null
    if ! grep -q '^vm.swappiness' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    else
        sed -i 's/^vm.swappiness.*/vm.swappiness=10/' /etc/sysctl.conf
    fi
    log_ok "Set vm.swappiness=10 (prefer RAM)"
fi

log_info "Memory after swap activation:"
free -h

log_ok "05-swapfile complete"

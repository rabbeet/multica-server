#!/usr/bin/env bash
# teardown.sh — clean reset.
# Stops containers, removes them, removes volumes EXCEPT data we keep.
#
# Preserved:
#   - Postgres data (host's native pg, untouched)
#   - /srv/plans-multica/ (git repo, can be re-cloned anyway)
#   - Backups under /var/backups/multica/
#
# Removed:
#   - All containers (multica, tinyproxy, caddy)
#   - Named volumes (claude-brainstorm-config, multica-data)
#   - tinyproxy & caddy state
#
# Use case: clean state before re-bootstrap, OR final shutdown for migration.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/_lib.sh
source "$REPO_ROOT/scripts/_lib.sh"

# ---- Confirmation guard ------------------------------------------------------
if [[ "${1:-}" != "--yes" ]]; then
    log_warn "This will stop multica and remove containers + named volumes."
    log_warn "Postgres data and /srv/plans-multica/ are preserved."
    log_warn ""
    read -r -p "Type 'teardown' to confirm: " confirm
    if [[ "$confirm" != "teardown" ]]; then
        log_info "Aborted"
        exit 0
    fi
fi

if [[ $EUID -ne 0 ]]; then
    SUDO=sudo
else
    SUDO=""
fi

# ---- Stop and remove containers ----------------------------------------------
log_info "Stopping docker stack..."
$SUDO docker compose down --volumes --remove-orphans || log_warn "compose down had issues (probably already stopped)"

# ---- Remove named volumes (paranoid double-check) ----------------------------
for vol in claude-brainstorm-config multica-data caddy-data caddy-config tinyproxy-state; do
    if $SUDO docker volume inspect "$vol" >/dev/null 2>&1; then
        $SUDO docker volume rm "$vol" || log_warn "Could not remove volume $vol"
    fi
done

# ---- Note what's preserved ---------------------------------------------------
log_info ""
log_info "Preserved (NOT removed):"
log_info "  - Postgres role multica_brainstorm and DB multica (run psql to drop manually)"
log_info "  - Redis DB index 5 (FLUSHDB if desired)"
log_info "  - /srv/plans-multica/ (delete with: sudo rm -rf /srv/plans-multica/)"
log_info "  - /var/backups/multica/ (delete with: sudo rm -rf /var/backups/multica/)"
log_info "  - Tailscale node registration (revoke at admin.tailscale.com if desired)"
log_info "  - Linux user multica (delete with: sudo userdel -r multica)"
log_info "  - Swapfile $SWAPFILE_PATH (deactivate with: sudo swapoff $SWAPFILE_PATH && sudo rm $SWAPFILE_PATH)"
log_info ""
log_ok "Teardown complete. Re-run ./bootstrap.sh when ready."

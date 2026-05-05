#!/usr/bin/env bash
# bootstrap.sh — single entrypoint for setting up multica-server on Ubuntu 24.04.
#
# Idempotent: re-running is safe. Each numbered script in scripts/ guards itself.
#
# Usage:
#   ./bootstrap.sh           # run full bootstrap
#   ./bootstrap.sh --dry-run # print what would run, don't execute
#   ./bootstrap.sh 04 05     # run only specific scripts (by number prefix)
#
# Required: .env populated from password manager. Run as root or with sudo-able account.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/_lib.sh
source "$REPO_ROOT/scripts/_lib.sh"

# ---- Pre-flight --------------------------------------------------------------
if [[ ! -f "$REPO_ROOT/.env" ]]; then
    log_error ".env not found"
    log_error "Run: cp .env.example .env && \${EDITOR:-vim} .env"
    log_error "Fill values from password manager. Required: TAILSCALE_AUTHKEY, BRAINSTORM_PAT, POSTGRES_PASSWORD"
    exit 1
fi

# Sanity check on env values
require_env
require_vars TAILSCALE_AUTHKEY BRAINSTORM_PAT POSTGRES_PASSWORD TAILNET_NAME

# Confirm we are root or can sudo
if [[ $EUID -ne 0 ]]; then
    log_warn "Not running as root. Some scripts will use sudo."
    if ! sudo -n true 2>/dev/null; then
        log_error "sudo requires password. Run as root or with passwordless sudo."
        exit 1
    fi
fi

# ---- Argument parsing --------------------------------------------------------
DRY_RUN=0
SCRIPT_FILTER=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --help|-h)
            grep '^#' "$0" | head -20 | cut -c3-
            exit 0
            ;;
        [0-9][0-9]) SCRIPT_FILTER+=("$arg") ;;
        *) log_error "Unknown argument: $arg"; exit 2 ;;
    esac
done

# ---- Banner ------------------------------------------------------------------
log_info "==================================================================="
log_info "multica-server bootstrap"
log_info "host:     $(hostname) ($(uname -srm))"
log_info "user:     $(whoami) (UID=$EUID)"
log_info "tailnet:  ${TAILNET_NAME}"
[[ $DRY_RUN -eq 1 ]] && log_info "MODE:     DRY RUN (no changes)"
log_info "==================================================================="

# ---- Run scripts in order ----------------------------------------------------
declare -a SCRIPTS_TO_RUN
mapfile -t SCRIPTS_TO_RUN < <(ls -1 "$REPO_ROOT"/scripts/[0-9][0-9]-*.sh | sort)

for script_path in "${SCRIPTS_TO_RUN[@]}"; do
    script_name=$(basename "$script_path")
    script_num="${script_name:0:2}"

    # If filter specified, skip non-matching
    if [[ ${#SCRIPT_FILTER[@]} -gt 0 ]]; then
        if [[ ! " ${SCRIPT_FILTER[*]} " == *" $script_num "* ]]; then
            continue
        fi
    fi

    log_info ""
    log_info "→ $script_name"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "  (would run; --dry-run)"
        continue
    fi

    # Each script may need root for system ops; run via sudo if not root.
    if [[ $EUID -ne 0 ]]; then
        sudo -E bash "$script_path"
    else
        bash "$script_path"
    fi
done

# ---- Final verify ------------------------------------------------------------
if [[ $DRY_RUN -eq 0 && ${#SCRIPT_FILTER[@]} -eq 0 ]]; then
    log_info ""
    log_info "==================================================================="
    log_info "✓ Bootstrap complete"
    log_info "==================================================================="
    log_info ""
    log_info "Next steps:"
    log_info "  1. First-time Claude OAuth (interactive, requires browser):"
    log_info "       docker exec -it multica claude /login"
    log_info ""
    log_info "  2. Open multica from your phone (or laptop):"
    log_info "       https://${TAILSCALE_HOSTNAME:-multica}.${TAILNET_NAME}"
    log_info ""
    log_info "  3. Health check anytime:"
    log_info "       ./scripts/99-verify.sh"
    log_info ""
fi

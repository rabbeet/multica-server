#!/usr/bin/env bash
# scripts/_lib.sh — shared helpers for bootstrap scripts.
# All numbered scripts source this at top.

set -euo pipefail

# ANSI color helpers (no-op if not a tty)
if [[ -t 1 ]]; then
    _RED=$'\033[0;31m'
    _GRN=$'\033[0;32m'
    _YLW=$'\033[0;33m'
    _BLU=$'\033[0;34m'
    _DIM=$'\033[2m'
    _RST=$'\033[0m'
else
    _RED='' _GRN='' _YLW='' _BLU='' _DIM='' _RST=''
fi

# Logging — every script call shows up with its own prefix
_SCRIPT_NAME=$(basename "${BASH_SOURCE[1]:-$0}" .sh)

log_info()  { printf '%s[%s]%s %s\n'  "$_BLU" "$_SCRIPT_NAME" "$_RST" "$*"; }
log_ok()    { printf '%s[%s]%s ✓ %s\n' "$_GRN" "$_SCRIPT_NAME" "$_RST" "$*"; }
log_skip()  { printf '%s[%s]%s ⏭  %s%s\n' "$_DIM" "$_SCRIPT_NAME" "$_RST" "$*" "$_RST"; }
log_warn()  { printf '%s[%s]%s ⚠  %s\n' "$_YLW" "$_SCRIPT_NAME" "$_RST" "$*"; }
log_error() { printf '%s[%s]%s ✗ %s\n' "$_RED" "$_SCRIPT_NAME" "$_RST" "$*" >&2; }

# Idempotency helper — short-circuit a script if a marker condition is met.
# Usage: skip_if_done "tailscale already running" tailscale_already_authenticated
# (where tailscale_already_authenticated is a function returning 0 if done)
skip_if_done() {
    local reason="$1"; shift
    if "$@"; then
        log_skip "$reason"
        exit 0
    fi
}

# Require root for ops that touch system state.
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must run as root (got UID=$EUID)"
        exit 1
    fi
}

# Require .env loaded — pull values into env vars.
# BASH_SOURCE[0] is _lib.sh itself (in scripts/), so /.. gives repo root
# regardless of which script called us (bootstrap.sh in root, or scripts/0X-*.sh).
require_env() {
    local repo_root
    repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    if [[ ! -f "$repo_root/.env" ]]; then
        log_error ".env not found at $repo_root/.env — copy from .env.example and fill in"
        exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    source "$repo_root/.env"
    set +a
}

# Require a list of variables to be set and non-empty.
require_vars() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" || "${!var}" == *"REPLACE_ME"* ]]; then
            missing+=("$var")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Required env vars not set or still placeholder: ${missing[*]}"
        log_error "Edit .env and re-run."
        exit 1
    fi
}

# Repo root from any caller (bootstrap.sh in root, scripts/0X-*.sh, etc).
# BASH_SOURCE[0] is always _lib.sh which lives in scripts/, so /.. = repo root.
repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

# Run a command, retrying with backoff. retry_with_backoff <max> <delay> -- <cmd...>
retry_with_backoff() {
    local max=$1 delay=$2; shift 2
    local n=0
    until "$@"; do
        n=$((n+1))
        if [[ $n -ge $max ]]; then
            log_error "Failed after $max attempts: $*"
            return 1
        fi
        log_warn "Attempt $n failed, retrying in ${delay}s..."
        sleep "$delay"
        delay=$((delay*2))
    done
}

# Find an unused UID in a range (inclusive).
# Usage: pick_free_uid 1100 1199
pick_free_uid() {
    local low=$1 high=$2
    for uid in $(seq "$low" "$high"); do
        if ! getent passwd "$uid" >/dev/null 2>&1; then
            echo "$uid"
            return 0
        fi
    done
    log_error "No free UID in range $low-$high"
    return 1
}

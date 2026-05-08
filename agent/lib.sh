#!/usr/bin/env bash
# agent/lib.sh — minimal helpers for in-container scripts.
# Mirror of multica-server/scripts/_lib.sh style but in-container scope.

set -euo pipefail

LOG_FILE="${AGENT_LOG_FILE:-/var/log/agent/agent.log}"

log_info()  { printf '[%s] [INFO]  %s\n'  "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"; }
log_error() { printf '[%s] [ERROR] %s\n'  "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE" >&2; }
log_skip()  { printf '[%s] [SKIP]  %s\n'  "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"; }
log_ok()    { printf '[%s] [OK]    %s\n'  "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"; }

# require_env VAR_NAME [VAR_NAME...] — fail fast if any are unset/empty.
require_env() {
  local missing=()
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then missing+=("$v"); fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Required env vars unset: ${missing[*]}"
    exit 1
  fi
}

# Used by Telegram alerts — swallow failures (network down should not crash spawn).
telegram_send() {
  local text="$1"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log_skip "Telegram not configured — skipping alert"
    return 0
  fi
  curl -s -m 10 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${text}" \
    >/dev/null 2>&1 || log_skip "Telegram delivery failed (non-fatal)"
}

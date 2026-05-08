#!/usr/bin/env bash
# agent-healthcheck.sh — periodic per-agent liveness check.
# Cron entry (every 15 min): /usr/local/bin/agent-healthcheck.sh
#
# For each ~/.claude/agent-N/ dir found:
#   1. Run `claude --print "ok"` with timeout 30s
#   2. On failure → write health.jsonl entry + Telegram alert (likely OAuth expired)
#
# Design ref: design doc Section 9 (Health-check + OAuth expiry alert)

set -uo pipefail   # NB: not -e — we want to keep checking other agents on first failure

# shellcheck source=lib.sh
source /usr/local/bin/agent-lib.sh

CLAUDE_BASE="/home/agent/.claude"
[ -d "$CLAUDE_BASE" ] || exit 0   # nothing configured yet

failures=0
checked=0

for dir in "$CLAUDE_BASE"/*/; do
  [ -d "$dir" ] || continue
  agent_id="$(basename "$dir")"
  # Skip dirs that are not agent dirs (e.g. claude's own backups/, projects/, sessions/)
  case "$agent_id" in
    backups|projects|sessions) continue ;;
  esac

  checked=$((checked + 1))

  # Per-agent health log (separate from main spawn log).
  health_log="$dir/health.jsonl"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 30s timeout on claude --print. Captures both auth and network failures.
  if CLAUDE_CONFIG_DIR="$dir" timeout 30 claude --print "ok" >/dev/null 2>&1; then
    printf '{"ts":"%s","agent":"%s","status":"ok"}\n' "$ts" "$agent_id" >> "$health_log"
  else
    failures=$((failures + 1))
    printf '{"ts":"%s","agent":"%s","status":"fail"}\n' "$ts" "$agent_id" >> "$health_log"

    msg="$(printf '⚠️ %s healthcheck failed — likely OAuth token expired.\nRe-auth:\ndocker exec -it agent-host bash -c '\''CLAUDE_CONFIG_DIR=%s claude /login'\''' "$agent_id" "$dir")"
    telegram_send "$msg"
    log_error "agent=$agent_id healthcheck failed"
  fi
done

# pg-agent-N reachability (defense for dev-PG sidecars). Optional — skipped if
# DEV_PG_HOSTS not set. Format: comma-separated hosts ("pg-agent-1,pg-agent-2").
if [ -n "${DEV_PG_HOSTS:-}" ]; then
  IFS=',' read -ra hosts <<< "$DEV_PG_HOSTS"
  for host in "${hosts[@]}"; do
    if ! pg_isready -h "$host" -U pulse -t 5 -q; then
      failures=$((failures + 1))
      log_error "dev-PG $host unreachable"
      telegram_send "⚠️ dev-PG sidecar $host unreachable from agent-host"
    fi
  done
fi

if [ "$failures" -gt 0 ]; then
  log_error "healthcheck: $failures/$checked failures (+ pg checks)"
  exit 1
fi

# Quiet success — only log periodically (every 4th run = once/hour).
minute="$(date +%M)"
case "$minute" in
  00|15|30|45) log_ok "healthcheck: $checked agents ok" ;;
esac
exit 0

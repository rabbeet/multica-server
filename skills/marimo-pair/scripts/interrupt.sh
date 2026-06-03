#!/usr/bin/env bash
# Send SIGINT to a marimo kernel without restarting it.
#
# Use when a cell is wedged on a long-running operation (FDS partition
# scan, large CSV download, infinite generator) and you want to recover
# control without losing in-memory state. Marimo's session.try_interrupt()
# does `os.kill(kernel_pid, SIGINT)`; the running cell raises
# KeyboardInterrupt and every variable from previously-run cells (loaded
# DataFrames, open psycopg connections, imported modules) survives.
#
# Compare /api/kernel/restart, which kills + respawns the kernel process
# — every variable is lost and the reactive graph re-plays from cell 1.
# Reach for restart only when interrupt fails twice or the kernel reports
# kernel_state != RUNNING.
#
# Caveat: SIGINT unblocks Python's I/O wait, so a psycopg query will
# normally cancel and the connection rolls back on context exit. If the
# cell holds a long-lived module-level connection (not `with` scoped),
# you may need to manually `conn.rollback()` from a new cell after
# interrupt. A future Lane B follow-up may add pg_cancel_backend support
# for that case.
#
# Usage:
#   interrupt.sh [--port N] [--session-id S]
#
# Exit codes:
#   0   interrupt request accepted (kernel got SIGINT)
#   2   bad CLI args
#   3   transport failure / endpoint rejected the request
#
# Output: client.py interrupt JSON on stdout
# {http_status, response, session_id}.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$SCRIPT_DIR/client.py"

port=""
session_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) port="$2"; shift 2 ;;
        --session-id) session_id="$2"; shift 2 ;;
        -h|--help) sed -n '3,30p' "$0" >&2; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) echo "Unexpected positional argument: $1" >&2; exit 2 ;;
    esac
done

args=("interrupt")
if [[ -n "$port" ]]; then
    args+=("--port" "$port")
fi
if [[ -n "$session_id" ]]; then
    args+=("--session-id" "$session_id")
fi

exec python3 "$CLIENT" "${args[@]}"

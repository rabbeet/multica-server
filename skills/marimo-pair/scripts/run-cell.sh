#!/usr/bin/env bash
# Re-run an existing marimo cell without modifying its code.
#
# Use this when you want to retrigger a cell after upstream state changed
# (e.g. a setup cell rebound a variable) and you want this cell to pick up
# the new value, without editing the body. For "I want to change the code
# AND run it" use edit-and-run.sh — re-running is cheaper but does no edit.
#
# Internally:
#   1. discover server + session via client.py
#   2. dump CURRENT cell code via code_mode (--with-code)
#   3. POST /api/kernel/run with that same code (re-queues the cell)
#   4. poll cell status until terminal (adaptive backoff)
#
# Usage:
#   run-cell.sh CELL_ID
#   run-cell.sh [--port N] [--timeout S] CELL_ID
#
# Exit codes match edit-and-run.sh: 0 clean, 1 errors, 2 not-found, 3
# transport, 124 hard-timeout.
#
# Output: client.py's run-cell JSON on stdout. No save/lint by default —
# the cell code is unchanged, so there is nothing to persist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$SCRIPT_DIR/client.py"

port=""
timeout="60"
cell_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)    port="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    -h|--help) sed -n '3,25p' "$0" >&2; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$cell_id" ]]; then
        cell_id="$1"
      else
        echo "Unexpected positional argument: $1" >&2; exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$cell_id" ]]; then
  echo "Usage: run-cell.sh [--port N] [--timeout S] CELL_ID" >&2
  exit 2
fi

args=("run-cell" "--cell-id" "$cell_id" "--timeout" "$timeout")
if [[ -n "$port" ]]; then
  args+=("--port" "$port")
fi

exec python3 "$CLIENT" "${args[@]}"

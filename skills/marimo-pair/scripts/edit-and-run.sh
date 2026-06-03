#!/usr/bin/env bash
# Edit a marimo cell's code and wait for the reactive run to settle.
#
# Why: the bare-curl + manual-poll pattern that agents used before (curl
# /api/kernel/run → run_in_background → tail output file → check status)
# burns 30-90 s per iteration. This wrapper composes client.py (discover →
# edit → poll with adaptive backoff) + lint-and-persist.sh (flush to disk +
# check for redefined-name collisions and red cells).
#
# Usage:
#   edit-and-run.sh CELL_ID CODE_FILE        # read code from file
#   echo 'print(1+1)' | edit-and-run.sh CELL_ID -   # read code from stdin
#   edit-and-run.sh [--port N] [--session-id S] [--timeout S]
#                   [--no-lint] CELL_ID CODE_FILE
#
# Exit codes:
#   0    cell ran, no errors, persisted, lint green
#   1    cell ran but produced errors / cell or lint rejected it
#   2    bad CLI args / cell not found
#   3    transport failure (server unreachable, save HTTP failure)
#   124  hard-timeout polling cell status — kernel may be stuck on a
#        long-running query. After Lane B ships, scripts/interrupt.sh can
#        cancel without restarting the kernel.
#
# Output: client.py's edit-and-run JSON on stdout (cell_id, status, errors,
# took_s, wall_s, timed_out). lint-and-persist.sh stderr passes through.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$SCRIPT_DIR/client.py"
LINT="$SCRIPT_DIR/lint-and-persist.sh"

port=""
session_id=""
timeout="60"
do_lint="true"
cell_id=""
code_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)       port="$2"; shift 2 ;;
    --session-id) session_id="$2"; shift 2 ;;
    --timeout)    timeout="$2"; shift 2 ;;
    --no-lint)    do_lint="false"; shift ;;
    -h|--help)    sed -n '3,29p' "$0" >&2; exit 0 ;;
    --)           shift; break ;;
    -*)           echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$cell_id" ]]; then
        cell_id="$1"
      elif [[ -z "$code_path" ]]; then
        code_path="$1"
      else
        echo "Unexpected positional argument: $1" >&2; exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$cell_id" ]]; then
  echo "Usage: edit-and-run.sh [--port N] [--timeout S] [--no-lint] CELL_ID CODE_FILE" >&2
  echo "       echo 'code' | edit-and-run.sh CELL_ID -" >&2
  exit 2
fi

# Resolve code-file. Stdin → temp file we own (and clean up via trap).
tmp_code=""
trap '[[ -n "$tmp_code" ]] && rm -f "$tmp_code"' EXIT

if [[ -z "$code_path" || "$code_path" == "-" ]]; then
  if [[ -t 0 && "$code_path" != "-" ]]; then
    echo "edit-and-run.sh: no code file and stdin is a tty" >&2
    exit 2
  fi
  tmp_code=$(mktemp /tmp/cell-XXXXXX.py)
  cat > "$tmp_code"
  code_path="$tmp_code"
elif [[ ! -r "$code_path" ]]; then
  echo "edit-and-run.sh: code file not readable: $code_path" >&2
  exit 2
fi

# Build client.py invocation.
args=("edit-and-run" "--cell-id" "$cell_id" "--code-file" "$code_path" "--timeout" "$timeout")
if [[ -n "$port" ]]; then
  args+=("--port" "$port")
fi
if [[ -n "$session_id" ]]; then
  args+=("--session-id" "$session_id")
fi

# Capture both client.py exit code AND its stdout. We pass stdout through
# to the caller regardless, then optionally chain lint-and-persist.
client_rc=0
client_out=$(python3 "$CLIENT" "${args[@]}") || client_rc=$?
echo "$client_out"

# Skip lint when the kernel run already failed — lint-and-persist requires
# a successful kernel round-trip to dump cell state, and chasing a second
# failure on top of the first one is just noise.
if [[ "$client_rc" -ne 0 ]]; then
  exit "$client_rc"
fi

if [[ "$do_lint" == "true" ]]; then
  lint_args=()
  [[ -n "$port" ]] && lint_args+=(--port "$port")
  [[ -n "$session_id" ]] && lint_args+=(--session "$session_id")
  if ! bash "$LINT" "${lint_args[@]}"; then
    lint_rc=$?
    # lint_rc=1 means file persisted but lint said red (e.g. redefined
    # name, cell error). Propagate it so callers can refuse to publish.
    echo "edit-and-run.sh: lint-and-persist returned $lint_rc" >&2
    exit "$lint_rc"
  fi
fi

exit 0

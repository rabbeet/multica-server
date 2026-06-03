#!/usr/bin/env bash
# Exercise client.py dump-cells against the live kernel: list at least
# one cell from the current session. Skips (exit 77) without a live
# marimo or session.
#
# This is the lightest possible round-trip test. The plan called for a
# create+run "1+1" check, but that requires creating a cell in a known
# notebook and cleaning it up — too much state for a smoke test. We
# verify the dump path here; the create/run path is exercised end-to-end
# only by test_edit_and_run.sh (which has stricter prereqs).
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$SCRIPTS_DIR/client.py"
DISCOVER="$SCRIPTS_DIR/discover-servers.sh"

if [[ "$("$DISCOVER" | jq 'length')" == "0" ]]; then
  echo "test_run_cell: no live marimo server, skipping" >&2
  exit 77
fi

# Find a RESPONSIVE session. Multi-session hosts often have one or two
# stuck kernels (a previous query hung); we want to smoke-test against a
# live one. Probe each session with a 3 s timeout on a print('alive') and
# pick the first that answers.
servers_json=$("$DISCOVER")
host=$(echo "$servers_json" | jq -r '.[0].host')
port=$(echo "$servers_json" | jq -r '.[0].port')
base_url=$(echo "$servers_json" | jq -r '.[0].base_url')
sids=$(curl -sf "http://${host}:${port}${base_url}/api/sessions" \
  | jq -r 'keys[]') || {
  echo "test_run_cell: failed to list sessions" >&2
  exit 1
}
if [[ -z "$sids" ]]; then
  echo "test_run_cell: server has no sessions, skipping" >&2
  exit 77
fi

session_id=""
EXEC="$SCRIPTS_DIR/execute-code.sh"
for sid in $sids; do
  if timeout 3 bash "$EXEC" --session "$sid" -c "print('alive')" \
      >/dev/null 2>&1; then
    session_id="$sid"
    break
  fi
done
if [[ -z "$session_id" ]]; then
  echo "test_run_cell: no responsive sessions, skipping" >&2
  exit 77
fi

ping_out=$(python3 "$CLIENT" ping --session-id "$session_id")
if [[ "$(echo "$ping_out" | jq -r '.ok')" != "true" ]]; then
  echo "test_run_cell: ping failed: $ping_out" >&2
  exit 1
fi

# Dump cells (no filter). Must produce a JSON array.
cells=$(python3 "$CLIENT" dump-cells --session-id "$session_id")
if ! echo "$cells" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "test_run_cell: dump-cells did not produce array: $cells" >&2
  exit 1
fi
count=$(echo "$cells" | jq 'length')
if (( count < 1 )); then
  echo "test_run_cell: dump-cells returned empty (need at least 1 cell)" >&2
  exit 1
fi

# Re-dump with --with-code and confirm the 'code' field is present.
cells_full=$(python3 "$CLIENT" dump-cells --session-id "$session_id" --with-code)
has_code=$(echo "$cells_full" | jq '.[0] | has("code")')
if [[ "$has_code" != "true" ]]; then
  echo "test_run_cell: --with-code did not include 'code' field" >&2
  exit 1
fi

echo "test_run_cell: ok ($count cells visible)"

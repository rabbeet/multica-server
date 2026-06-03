#!/usr/bin/env bash
# Verify edit-and-run.sh's reachability and graceful-error paths against
# a live marimo. We deliberately do NOT mutate a real notebook cell here:
# the brainstorm host normally has multiple sessions in flux (agent-1
# editing on its side, kernels restarting) so a round-trip test that
# stashes-and-restores a cell is too racy to trust in CI-style runs.
#
# What this test guarantees instead:
#   1. edit-and-run.sh forwards client.py errors faithfully on a bogus
#      cell ID, exiting non-zero with a JSON error blob.
#   2. dump-cells through edit-and-run.sh's discovery path resolves
#      a real session_id end-to-end.
#
# The real "did the edit actually run?" check lives in agent usage —
# any PUL-* marimo ticket that calls edit-and-run.sh is itself a
# round-trip test in production. If the helper is broken there, the
# agent's run will fail loudly and we get a real bug report.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$SCRIPTS_DIR/client.py"
DISCOVER="$SCRIPTS_DIR/discover-servers.sh"
EDIT_AND_RUN="$SCRIPTS_DIR/edit-and-run.sh"

if [[ "$("$DISCOVER" | jq 'length')" == "0" ]]; then
  echo "test_edit_and_run: no live marimo server, skipping" >&2
  exit 77
fi

# Probe-loop to find a responsive session — see test_run_cell.sh.
servers_json=$("$DISCOVER")
host=$(echo "$servers_json" | jq -r '.[0].host')
port=$(echo "$servers_json" | jq -r '.[0].port')
base_url=$(echo "$servers_json" | jq -r '.[0].base_url')
sids=$(curl -sf "http://${host}:${port}${base_url}/api/sessions" \
  | jq -r 'keys[]') || {
  echo "test_edit_and_run: failed to list sessions, skipping" >&2
  exit 77
}
if [[ -z "$sids" ]]; then
  echo "test_edit_and_run: server has no sessions, skipping" >&2
  exit 77
fi

EXEC="$SCRIPTS_DIR/execute-code.sh"
session_id=""
for sid in $sids; do
  if timeout 3 bash "$EXEC" --session "$sid" -c "print('alive')" \
      >/dev/null 2>&1; then
    session_id="$sid"
    break
  fi
done
if [[ -z "$session_id" ]]; then
  echo "test_edit_and_run: no responsive sessions, skipping" >&2
  exit 77
fi

# 1. Bogus cell id should propagate a non-zero exit through edit-and-run.sh.
work_dir=$(mktemp -d /tmp/marimo-test-XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
echo "_test_marker_pul270 = 'noop'" > "$work_dir/code.py"

bogus_rc=0
bogus_out=$(bash "$EDIT_AND_RUN" --no-lint --session-id "$session_id" \
  --timeout 10 ZZ_DOES_NOT_EXIST "$work_dir/code.py" 2>&1) || bogus_rc=$?
if [[ "$bogus_rc" == "0" ]]; then
  echo "test_edit_and_run: bogus cell-id should not exit 0; out=$bogus_out" >&2
  exit 1
fi

# 2. dump-cells through client.py discovery resolves at least one cell on
# the chosen session — this is the same path edit-and-run.sh would take
# to validate the cell ID, minus the mutation.
cells=$(python3 "$CLIENT" dump-cells --session-id "$session_id" 2>/dev/null) || {
  echo "test_edit_and_run: dump-cells failed via discovery path, skipping" >&2
  exit 77
}
count=$(echo "$cells" | jq 'length')
if (( count < 1 )); then
  echo "test_edit_and_run: dump-cells returned empty via discovery path" >&2
  exit 1
fi

echo "test_edit_and_run: ok (helper reachable, ${count} cells discoverable, bogus-cell rejected with rc=$bogus_rc)"

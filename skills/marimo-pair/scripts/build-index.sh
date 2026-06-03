#!/usr/bin/env bash
# Refresh /srv/marimo-notebooks/MARIMO_INDEX.md.
#
# Three callers share this script:
#   - lint-and-persist.sh (end-of-ticket, after a green lint)
#   - the marimo routing rule (step 0, start-of-ticket)
#   - any future host-side cron
#
# Concurrent calls queue on a flock — the index is rewritten atomically by
# build-index.py (temp file + rename), so they never produce a half-written
# file even without the lock; the lock just prevents one wasted refresh.
#
# Exit codes match build-index.py:
#   0  index rewritten
#   1  hard failure (directory missing, python missing)
#   2  output directory not writable (sandbox without rw on
#      /srv/marimo-notebooks/) — non-fatal for callers, treated as a warning
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$SCRIPT_DIR/build-index.py"

if [[ ! -f "$PY" ]]; then
  echo "build-index.sh: missing $PY" >&2
  exit 1
fi

LOCK="/tmp/marimo-build-index.lock"
exec 9>"$LOCK"
if ! flock -w 30 9; then
  echo "build-index.sh: lock $LOCK held >30s, skipping refresh" >&2
  exit 0
fi

exec python3 "$PY" "$@"

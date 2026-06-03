#!/usr/bin/env bash
# Shell-syntax check + argument-handling smoke for edit-and-run.sh and
# run-cell.sh. Pure test — no live marimo.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDIT_AND_RUN="$SCRIPTS_DIR/edit-and-run.sh"
RUN_CELL="$SCRIPTS_DIR/run-cell.sh"

# 1. bash -n on both scripts (catches structural issues like unclosed quotes
# without running them).
bash -n "$EDIT_AND_RUN"
bash -n "$RUN_CELL"

# 2. No-arg invocation must exit 2 (bad CLI), not 0, not crash.
if "$EDIT_AND_RUN" 2>/dev/null; then
  echo "test_edit_and_run_syntax: edit-and-run.sh accepted no args" >&2
  exit 1
fi
edit_rc=0
"$EDIT_AND_RUN" 2>/dev/null || edit_rc=$?
if [[ "$edit_rc" != "2" ]]; then
  echo "test_edit_and_run_syntax: edit-and-run.sh no-args exit was $edit_rc, want 2" >&2
  exit 1
fi

if "$RUN_CELL" 2>/dev/null; then
  echo "test_edit_and_run_syntax: run-cell.sh accepted no args" >&2
  exit 1
fi
run_rc=0
"$RUN_CELL" 2>/dev/null || run_rc=$?
if [[ "$run_rc" != "2" ]]; then
  echo "test_edit_and_run_syntax: run-cell.sh no-args exit was $run_rc, want 2" >&2
  exit 1
fi

# 3. Unknown option must exit 2.
unk_rc=0
"$EDIT_AND_RUN" --bogus 2>/dev/null || unk_rc=$?
if [[ "$unk_rc" != "2" ]]; then
  echo "test_edit_and_run_syntax: --bogus exit was $unk_rc, want 2" >&2
  exit 1
fi

# 4. Missing code file (non-stdin, no file) must exit 2.
missing_rc=0
"$EDIT_AND_RUN" some-cell-id /nonexistent/path.py 2>/dev/null || missing_rc=$?
if [[ "$missing_rc" != "2" ]]; then
  echo "test_edit_and_run_syntax: missing code file exit was $missing_rc, want 2" >&2
  exit 1
fi

echo "test_edit_and_run_syntax: ok"

#!/usr/bin/env bash
# Shell + Python syntax + argparse check for sql-scratch.sh / sql-scratch.py.
# Pure test — no DSN required.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$SCRIPTS_DIR/sql-scratch.sh"
PY="$SCRIPTS_DIR/sql-scratch.py"

# 1. bash -n + python ast parse
bash -n "$SH"
python3 -c "import ast; ast.parse(open('$PY').read())"

# 2. No args → argparse refuses, exit 2
rc=0
bash "$SH" 2>/dev/null || rc=$?
if [[ "$rc" == "0" ]]; then
    echo "test_sql_scratch_syntax: no-args succeeded (want non-zero)" >&2
    exit 1
fi

# 3. Bogus env var name → exit 2 with explicit error
rc=0
out=$(echo "SELECT 1" | bash "$SH" __NO_SUCH_DSN__ 2>&1) || rc=$?
if [[ "$rc" != "2" ]]; then
    echo "test_sql_scratch_syntax: bogus DSN exit was $rc, want 2; out=$out" >&2
    exit 1
fi
case "$out" in
    *empty*|*is\ empty*) ;;
    *)
        echo "test_sql_scratch_syntax: bogus DSN error message missing 'empty'" >&2
        echo "$out" >&2
        exit 1
        ;;
esac

# 4. --statement-timeout-ms expects int (argparse enforces)
rc=0
echo "SELECT 1" | bash "$SH" PULSE_PG_DSN --statement-timeout-ms abc 2>/dev/null || rc=$?
if [[ "$rc" == "0" ]]; then
    echo "test_sql_scratch_syntax: bad --statement-timeout-ms value accepted" >&2
    exit 1
fi

echo "test_sql_scratch_syntax: ok"

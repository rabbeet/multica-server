#!/usr/bin/env bash
# Verify sql-scratch.sh's BEGIN READ ONLY guard rejects mutations.
# Requires $PULSE_PG_DSN. Skips (77) without it.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$SCRIPTS_DIR/sql-scratch.sh"

if [[ -z "${PULSE_PG_DSN:-}" ]]; then
    echo "test_sql_scratch_ro: no \$PULSE_PG_DSN, skipping" >&2
    exit 77
fi

# 1. Happy path: SELECT 1 returns one row.
out=$(echo "SELECT 1 AS n" | bash "$SH" PULSE_PG_DSN)
rc=$?
if [[ "$rc" != "0" ]]; then
    echo "test_sql_scratch_ro: happy SELECT failed rc=$rc: $out" >&2
    exit 1
fi
n=$(echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("row_count"))')
if [[ "$n" != "1" ]]; then
    echo "test_sql_scratch_ro: happy SELECT row_count=$n want 1; out=$out" >&2
    exit 1
fi

# 2. RO guard blocks mutation. CREATE TABLE must fail with 25006.
rc=0
out=$(echo "CREATE TABLE _sql_scratch_test_pul270 (id int)" \
    | bash "$SH" PULSE_PG_DSN 2>&1) || rc=$?
if [[ "$rc" != "1" ]]; then
    echo "test_sql_scratch_ro: CREATE TABLE exit was $rc, want 1; out=$out" >&2
    exit 1
fi
case "$out" in
    *25006*|*read-only*|*read_only*) ;;
    *)
        echo "test_sql_scratch_ro: CREATE TABLE error should mention 25006/read-only" >&2
        echo "$out" >&2
        exit 1
        ;;
esac

# 3. --explain emits a plan.
out=$(echo "SELECT count(*) FROM pg_class" | bash "$SH" PULSE_PG_DSN --explain)
rc=$?
if [[ "$rc" != "0" ]]; then
    echo "test_sql_scratch_ro: explain failed rc=$rc: $out" >&2
    exit 1
fi
plan=$(echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("explain_plan", ""))')
case "$plan" in
    *Seq\ Scan*|*Aggregate*|*Index*) ;;
    *)
        echo "test_sql_scratch_ro: explain_plan missing expected ops" >&2
        echo "$plan" >&2
        exit 1
        ;;
esac

echo "test_sql_scratch_ro: ok"

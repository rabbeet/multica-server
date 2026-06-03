#!/usr/bin/env bash
# Prototype a Postgres query off-notebook before committing it to a cell.
# Thin wrapper around sql-scratch.py: picks an interpreter that has psycopg
# (system python3 → /opt/marimo/venv/bin/python3) and forwards arguments.
#
# Default behavior: run inside BEGIN READ ONLY with statement_timeout=10s.
# The query rolls back regardless. Use --allow-write to opt out of the
# read-only guard (you still need a RW DSN).
#
# Usage:
#   sql-scratch.sh PULSE_PG_DSN <<< "SELECT count(*) FROM issue"
#   sql-scratch.sh FDS_DB_DSN --sql-file query.sql --explain
#   sql-scratch.sh FDS_DB_DSN --statement-timeout-ms 30000 < query.sql
#
# Exit codes mirror sql-scratch.py: 0 ok, 1 query failed, 2 bad CLI,
# 124 statement_timeout fired.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_SCRIPT="$SCRIPT_DIR/sql-scratch.py"

# Pick an interpreter that has psycopg. System python3 usually doesn't on
# brainstorm-style hosts (we deliberately avoid polluting it with deps);
# marimo's own venv does.
PY=""
if python3 -c "import psycopg" 2>/dev/null; then
    PY="python3"
elif [[ -x /opt/marimo/venv/bin/python3 ]] \
        && /opt/marimo/venv/bin/python3 -c "import psycopg" 2>/dev/null; then
    PY="/opt/marimo/venv/bin/python3"
else
    echo "sql-scratch.sh: no python3 with psycopg found. Tried system " >&2
    echo "and /opt/marimo/venv/bin/python3. Install: pip install 'psycopg[binary]'." >&2
    exit 2
fi

exec "$PY" "$PY_SCRIPT" "$@"

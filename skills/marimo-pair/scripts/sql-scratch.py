#!/usr/bin/env python3
"""Prototype a Postgres query off-notebook before committing it to a cell.

A separate process that opens its own psycopg connection, runs SQL inside
a default-read-only transaction, prints the row count + timing + a small
sample of rows, optionally adds EXPLAIN ANALYZE. Calling this BEFORE
turning the query into a notebook cell catches the slow / hung / wrong
query without spending a marimo round-trip on each iteration.

Why a separate tool and not `psql` or a scratchpad cell?

  - Forced `BEGIN READ ONLY`: every connection (even on a RW DSN like
    $FDS_DB_DSN) refuses to mutate anything for the duration of the
    query. The `--allow-write` flag opens a normal transaction.
  - Forced `statement_timeout`: a stuck query times out and frees the
    PG connection rather than chewing through the agent's wall-time
    budget. Default 10 s; override with `--statement-timeout-ms`.
  - Structured output: row count, timing, column types, head rows as
    JSON on stdout. Pipe it to jq or hand-eyeball it.
  - Optional EXPLAIN ANALYZE: shows the plan + actual rows for the same
    query. Default off (cheap iteration); flip on when the timing is
    suspicious.

Stdin or a file: pass `--sql-file PATH` or pipe the query.

Usage:
  sql-scratch.py PULSE_PG_DSN              # SQL from stdin
  sql-scratch.py FDS_DB_DSN --sql-file q.sql
  sql-scratch.py PULSE_PG_DSN --explain    # add EXPLAIN ANALYZE
  sql-scratch.py FDS_DB_DSN --allow-write  # skip BEGIN READ ONLY

Exit codes:
  0    query ran, output on stdout (rows + timing as JSON)
  1    query failed (syntax, permission, mutation under read-only, etc.)
  2    bad CLI / missing env var / missing psycopg
  124  statement_timeout fired

Output schema (JSON on stdout):
  {
    "dsn_env": "PULSE_PG_DSN",
    "explain": false,
    "elapsed_ms": 123.4,
    "columns": [["id", "int4"], ["title", "text"], ...],
    "row_count": 42,
    "sample": [[...], ...],     # up to 20 rows
    "explain_plan": "..."       # only when --explain
  }
"""
from __future__ import annotations

import argparse
import datetime
import decimal
import json
import os
import sys
import time
import uuid

try:
    import psycopg
    from psycopg.rows import tuple_row
except ImportError:
    print(
        json.dumps({
            "error": "psycopg is not importable. Run with "
                     "/opt/marimo/venv/bin/python3 (which has psycopg) or "
                     "install: pip install 'psycopg[binary]'."
        }),
        file=sys.stderr,
    )
    sys.exit(2)


_SAMPLE_LIMIT = 20
_DEFAULT_TIMEOUT_MS = 10_000


def _jsonify(value: object) -> object:
    """Coerce common Postgres types to JSON-encodable scalars."""
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, decimal.Decimal):
        return float(value)
    if isinstance(value, uuid.UUID):
        return str(value)
    if isinstance(value, (bytes, bytearray, memoryview)):
        return f"<{len(bytes(value))} bytes>"
    if isinstance(value, (list, tuple)):
        return [_jsonify(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _jsonify(v) for k, v in value.items()}
    return value


def run(args: argparse.Namespace) -> int:
    dsn = os.environ.get(args.dsn_env)
    if not dsn:
        print(
            json.dumps({"error": f"env var ${args.dsn_env} is empty"}),
            file=sys.stderr,
        )
        return 2

    if args.sql_file:
        try:
            sql = open(args.sql_file, encoding="utf-8").read()
        except OSError as e:
            print(json.dumps({"error": f"read --sql-file: {e}"}), file=sys.stderr)
            return 2
    else:
        sql = sys.stdin.read()
    sql = sql.strip().rstrip(";")
    if not sql:
        print(json.dumps({"error": "empty SQL"}), file=sys.stderr)
        return 2

    out: dict[str, object] = {
        "dsn_env": args.dsn_env,
        "explain": args.explain,
        "read_only": not args.allow_write,
        "statement_timeout_ms": args.statement_timeout_ms,
    }

    try:
        with psycopg.connect(dsn, autocommit=False, row_factory=tuple_row) as conn:
            with conn.cursor() as cur:
                # SET statement_timeout does not accept query parameters
                # (Postgres SQL grammar). Inline the int directly — argparse
                # type=int guarantees it's a literal integer, not user SQL.
                timeout_ms = int(args.statement_timeout_ms)
                cur.execute(f"SET statement_timeout = {timeout_ms}")

                if not args.allow_write:
                    # SET TRANSACTION READ ONLY must run as the first
                    # statement in a transaction. We've not run anything
                    # else above (SET statement_timeout is session-scope,
                    # not transaction-scope), so this is safe.
                    cur.execute("SET TRANSACTION READ ONLY")

                if args.explain:
                    cur.execute(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) {sql}")
                    plan_rows = cur.fetchall()
                    out["explain_plan"] = "\n".join(r[0] for r in plan_rows)
                    # Re-run for the actual rows.
                    t0 = time.monotonic()
                    cur.execute(sql)
                else:
                    t0 = time.monotonic()
                    cur.execute(sql)

                if cur.description is None:
                    # DDL / non-returning DML. row_count is meaningless.
                    elapsed = (time.monotonic() - t0) * 1000.0
                    out["elapsed_ms"] = round(elapsed, 2)
                    out["columns"] = []
                    out["row_count"] = cur.rowcount if cur.rowcount >= 0 else None
                    out["sample"] = []
                    conn.rollback()
                    print(json.dumps(out, ensure_ascii=False))
                    return 0

                columns = [(d.name, d._type_display) if hasattr(d, "_type_display")
                           else (d.name, "?") for d in cur.description]
                # psycopg description columns have type_code as an OID — map
                # to type name via the cursor's internal types map.
                try:
                    from psycopg import types as pg_types  # noqa: F401
                    # psycopg3 exposes type-name lookup via cursor.adapters
                    types_map = conn.adapters.types
                    columns = [
                        (d.name, types_map.get(d.type_code).name
                         if types_map.get(d.type_code) else "?")
                        for d in cur.description
                    ]
                except Exception:  # noqa: BLE001
                    columns = [(d.name, "?") for d in cur.description]

                rows: list[tuple] = []
                row_count = 0
                for row in cur:
                    row_count += 1
                    if len(rows) < _SAMPLE_LIMIT:
                        rows.append(row)

                elapsed = (time.monotonic() - t0) * 1000.0
                out["elapsed_ms"] = round(elapsed, 2)
                out["columns"] = columns
                out["row_count"] = row_count
                out["sample"] = [_jsonify(r) for r in rows]

                conn.rollback()
    except psycopg.errors.QueryCanceled as e:
        print(
            json.dumps({
                "error": "statement_timeout fired",
                "detail": str(e)[:200],
                "statement_timeout_ms": args.statement_timeout_ms,
            }),
            file=sys.stderr,
        )
        return 124
    except psycopg.Error as e:
        print(
            json.dumps({
                "error": "psycopg error",
                "code": getattr(e, "sqlstate", None),
                "detail": str(e)[:500],
            }),
            file=sys.stderr,
        )
        return 1

    print(json.dumps(out, ensure_ascii=False))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="sql-scratch.py")
    p.add_argument(
        "dsn_env",
        help="name of an env var holding the DSN, e.g. PULSE_PG_DSN",
    )
    p.add_argument(
        "--sql-file",
        default=None,
        help="path to SQL file (default: read from stdin)",
    )
    p.add_argument(
        "--explain",
        action="store_true",
        help="prepend EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) "
             "and include the plan in output",
    )
    p.add_argument(
        "--allow-write",
        action="store_true",
        help="skip BEGIN READ ONLY and run in a normal transaction",
    )
    p.add_argument(
        "--statement-timeout-ms",
        type=int,
        default=_DEFAULT_TIMEOUT_MS,
        help=f"PG statement_timeout (ms, default {_DEFAULT_TIMEOUT_MS})",
    )
    return p


def main() -> int:
    return run(build_parser().parse_args())


if __name__ == "__main__":
    sys.exit(main())

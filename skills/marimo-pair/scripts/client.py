#!/usr/bin/env python3
"""marimo-pair client — HTTP plumbing for cell-level helpers.

Shared by run-cell.sh and edit-and-run.sh. Wraps the existing
discover-servers.sh + execute-code.sh primitives instead of re-implementing
them, so there is one source of truth for the marimo API contract.

Subcommands:

  discover [--port PORT]
      Locate a running marimo server + session, extract server-token,
      print full discovery JSON to stdout.

  ping [--port PORT]
      Fast health probe. {"ok": true|false, ...} on stdout, exit 0 on
      success, 2 on failure.

  dump-cells [--port PORT] [--cell-id ID]... [--with-code]
      Dump cell state (id, name, status, errors, config) via code_mode.
      --cell-id may repeat to filter. --with-code includes cell source.

  edit-and-run --cell-id ID --code-file PATH [--port PORT] [--timeout 60]
      Replace cell code via code_mode (ctx.edit_cell), wait for the
      reactive run to settle, return {cell_id, status, errors, took_s,
      wall_s, timed_out}.

      Exit codes: 0 idle/clean, 1 errors[], 124 hard-timeout, 2 not-found,
      other non-zero on transport failure.

  run-cell --cell-id ID [--port PORT] [--timeout 60]
      Re-run an existing cell with its CURRENT code (no edit). Internally:
      dump current code, POST /api/kernel/run, poll until idle.

      Exit codes: same as edit-and-run.

Stdlib only — no third-party packages required on the agent host.
The kernel side still needs marimo's own venv (which is what handles
code_mode).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
DISCOVER_SH = SCRIPT_DIR / "discover-servers.sh"
EXECUTE_SH = SCRIPT_DIR / "execute-code.sh"

_HTTP_TIMEOUT = 5.0
_DUMP_EXEC_TIMEOUT = 30.0
_POLL_DELAYS = (0.1, 0.2, 0.5, 1.0)


def _sh(cmd: list[str], *, input_text: str | None = None,
        timeout: float = 30.0) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd, capture_output=True, text=True, input=input_text,
        timeout=timeout, check=False,
    )


def _http_get_json(url: str, *, auth: str = "") -> Any:
    headers = {"Authorization": f"Bearer {auth}"} if auth else {}
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=_HTTP_TIMEOUT) as r:
        return json.loads(r.read())


def _http_get_text(url: str, *, auth: str = "") -> str:
    headers = {"Authorization": f"Bearer {auth}"} if auth else {}
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=_HTTP_TIMEOUT) as r:
        return r.read().decode("utf-8", errors="ignore")


def discover(port: int | None = None,
             session_id: str | None = None) -> dict[str, Any]:
    """Locate a live marimo server + session, return everything callers need.

    Returns a dict with keys: base, host, port, base_url, server_id,
    session_id, filename, server_token, auth_token.

    Raises RuntimeError with a one-line, human-readable reason if
    discovery fails. No partial returns.
    """
    res = _sh([str(DISCOVER_SH)])
    if res.returncode != 0:
        raise RuntimeError(
            f"discover-servers.sh failed (rc={res.returncode}): "
            f"{res.stderr.strip()[:200] or 'no stderr'}"
        )
    entries = json.loads(res.stdout or "[]")
    if port is not None:
        entries = [e for e in entries if int(e.get("port", 0)) == port]
    if not entries:
        raise RuntimeError(
            "no live marimo server found "
            "(start marimo or pass --port)"
        )
    if len(entries) > 1:
        ids = ", ".join(e.get("server_id", "?") for e in entries)
        raise RuntimeError(
            f"multiple marimo servers running; pass --port. Found: {ids}"
        )
    e = entries[0]
    base = f"http://{e['host']}:{e['port']}{e.get('base_url', '')}"
    auth_token = os.environ.get("MARIMO_TOKEN", "")

    sessions = _http_get_json(f"{base}/api/sessions", auth=auth_token)
    sids = list(sessions.keys())
    if not sids:
        raise RuntimeError(
            "marimo server has no active sessions "
            "(open a notebook in the browser first)"
        )
    if session_id is not None:
        if session_id not in sessions:
            listing = "; ".join(
                f"{k}={v.get('filename', '?')}" for k, v in sessions.items()
            )
            raise RuntimeError(
                f"session_id {session_id!r} not found. Available: {listing}"
            )
        sid = session_id
    elif len(sids) > 1:
        listing = "; ".join(
            f"{k}={v.get('filename', '?')}" for k, v in sessions.items()
        )
        raise RuntimeError(
            f"multiple sessions on server; pass --session-id. {listing}"
        )
    else:
        sid = sids[0]
    filename = sessions[sid].get("filename", "")

    html = _http_get_text(f"{base}/", auth=auth_token)
    m = re.search(r'<marimo-server-token[^>]*data-token="([^"]*)"', html)
    server_token = m.group(1) if m else ""
    if not server_token:
        raise RuntimeError(
            "could not extract Marimo-Server-Token from index HTML "
            "(server may not be in edit-mode)"
        )

    return {
        "base": base,
        "host": e["host"],
        "port": int(e["port"]),
        "base_url": e.get("base_url", ""),
        "server_id": e.get("server_id", ""),
        "session_id": sid,
        "filename": filename,
        "server_token": server_token,
        "auth_token": auth_token,
    }


def _exec_in_kernel(disc: dict[str, Any], code: str, *,
                    timeout: float = _DUMP_EXEC_TIMEOUT) -> str:
    """Run Python in the marimo kernel scratchpad. Returns stdout."""
    args = [
        str(EXECUTE_SH),
        "--url", disc["base"],
        "--session", disc["session_id"],
    ]
    if disc.get("auth_token"):
        args += ["--token", disc["auth_token"]]
    res = _sh(args, input_text=code, timeout=timeout)
    if res.returncode != 0:
        raise RuntimeError(
            "execute-code.sh failed: "
            f"{(res.stderr or res.stdout).strip()[:200]}"
        )
    return res.stdout


_DUMP_TEMPLATE = """\
import json as _json
import marimo._code_mode as _cm

async with _cm.get_context() as ctx:
    _filter = {filter_expr}
    _include_code = {include_code}
    _out = []
    for c in ctx.cells:
        if not _filter(c):
            continue
        _row = {{
            "id": str(c.id),
            "name": c.name or "",
            "status": str(c.status) if c.status is not None else None,
            "errors": [{{"kind": e.kind, "msg": e.msg}} for e in c.errors],
            "config": {{
                "hide_code": c.config.hide_code,
                "disabled": c.config.disabled,
            }},
        }}
        if _include_code:
            _row["code"] = c.code
        _out.append(_row)
    print("CELLDUMP_BEGIN")
    print(_json.dumps(_out))
    print("CELLDUMP_END")
"""


def dump_cells(disc: dict[str, Any], cell_ids: list[str] | None = None, *,
               include_code: bool = False,
               timeout: float = _DUMP_EXEC_TIMEOUT) -> list[dict]:
    """Dump cell state from the kernel via code_mode. cell_ids filters."""
    if cell_ids:
        filt = f"lambda c: str(c.id) in {json.dumps(cell_ids)}"
    else:
        filt = "lambda c: True"
    code = _DUMP_TEMPLATE.format(
        filter_expr=filt,
        include_code=repr(bool(include_code)),
    )
    out = _exec_in_kernel(disc, code, timeout=timeout)
    m = re.search(r"CELLDUMP_BEGIN\n(.*?)\nCELLDUMP_END", out, re.DOTALL)
    if not m:
        raise RuntimeError(
            "dump_cells: missing CELLDUMP markers in kernel output "
            f"(stdout head: {out[:200]!r})"
        )
    return json.loads(m.group(1))


_EDIT_TEMPLATE = """\
import marimo._code_mode as _cm

CELL_ID = {cell_id!r}
with open({code_path!r}, encoding="utf-8") as _f:
    NEW_CODE = _f.read()

# edit_cell raises StaleCellError unless the agent first reads the cell at
# its current version. The reactive run is triggered on context-exit by
# ctx.run_cell(); without it edit_cell queues but never executes.
async with _cm.get_context() as ctx:
    _ = ctx.cells[CELL_ID].code
    ctx.edit_cell(CELL_ID, NEW_CODE)
    ctx.run_cell(CELL_ID)
    print("EDIT_OK", CELL_ID)
"""


def edit_cell(disc: dict[str, Any], cell_id: str, code_file: str, *,
              timeout: float = _DUMP_EXEC_TIMEOUT) -> None:
    """Replace cell code via code_mode. Kernel queues reactive re-run."""
    code = _EDIT_TEMPLATE.format(cell_id=cell_id, code_path=code_file)
    out = _exec_in_kernel(disc, code, timeout=timeout)
    if f"EDIT_OK {cell_id}" not in out:
        raise RuntimeError(
            f"edit_cell {cell_id}: kernel did not confirm EDIT_OK "
            f"(stdout head: {out[:200]!r})"
        )


_RUN_TEMPLATE = """\
import marimo._code_mode as _cm

CELL_ID = {cell_id!r}

# Read cell first so edit_cell-style staleness checks are satisfied for
# any caller that wants to chain an edit afterward. run_cell on its own
# doesn't need the read but the read is free.
async with _cm.get_context() as ctx:
    _ = ctx.cells[CELL_ID].code
    ctx.run_cell(CELL_ID)
    print("RUN_OK", CELL_ID)
"""


def run_cell_kernel(disc: dict[str, Any], cell_id: str, *,
                    timeout: float = _DUMP_EXEC_TIMEOUT) -> None:
    """Queue a cell for re-run via code_mode ctx.run_cell."""
    code = _RUN_TEMPLATE.format(cell_id=cell_id)
    out = _exec_in_kernel(disc, code, timeout=timeout)
    if f"RUN_OK {cell_id}" not in out:
        raise RuntimeError(
            f"run_cell {cell_id}: kernel did not confirm RUN_OK "
            f"(stdout head: {out[:200]!r})"
        )


def interrupt_kernel(disc: dict[str, Any]) -> dict[str, Any]:
    """POST /api/kernel/interrupt to send SIGINT to the kernel process.

    Marimo's session.try_interrupt() does os.kill(pid, SIGINT) under the
    hood — the currently-running cell raises KeyboardInterrupt, in-memory
    state (variables, imports, open connections) survives. Compare with
    /api/kernel/restart which kills + respawns the kernel and nukes every
    variable.

    The endpoint @requires('edit'), which means it needs the
    Marimo-Server-Token header (already discovered into disc['server_token'])
    in addition to Marimo-Session-Id.
    """
    headers = {
        "Content-Type": "application/json",
        "Marimo-Session-Id": disc["session_id"],
        "Marimo-Server-Token": disc["server_token"],
    }
    if disc.get("auth_token"):
        headers["Authorization"] = f"Bearer {disc['auth_token']}"
    req = urllib.request.Request(
        f"{disc['base']}/api/kernel/interrupt",
        data=b"{}",
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=_HTTP_TIMEOUT) as r:
            body = r.read().decode("utf-8", errors="ignore")
            status = r.status
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"POST /api/kernel/interrupt: {e}") from None
    try:
        parsed: Any = json.loads(body) if body else {}
    except json.JSONDecodeError:
        parsed = {"raw": body[:200]}
    return {
        "http_status": status,
        "response": parsed,
        "session_id": disc["session_id"],
    }


def poll_cell(disc: dict[str, Any], cell_id: str, *,
              timeout_s: float = 60.0) -> dict[str, Any]:
    """Adaptive-backoff poll until cell hits a terminal status or timeout.

    Terminal statuses: idle, disabled, or any non-empty errors[].
    Non-terminal: queued, running, None (transient).

    Returns the last cell row + took_s + timed_out.
    """
    start = time.monotonic()
    idx = 0
    while True:
        cells = dump_cells(disc, [cell_id])
        if not cells:
            raise RuntimeError(f"poll_cell: cell {cell_id} not found in kernel")
        c = cells[0]
        status = c.get("status") or ""
        # marimo statuses we treat as terminal:
        if status in ("idle", "disabled") or c.get("errors"):
            return {
                **c,
                "took_s": round(time.monotonic() - start, 3),
                "timed_out": False,
            }
        if time.monotonic() - start > timeout_s:
            return {
                **c,
                "took_s": round(time.monotonic() - start, 3),
                "timed_out": True,
            }
        time.sleep(_POLL_DELAYS[min(idx, len(_POLL_DELAYS) - 1)])
        idx += 1


# ---------------- subcommand entrypoints ---------------------------------


def _cmd_discover(args: argparse.Namespace) -> int:
    print(json.dumps(discover(args.port, args.session_id), indent=2))
    return 0


def _cmd_ping(args: argparse.Namespace) -> int:
    try:
        d = discover(args.port, args.session_id)
    except Exception as e:  # noqa: BLE001 — we want any failure surfaced
        print(json.dumps({"ok": False, "error": str(e)}))
        return 2
    print(json.dumps({
        "ok": True,
        "session_id": d["session_id"],
        "filename": d["filename"],
        "base": d["base"],
    }))
    return 0


def _cmd_dump_cells(args: argparse.Namespace) -> int:
    d = discover(args.port, args.session_id)
    cells = dump_cells(d, args.cell_id or None, include_code=args.with_code)
    print(json.dumps(cells, indent=2))
    return 0


def _cmd_edit_and_run(args: argparse.Namespace) -> int:
    d = discover(args.port, args.session_id)
    t0 = time.monotonic()
    edit_cell(d, args.cell_id, args.code_file)
    result = poll_cell(d, args.cell_id, timeout_s=args.timeout)
    result["wall_s"] = round(time.monotonic() - t0, 3)
    print(json.dumps(result))
    if result.get("timed_out"):
        return 124
    if result.get("errors"):
        return 1
    return 0


def _cmd_interrupt(args: argparse.Namespace) -> int:
    d = discover(args.port, args.session_id)
    result = interrupt_kernel(d)
    print(json.dumps(result))
    if result.get("http_status") != 200:
        return 3
    return 0


def _cmd_run_cell(args: argparse.Namespace) -> int:
    d = discover(args.port, args.session_id)
    # Verify cell exists before triggering a run.
    cells = dump_cells(d, [args.cell_id])
    if not cells:
        print(json.dumps({"error": f"cell {args.cell_id} not found"}))
        return 2
    t0 = time.monotonic()
    run_cell_kernel(d, args.cell_id)
    result = poll_cell(d, args.cell_id, timeout_s=args.timeout)
    result["wall_s"] = round(time.monotonic() - t0, 3)
    print(json.dumps(result))
    if result.get("timed_out"):
        return 124
    if result.get("errors"):
        return 1
    return 0


def _add_session_args(s: argparse.ArgumentParser) -> None:
    s.add_argument("--port", type=int, default=None,
                   help="marimo server port (auto when only one is running)")
    s.add_argument("--session-id", default=None,
                   help="session id (auto when the server has one session)")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="client.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("discover", help="print server/session discovery JSON")
    _add_session_args(s)
    s.set_defaults(fn=_cmd_discover)

    s = sub.add_parser("ping", help="health probe")
    _add_session_args(s)
    s.set_defaults(fn=_cmd_ping)

    s = sub.add_parser("dump-cells", help="dump cell state via code_mode")
    _add_session_args(s)
    s.add_argument("--cell-id", action="append", default=None,
                   help="filter to one cell (repeat to add)")
    s.add_argument("--with-code", action="store_true",
                   help="include cell source in dump")
    s.set_defaults(fn=_cmd_dump_cells)

    s = sub.add_parser("edit-and-run",
                       help="replace cell code + wait for run")
    _add_session_args(s)
    s.add_argument("--cell-id", required=True)
    s.add_argument("--code-file", required=True,
                   help="path to file containing the new cell body")
    s.add_argument("--timeout", type=float, default=60.0,
                   help="hard-timeout for the run (s)")
    s.set_defaults(fn=_cmd_edit_and_run)

    s = sub.add_parser("run-cell",
                       help="re-run existing cell with current code")
    _add_session_args(s)
    s.add_argument("--cell-id", required=True)
    s.add_argument("--timeout", type=float, default=60.0)
    s.set_defaults(fn=_cmd_run_cell)

    s = sub.add_parser("interrupt",
                       help="SIGINT the kernel (preserves in-memory state)")
    _add_session_args(s)
    s.set_defaults(fn=_cmd_interrupt)

    return p


def main() -> int:
    args = build_parser().parse_args()
    try:
        return args.fn(args)
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

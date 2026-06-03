#!/usr/bin/env bash
# Persist the marimo kernel state to disk and lint the notebook.
#
# Why: file edits via ctx.edit_cell / ctx.create_cell / ctx.delete_cell live
# only in the kernel until something calls /api/kernel/save. Cmd+R or any
# unrelated frontend reload re-reads the .py from disk and silently clobbers
# in-memory work. The kernel also blocks any cell that redefines a top-level
# non-`_` name already defined elsewhere — those show as the red banner
# "This cell wasn't run because it has errors / redefines variables from
# other cells", with the cell falling back to displaying its source.
#
# This script makes both failure modes impossible to publish past:
#   1. POSTs SaveNotebookRequest to /api/kernel/save (flush to disk).
#   2. Parses the .py AST and fails on top-level name collisions.
#   3. Reads cell runtime status / errors via code_mode and fails on red cells.
#   4. Optionally enforces hide_code=True on every non-intro cell.
#
# Usage:
#   lint-and-persist.sh [--port PORT | --url URL] [--session ID]
#                       [--strict-hide-code] [session-id]
#   MARIMO_TOKEN=...  for token-auth servers.
#
# Exit codes:
#   0  persisted and clean
#   1  lint failed (collisions / errors / hide_code) — file IS persisted, but
#      the comment with the tailnet URL must not be posted until lint is green
#   2  bad CLI args
#   3  could not reach server / save HTTP failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXEC_SCRIPT="$SCRIPT_DIR/execute-code.sh"
DISCOVER_SCRIPT="$SCRIPT_DIR/discover-servers.sh"
LINT_PY="$SCRIPT_DIR/_lint.py"

port=""
url=""
token="${MARIMO_TOKEN:-}"
session=""
strict_hide_code="false"
positional_session=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)             port="$2"; shift 2 ;;
    --url)              url="$2"; shift 2 ;;
    --token)            token="$2"; shift 2 ;;
    --session)          session="$2"; shift 2 ;;
    --strict-hide-code) strict_hide_code="true"; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" >&2
      exit 0
      ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -n "$positional_session" ]]; then
        echo "Unexpected positional argument: $1" >&2; exit 2
      fi
      positional_session="$1"; shift ;;
  esac
done

if [[ -z "$session" && -n "$positional_session" ]]; then
  session="$positional_session"
fi

# Resolve the server base URL.
if [[ -n "$url" ]]; then
  base="${url%/}"
else
  entries=$("$DISCOVER_SCRIPT")
  total=$(echo "$entries" | jq 'length')
  if [[ "$total" == "0" ]]; then
    echo "No running marimo instances found." >&2
    exit 3
  fi

  if [[ -n "$port" ]]; then
    entry=$(echo "$entries" | jq --argjson p "$port" 'map(select(.port == $p)) | .[0] // empty')
  elif [[ "$total" == "1" ]]; then
    entry=$(echo "$entries" | jq '.[0]')
  else
    echo "Multiple marimo servers running. Pass --port:" >&2
    echo "$entries" | jq -r '.[] | "  --port \(.port)  (\(.server_id))"' >&2
    exit 2
  fi

  if [[ -z "$entry" || "$entry" == "null" ]]; then
    echo "No marimo instance found on port $port." >&2
    exit 3
  fi

  e_host=$(echo "$entry" | jq -r '.host')
  e_port=$(echo "$entry" | jq -r '.port')
  e_base=$(echo "$entry" | jq -r '.base_url')
  base="http://${e_host}:${e_port}${e_base}"
fi

auth_args=()
if [[ -n "$token" ]]; then
  auth_args+=(-H "Authorization: Bearer ${token}")
fi

# Resolve the session id (and validate that the supplied one exists).
sessions_resp=$(curl -sf "${auth_args[@]+"${auth_args[@]}"}" "${base}/api/sessions") || {
  echo "Failed to reach ${base}/api/sessions" >&2; exit 3; }

if [[ -z "$session" ]]; then
  ids=$(echo "$sessions_resp" | jq -r 'keys[]')
  count=$(printf '%s\n' "$ids" | grep -c . || true)
  if [[ "$count" == "0" ]]; then
    echo "No active sessions on the server." >&2; exit 3
  fi
  if [[ "$count" -gt 1 ]]; then
    echo "Multiple sessions on server. Pass <session-id> explicitly:" >&2
    echo "$sessions_resp" | jq -r 'to_entries[] | "  \(.key)  \(.value.filename // "")"' >&2
    exit 2
  fi
  session=$(printf '%s\n' "$ids" | head -1)
fi

session_filename=$(echo "$sessions_resp" | jq -r --arg sid "$session" '.[$sid].filename // empty')
if [[ -z "$session_filename" ]]; then
  echo "Session ${session} not found on server. Available:" >&2
  echo "$sessions_resp" | jq -r 'to_entries[] | "  \(.key)  \(.value.filename // "")"' >&2
  exit 2
fi

# Skew-protection token. /api/kernel/save requires Marimo-Server-Token even
# when the server runs --no-token. It's embedded in the index HTML.
server_token=$(curl -sf "${auth_args[@]+"${auth_args[@]}"}" "${base}/" \
  | grep -oE '<marimo-server-token[^>]*data-token="[^"]*"' \
  | head -1 \
  | sed -E 's/.*data-token="([^"]*)".*/\1/' || true)
if [[ -z "$server_token" ]]; then
  echo "Could not extract Marimo-Server-Token from ${base}/." >&2
  echo "Check that the server is up and serving the edit-mode page." >&2
  exit 3
fi

# Dump cell snapshot (id, code, name, config, status, errors) via code_mode.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cells_path="$tmpdir/cells.json"
dump_path="$tmpdir/dump.txt"

cat > "$tmpdir/dump.py" <<'PY'
import json
import marimo._code_mode as cm

async with cm.get_context() as ctx:
    out = []
    for c in ctx.cells:
        cfg = c.config
        status = c.status
        errors = [{"kind": e.kind, "msg": e.msg} for e in c.errors]
        out.append({
            "id": str(c.id),
            "name": c.name or "",
            "code": c.code,
            "config": {
                "column": cfg.column,
                "disabled": cfg.disabled,
                "hide_code": cfg.hide_code,
            },
            "status": str(status) if status is not None else None,
            "errors": errors,
        })
    print("CELLDUMP_BEGIN")
    print(json.dumps(out))
    print("CELLDUMP_END")
PY

if ! bash "$EXEC_SCRIPT" --url "$base" --session "$session" "$tmpdir/dump.py" \
    > "$dump_path" 2>&1; then
  echo "Failed to dump cell state from kernel:" >&2
  cat "$dump_path" >&2
  exit 3
fi

awk '/CELLDUMP_BEGIN/{flag=1; next} /CELLDUMP_END/{flag=0} flag' "$dump_path" \
  > "$cells_path"
if ! jq -e 'type == "array"' "$cells_path" >/dev/null 2>&1; then
  echo "Cell dump did not produce valid JSON. Raw output:" >&2
  cat "$dump_path" >&2
  exit 3
fi

# Build SaveNotebookRequest and POST it.
save_body=$(jq -n \
  --arg fn "$session_filename" \
  --slurpfile cells "$cells_path" \
  '{
    cellIds: ($cells[0] | map(.id)),
    codes:   ($cells[0] | map(.code)),
    names:   ($cells[0] | map(.name)),
    configs: ($cells[0] | map(.config)),
    filename: $fn,
    persist: true
  }')

http_status=$(curl -s -o "$tmpdir/save.out" -w "%{http_code}" \
  -X POST "${base}/api/kernel/save" \
  -H "Content-Type: application/json" \
  -H "Marimo-Session-Id: ${session}" \
  -H "Marimo-Server-Token: ${server_token}" \
  "${auth_args[@]+"${auth_args[@]}"}" \
  --data-binary "$save_body")

if [[ "$http_status" != "200" ]]; then
  echo "Save failed (HTTP $http_status):" >&2
  cat "$tmpdir/save.out" >&2
  exit 3
fi

echo "ok persisted ${session_filename}"

# Lint the persisted file + cell runtime status. Exit code propagates.
lint_rc=0
python3 "$LINT_PY" "$session_filename" "$strict_hide_code" "$cells_path" \
  || lint_rc=$?

# Refresh /srv/marimo-notebooks/MARIMO_INDEX.md from marimo issue list +
# notebooks. Only on a green lint — a red lint means the notebook is in a
# bad state and shouldn't be advertised to other agents via the index yet.
# Best-effort: a failure here never overrides the lint exit code.
if [[ $lint_rc -eq 0 ]]; then
  bash "$SCRIPT_DIR/build-index.sh" >/dev/null 2>&1 \
    || echo "build-index hook failed (non-fatal)" >&2
fi

exit $lint_rc

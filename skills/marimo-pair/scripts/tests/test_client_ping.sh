#!/usr/bin/env bash
# Verify client.py can discover a live marimo server and report ok=true.
# Skips (exit 77) when no marimo server is discoverable — local dev hosts
# without a marimo notebook open will see this often. Pass --require-kernel
# to run-all.sh to turn the skip into a failure.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$SCRIPTS_DIR/client.py"
DISCOVER="$SCRIPTS_DIR/discover-servers.sh"

# Fast-path skip: if discover-servers.sh returns an empty list, there's
# no live kernel to talk to. Don't fail; signal SKIP.
if [[ "$("$DISCOVER" | jq 'length')" == "0" ]]; then
  echo "test_client_ping: no live marimo server, skipping" >&2
  exit 77
fi

# Resolve a usable session_id even when the server has many open notebooks
# (the brainstorm host normally does — one session per PUL-*.py). ping is
# a pure HTTP probe (no kernel exec), so any session will do for it.
servers_json=$("$DISCOVER")
host=$(echo "$servers_json" | jq -r '.[0].host')
port=$(echo "$servers_json" | jq -r '.[0].port')
base_url=$(echo "$servers_json" | jq -r '.[0].base_url')
base="http://${host}:${port}${base_url}"
session_id=$(curl -sf "${base}/api/sessions" | jq -r 'keys[0]') || {
  echo "test_client_ping: failed to list sessions" >&2
  exit 1
}
if [[ -z "$session_id" || "$session_id" == "null" ]]; then
  echo "test_client_ping: server has no sessions, skipping" >&2
  exit 77
fi

out=$(python3 "$CLIENT" ping --session-id "$session_id")
ok=$(echo "$out" | jq -r '.ok')
if [[ "$ok" != "true" ]]; then
  echo "test_client_ping: ping returned non-ok: $out" >&2
  exit 1
fi

sid=$(echo "$out" | jq -r '.session_id')
if [[ "$sid" != "$session_id" ]]; then
  echo "test_client_ping: ping returned wrong session: want $session_id, got $sid" >&2
  exit 1
fi

echo "test_client_ping: ok (session=$sid)"

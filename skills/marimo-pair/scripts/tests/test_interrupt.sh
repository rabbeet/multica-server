#!/usr/bin/env bash
# Verify POST /api/kernel/interrupt round-trips against a live marimo.
# Skips (77) when no live marimo or no sessions.
#
# We do NOT interrupt a session that is currently running a query (that
# would race with whatever the user is doing). We just verify the
# endpoint accepts the request and returns http_status 200 — sending
# SIGINT to a kernel that's idle is a no-op for the kernel.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$SCRIPTS_DIR/client.py"
DISCOVER="$SCRIPTS_DIR/discover-servers.sh"
INTERRUPT="$SCRIPTS_DIR/interrupt.sh"

if [[ "$("$DISCOVER" | jq 'length')" == "0" ]]; then
    echo "test_interrupt: no live marimo server, skipping" >&2
    exit 77
fi

servers_json=$("$DISCOVER")
host=$(echo "$servers_json" | jq -r '.[0].host')
port=$(echo "$servers_json" | jq -r '.[0].port')
base_url=$(echo "$servers_json" | jq -r '.[0].base_url')
session_id=$(curl -sf "http://${host}:${port}${base_url}/api/sessions" \
    | jq -r 'keys[0]') || {
    echo "test_interrupt: failed to list sessions, skipping" >&2
    exit 77
}
if [[ -z "$session_id" || "$session_id" == "null" ]]; then
    echo "test_interrupt: no sessions, skipping" >&2
    exit 77
fi

out=$(bash "$INTERRUPT" --session-id "$session_id")
rc=$?
if [[ "$rc" != "0" ]]; then
    echo "test_interrupt: interrupt.sh exit $rc; out=$out" >&2
    exit 1
fi

http=$(echo "$out" | jq -r '.http_status')
if [[ "$http" != "200" ]]; then
    echo "test_interrupt: http_status=$http want 200; out=$out" >&2
    exit 1
fi

success=$(echo "$out" | jq -r '.response.success // empty')
if [[ "$success" != "true" ]]; then
    echo "test_interrupt: response.success not true; out=$out" >&2
    exit 1
fi

echo "test_interrupt: ok (session=$session_id)"

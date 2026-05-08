#!/usr/bin/env bash
# agent/deploy.sh — ongoing-update wrapper for the agent-host stack.
# Analog of /opt/deploy-multica.sh but scoped to agent stack only.
#
# Recommended install location on server: /opt/deploy-agent.sh
# (a 2-line shim that calls this script from the cloned multica-server repo)
#
# Or run directly:
#   sudo /opt/multica-infra/agent/deploy.sh
#   sudo /opt/multica-infra/agent/deploy.sh --no-cache    (force fresh image build)
#
# What it does:
#   1. cd into multica-server checkout (where this script lives)
#   2. git fetch + reset --hard origin/main
#   3. docker compose build (--pull or --no-cache) for agent-host
#   4. docker compose up -d for the agent stack
#   5. Wait for agent-host healthcheck
#
# Idempotent. Safe to re-run. Preserves OAuth tokens (named volume).

set -euo pipefail

# Resolve to the multica-infra root (parent of this script's dir).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_DIR="$SCRIPT_DIR"

cd "$INFRA_ROOT"

if [[ ! -d .git ]]; then
    echo "ERROR: $INFRA_ROOT is not a git repo. Did you clone rabbeet/multica-server here?" >&2
    exit 1
fi

echo "==> Pulling rabbeet/multica-server main..."
git fetch origin main
git reset --hard origin/main

cd "$AGENT_DIR"

# Sanity: env file exists (docker compose auto-reads .env in same dir as compose.yml).
if [[ ! -f .env && ! -f "$INFRA_ROOT/.env" ]]; then
    echo "ERROR: no .env found at $AGENT_DIR/.env or $INFRA_ROOT/.env" >&2
    echo "       Required vars (see agent/README.md):" >&2
    echo "         AGENT_PULSE_PAT, AGENT_PLANS_PAT, [AGENT_MULTICA_PAT]" >&2
    echo "         PULSE_AGENT_RO_PW, PULSE_AGENT_CH_PW, PULSE_CH_REPLICA_HOST" >&2
    echo "         PLANS_REPO_PATH=rabbeet/plans" >&2
    exit 1
fi

# Use INFRA_ROOT/.env if agent/.env does not exist (single source of truth pattern).
if [[ ! -f .env && -f "$INFRA_ROOT/.env" ]]; then
    ln -sf "$INFRA_ROOT/.env" .env
fi

echo "==> Building agent-host image..."
if [[ "${1:-}" == "--no-cache" ]]; then
    docker compose -f compose.yml build --no-cache agent-host
else
    docker compose -f compose.yml build --pull agent-host
fi

echo "==> Recreating agent stack..."
docker compose -f compose.yml up -d

echo "==> Waiting for agent-host healthcheck..."
for i in {1..30}; do
    state=$(docker inspect agent-host --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)
    if [[ "$state" == "healthy" ]]; then
        echo "==> agent-host healthy"
        echo ""
        echo "Agents OAuth status:"
        docker exec agent-host bash -c '
            for d in /home/agent/.claude/agent-*/; do
                [ -d "$d" ] || continue
                id=$(basename "$d")
                if [ -f "$d/.claude.json" ]; then
                    echo "  $id: configured"
                else
                    echo "  $id: NOT logged in (run: docker exec -it agent-host bash -c '\''CLAUDE_CONFIG_DIR=$d claude /login'\'')"
                fi
            done
            ls /home/agent/.claude/ 2>/dev/null | grep -q "^agent-" || echo "  (no agents configured yet — first-time setup needed)"
        '
        exit 0
    fi
    sleep 2
done

echo "==> agent-host NOT healthy after 60s — last logs:"
docker compose -f compose.yml logs --tail 50 agent-host
exit 1

#!/usr/bin/env bash
# 14-agent-workers.sh — bring up the agent-host Docker stack (A-lite).
#
# A-lite architecture: 1 long-lived agent-host container hosts N concurrent
# claude processes via CLAUDE_CONFIG_DIR + git worktrees from /srv/pulse-bare.git.
# Multica daemon dispatches per-workspace via `docker exec agent-host
# /usr/local/bin/agent-spawn.sh agent-N`.
#
# Idempotent: re-running rebuilds only if Dockerfile changed; otherwise no-op.
#
# Design ref: ~/.gstack/projects/rabbeet-multica-server/rabbeeet-main-design-20260507-224221.md (A-lite)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

USERNAME="${MULTICA_USER:-multica}"
AGENT_DIR="$(repo_root)/agent"

# Optional feature: skip cleanly if PATs not yet provisioned, same pattern as 13-context-clones.
if [[ -z "${AGENT_PULSE_PAT:-}" || -z "${AGENT_PLANS_PAT:-}" ]]; then
    log_skip "Agent workers skipped: AGENT_PULSE_PAT and/or AGENT_PLANS_PAT not set in .env"
    log_info "  To enable agent-host worker stack:"
    log_info "    1. Generate fine-grained PATs (contents:read+write, repo-scoped) for the projects you want agents to ship to"
    log_info "    2. Add to .env: AGENT_PULSE_PAT=...  AGENT_PLANS_PAT=...  AGENT_MULTICA_PAT=..."
    log_info "    3. Add: PULSE_AGENT_RO_PW=...  PULSE_AGENT_CH_PW=...  PULSE_CH_REPLICA_HOST=..."
    log_info "    4. Add: PLANS_REPO_PATH=rabbeet/plans"
    log_info "    5. Re-run: sudo ./bootstrap.sh 14"
    exit 0
fi

require_vars AGENT_PULSE_PAT AGENT_PLANS_PAT \
             PULSE_AGENT_RO_PW PULSE_AGENT_CH_PW PULSE_CH_REPLICA_HOST \
             PLANS_REPO_PATH

# AGENT_MULTICA_PAT is optional (only when agents touch multica-core repo).
: "${AGENT_MULTICA_PAT:=}"

# Sanity check: docker available.
if ! command -v docker >/dev/null 2>&1; then
    log_error "docker not found — should have been installed by 01-host-deps.sh"
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    log_error "'docker compose' subcommand not available — should have been installed by 01-host-deps.sh"
    exit 1
fi

# ---- /srv directories ----
# Worktrees, bare clone, logs all live in /srv. Bind-mounted into agent-host.

PULSE_BARE=/srv/pulse-bare.git
WORKTREES=/srv/agent-worktrees
LOG_DIR=/var/log/agent

if [[ ! -d "$PULSE_BARE" ]]; then
    log_info "Cloning bare Pulse repo to $PULSE_BARE..."
    PULSE_REPO_HTTPS="${PULSE_REPO_HTTPS:-https://github.com/rabbeet/Pulse.git}"
    pulse_path=${PULSE_REPO_HTTPS#https://github.com/}
    pulse_path=${pulse_path%.git}
    git clone --bare "https://${GITHUB_USER:-rabbeet}:${AGENT_PULSE_PAT}@github.com/${pulse_path}.git" \
        "$PULSE_BARE"
    chgrp -R "$USERNAME" "$PULSE_BARE"
    chmod -R g+rw "$PULSE_BARE"
    chmod g+s "$PULSE_BARE"
    log_ok "bare clone created at $PULSE_BARE (root:multica, group writable)"
else
    log_skip "$PULSE_BARE already exists"
fi

mkdir -p "$WORKTREES" "$LOG_DIR"
chgrp -R "$USERNAME" "$WORKTREES" "$LOG_DIR"
chmod 770 "$WORKTREES" "$LOG_DIR"

# ---- Build & launch ----

cd "$AGENT_DIR"

log_info "Building agent-host image..."
# --pull only on fresh install to keep re-runs fast. -- pulls Ubuntu base on first build.
if ! docker image inspect multica-agent-agent-host >/dev/null 2>&1; then
    docker compose -f compose.yml build --pull agent-host
else
    docker compose -f compose.yml build agent-host
fi

log_info "Starting agent stack..."
# Pass through .env at the compose layer; compose.yml resolves ${VAR} references.
# We deliberately do NOT use --remove-orphans (multica selfhost has its own services).
docker compose -f compose.yml up -d

# ---- Verify smoke ----

# Wait up to 30s for agent-host to become healthy.
log_info "Waiting for agent-host healthcheck..."
for _ in $(seq 1 30); do
    state=$(docker inspect agent-host --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)
    [[ "$state" == "healthy" ]] && break
    sleep 1
done

state=$(docker inspect agent-host --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)
if [[ "$state" != "healthy" ]]; then
    log_warn "agent-host did not reach healthy state in 30s (current: $state)"
    log_warn "Check: docker logs agent-host"
fi

# ---- Next steps ----

cat <<EOF

[14-agent-workers.sh] ✓ stack up.

Next steps (manual — required before first task):

  1. OAuth login for agent-1 (and any other agents you plan to use):

       docker exec -it agent-host bash -c \\
         'CLAUDE_CONFIG_DIR=/home/agent/.claude/agent-1 claude /login'

     Follow the browser link on a device with a browser. Token persists in named
     volume claude-agent-config — survives container restart.

  2. Wire multica.ai to dispatch into the container (Step 0 Check A):

     Verify multica.ai supports docker-exec workspaces. If not, fall back to the
     SSH-tunnel adapter (option c — pre-committed in design).

  3. Verify role+limits on host PG (sudo ./bootstrap.sh 15) BEFORE any task runs.

  4. Run 99-verify.sh smoke checks:

       sudo ./scripts/99-verify.sh

EOF

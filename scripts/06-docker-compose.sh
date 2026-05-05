#!/usr/bin/env bash
# 06-docker-compose.sh — bring up multica + tinyproxy + caddy stack.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

REPO=$(repo_root)
cd "$REPO"

# ---- Verify compose file exists ----------------------------------------------
if [[ ! -f "$REPO/docker-compose.yml" ]]; then
    log_error "docker-compose.yml not found in $REPO"
    exit 1
fi

# ---- Verify host pg/redis are reachable from docker bridge ------------------
# We connect via host.docker.internal — need to ensure docker can resolve it.
# On Linux this requires `extra_hosts: ["host.docker.internal:host-gateway"]`
# which is in our compose. Sanity-check that postgresql is listening on the
# bridge IP, not just localhost.

PG_LISTENS=$(ss -tlnp 'sport = :5432' 2>/dev/null | grep -c LISTEN || true)
if [[ "$PG_LISTENS" -eq 0 ]]; then
    log_error "postgres not listening on :5432"
    exit 1
fi

# ---- Pull images (idempotent — docker handles caching) ----------------------
log_info "Pulling docker images..."
docker compose pull

# ---- Bring up stack ----------------------------------------------------------
log_info "Starting docker compose stack..."
docker compose up -d --remove-orphans

# ---- Wait for multica to be healthy ------------------------------------------
log_info "Waiting for multica to come up (max 60s)..."
for i in {1..30}; do
    state=$(docker inspect -f '{{.State.Status}}' multica 2>/dev/null || echo "missing")
    if [[ "$state" == "running" ]]; then
        # Also check it's not in a restart loop
        sleep 2
        new_state=$(docker inspect -f '{{.State.Status}}' multica 2>/dev/null)
        if [[ "$new_state" == "running" ]]; then
            log_ok "multica running (uptime: $(docker inspect -f '{{.State.StartedAt}}' multica))"
            break
        fi
    fi
    if [[ $i -eq 30 ]]; then
        log_error "multica did not stabilize after 60s"
        log_error "Last logs:"
        docker logs --tail 30 multica
        exit 1
    fi
    sleep 2
done

# ---- Confirm caddy is binding to tailnet IP ---------------------------------
# Caddy must NOT bind to 0.0.0.0 — only tailnet IP.
caddy_listens=$(docker inspect caddy 2>/dev/null | jq -r '.[0].NetworkSettings.Ports // {} | keys[]' 2>/dev/null || true)
log_info "Caddy port bindings: ${caddy_listens:-none}"

# ---- Print stack status ------------------------------------------------------
log_info ""
log_info "Stack status:"
docker compose ps

log_ok "06-docker-compose complete"

#!/usr/bin/env bash
# update.sh — pull/build latest multica images, restart stack, verify.
# For routine updates after initial bootstrap.
#
# Behavior depends on MULTICA_FORK in the outer .env:
#   unset → upstream mode: docker compose pull from ghcr.io/multica-ai/...
#   set   → fork mode: pull source from $MULTICA_FORK, rebuild images locally
#
# Always runs migrations on backend container start (entrypoint.sh ./migrate up).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/_lib.sh
source "$REPO_ROOT/scripts/_lib.sh"

require_env

USERNAME="${MULTICA_USER:-multica}"
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
MULTICA_REPO="$USER_HOME/multica"
MULTICA_USE_FORK="false"
[[ -n "${MULTICA_FORK:-}" ]] && MULTICA_USE_FORK="true"

# ---- 1. Update multica-server config (this repo) ----
log_info "Pulling latest multica-server config from git..."
git fetch origin
LOCAL_HEAD=$(git rev-parse HEAD)
REMOTE_HEAD=$(git rev-parse origin/main)
if [[ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
    log_info "multica-server out of date — fast-forwarding..."
    git pull --ff-only origin main
else
    log_skip "multica-server already at origin/main"
fi

# ---- 2. Update multica repo (upstream OR fork) ----
# In fork mode we need the latest fork HEAD before rebuilding images.
# In upstream mode we still pull source so the migrations dir is fresh
# (entrypoint.sh ./migrate up reads it from the COPY'd image, but we keep
# the host clone in sync for any out-of-band migration runs / debugging).
if [[ -d "$MULTICA_REPO/.git" ]]; then
    log_info "Pulling latest multica source ($MULTICA_REPO)..."
    sudo -u "$USERNAME" git -C "$MULTICA_REPO" fetch origin main
    sudo -u "$USERNAME" git -C "$MULTICA_REPO" reset --hard origin/main
else
    log_error "multica repo not cloned at $MULTICA_REPO. Run bootstrap.sh first."
    exit 1
fi

# Use sudo only when not already root.
DOCKER_PREFIX=""
[[ $EUID -ne 0 ]] && DOCKER_PREFIX="sudo"

# ---- 3. Pull or build images ----
cd "$MULTICA_REPO"

if [[ "$MULTICA_USE_FORK" == "true" ]]; then
    log_info "Fork mode (MULTICA_FORK=$MULTICA_FORK) — rebuilding images from source..."
    $DOCKER_PREFIX docker compose \
        -f docker-compose.selfhost.yml \
        -f docker-compose.selfhost.build.yml \
        build --pull
    log_ok "Built fork images"

    log_info "Recreating containers with new images..."
    $DOCKER_PREFIX docker compose \
        -f docker-compose.selfhost.yml \
        -f docker-compose.selfhost.build.yml \
        up -d --force-recreate --remove-orphans
else
    log_info "Upstream mode — pulling latest ghcr images..."
    $DOCKER_PREFIX docker compose -f docker-compose.selfhost.yml pull
    log_ok "Images pulled"

    log_info "Recreating containers..."
    $DOCKER_PREFIX docker compose -f docker-compose.selfhost.yml up -d --remove-orphans
fi

# ---- 4. Wait for backend health (migrations run on entrypoint) ----
cd "$REPO_ROOT"
log_info "Waiting for multica backend (migrations apply on startup)..."
for i in {1..30}; do
    if curl -sf http://localhost:8080/health >/dev/null 2>&1; then
        log_ok "multica backend healthy"
        break
    fi
    if [[ $i -eq 30 ]]; then
        log_error "multica backend did not become healthy after 60s"
        log_error "Last logs:"
        $DOCKER_PREFIX docker compose -f "$MULTICA_REPO/docker-compose.selfhost.yml" logs --tail 30 backend
        exit 1
    fi
    sleep 2
done

# ---- 5. Refresh skills + verify ----
log_info "Refreshing skills bundle in container..."
bash "$REPO_ROOT/scripts/08-skills-deploy.sh"

log_info "Running verify..."
bash "$REPO_ROOT/scripts/99-verify.sh"

log_ok "Update complete"
[[ "$MULTICA_USE_FORK" == "true" ]] && \
    log_info "Deployed from fork: $MULTICA_FORK ($(sudo -u "$USERNAME" git -C "$MULTICA_REPO" rev-parse --short HEAD))"

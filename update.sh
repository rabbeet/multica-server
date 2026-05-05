#!/usr/bin/env bash
# update.sh — pull latest images, restart stack, verify.
# For routine updates after initial bootstrap.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/_lib.sh
source "$REPO_ROOT/scripts/_lib.sh"

require_env

log_info "Pulling latest config from git..."
git fetch origin
LOCAL_HEAD=$(git rev-parse HEAD)
REMOTE_HEAD=$(git rev-parse origin/main)
if [[ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
    log_info "Local out of date — fast-forwarding..."
    git pull --ff-only origin main
else
    log_skip "Already at origin/main"
fi

log_info "Pulling latest docker images..."
if [[ $EUID -ne 0 ]]; then
    sudo docker compose pull
    sudo docker compose up -d --remove-orphans
else
    docker compose pull
    docker compose up -d --remove-orphans
fi

log_info "Refreshing skills bundle in container..."
bash "$REPO_ROOT/scripts/07-skills.sh"

log_info "Running verify..."
bash "$REPO_ROOT/scripts/99-verify.sh"

log_ok "Update complete"

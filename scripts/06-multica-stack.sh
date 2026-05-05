#!/usr/bin/env bash
# 06-multica-stack.sh — clone multica repo, configure, run their selfhost compose.
#
# Multica's official deployment uses ghcr.io/multica-ai/multica-{backend,web} +
# pgvector/pgvector:pg17. We clone their repo and use their docker-compose.selfhost.yml.
#
# We DO NOT reuse host's native postgres because multica needs pgvector extension.
# The multica pg container listens on host's :5433 (we shift from default :5432
# to avoid colliding with native pg-16 still running for happy/legacy reasons).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

USERNAME="${MULTICA_USER:-multica}"
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
MULTICA_REPO="$USER_HOME/multica"

# ---- Validate POSTGRES_PASSWORD is URL-safe ----
# The password is embedded into DATABASE_URL like postgres://user:PWD@host:port/db.
# Chars like /, +, :, @, ? etc break URL parsing in pgx driver. Reject early.
if [[ "$POSTGRES_PASSWORD" =~ [^A-Za-z0-9_.~-] ]]; then
    log_error "POSTGRES_PASSWORD contains URL-unsafe characters."
    log_error "Use only [A-Za-z0-9_.~-]. Regenerate with: openssl rand -hex 32"
    log_error "Then update .env on server, wipe pg volume, re-run bootstrap:"
    log_error "  cd $MULTICA_REPO && docker compose -f docker-compose.selfhost.yml down -v"
    log_error "  rm $MULTICA_REPO/.env"
    log_error "  ./bootstrap.sh"
    exit 1
fi

# ---- Clone multica repo if not yet ----
if [[ ! -d "$MULTICA_REPO/.git" ]]; then
    log_info "Cloning multica repo into $MULTICA_REPO..."
    sudo -u "$USERNAME" git clone --depth 1 https://github.com/multica-ai/multica.git "$MULTICA_REPO"
    log_ok "Cloned multica repo"
else
    log_skip "multica repo already cloned"
    sudo -u "$USERNAME" git -C "$MULTICA_REPO" fetch --depth 1 origin main
    sudo -u "$USERNAME" git -C "$MULTICA_REPO" reset --hard origin/main
fi

cd "$MULTICA_REPO"

# ---- Generate multica's own .env in their repo dir ----
# This is multica's .env, separate from our multica-server/.env. Their template
# has all THEIR variables (JWT_SECRET, POSTGRES_*, etc.). We pre-fill the ones
# we know; user fills any extras (Google OAuth, S3, Resend) by editing on server.
MULTICA_ENV_FILE="$MULTICA_REPO/.env"
MULTICA_PG_PORT=5433   # avoid collision with native pg-16

if [[ ! -f "$MULTICA_ENV_FILE" ]]; then
    log_info "Generating multica .env from their template..."
    sudo -u "$USERNAME" cp "$MULTICA_REPO/.env.example" "$MULTICA_ENV_FILE"

    # Generate JWT secret (multica requires this)
    JWT_SECRET=$(openssl rand -hex 32)

    # Use our POSTGRES_PASSWORD from outer .env
    sudo -u "$USERNAME" sed -i \
        -e "s|^JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" \
        -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" \
        -e "s|^POSTGRES_PORT=.*|POSTGRES_PORT=$MULTICA_PG_PORT|" \
        "$MULTICA_ENV_FILE"

    chmod 600 "$MULTICA_ENV_FILE"
    chown "$USERNAME":"$USERNAME" "$MULTICA_ENV_FILE"

    log_ok "Generated $MULTICA_ENV_FILE (JWT_SECRET random, POSTGRES_PASSWORD synced)"
else
    log_skip "multica .env already exists"
fi

# ---- Pull official multica images ----
log_info "Pulling multica images (ghcr.io/multica-ai/multica-{backend,web})..."
if sudo -u "$USERNAME" docker compose -f docker-compose.selfhost.yml pull; then
    log_ok "Images pulled"
else
    log_error "Image pull failed (images may not be published yet)"
    log_error "Falling back to building from source: docker compose -f selfhost.build.yml..."
    sudo -u "$USERNAME" docker compose \
        -f docker-compose.selfhost.yml \
        -f docker-compose.selfhost.build.yml \
        build
    log_ok "Built from source"
fi

# ---- Bring up the stack ----
log_info "Starting multica selfhost stack..."
sudo -u "$USERNAME" docker compose -f docker-compose.selfhost.yml up -d

# ---- Wait for backend health ----
log_info "Waiting for multica backend to be ready (max 60s)..."
for i in {1..30}; do
    if curl -sf http://localhost:8080/health >/dev/null 2>&1; then
        log_ok "multica backend healthy"
        break
    fi
    if [[ $i -eq 30 ]]; then
        log_error "multica backend did not become healthy after 60s"
        log_error "Last logs:"
        sudo -u "$USERNAME" docker compose -f docker-compose.selfhost.yml logs --tail 30 backend
        exit 1
    fi
    sleep 2
done

# ---- Confirm running services ----
log_info ""
log_info "Stack status:"
sudo -u "$USERNAME" docker compose -f docker-compose.selfhost.yml ps

log_ok "06-multica-stack complete"
log_info ""
log_info "  Frontend (multica web UI):  http://localhost:3000  (will be reverse-proxied via Tailscale serve)"
log_info "  Backend (CLI/daemon API):   http://localhost:8080"
log_info "  Postgres (pgvector):        localhost:$MULTICA_PG_PORT"

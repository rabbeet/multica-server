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

# MULTICA_FORK: when set in the outer .env, clone from this fork URL and build
# the backend/web images from source instead of pulling published GHCR images.
# Use case: deploying custom changes that haven't landed in upstream
# multica-ai/multica yet. Example value:
#   MULTICA_FORK=https://github.com/rabbeet/multica.git
# When unset (default), behavior matches upstream: clone multica-ai/multica and
# pull ghcr.io/multica-ai/multica-{backend,web}:latest.
MULTICA_REPO_URL="${MULTICA_FORK:-https://github.com/multica-ai/multica.git}"
MULTICA_USE_FORK="false"
[[ -n "${MULTICA_FORK:-}" ]] && MULTICA_USE_FORK="true"

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
# Source = MULTICA_FORK (if set) else upstream multica-ai/multica.
# If the repo already exists locally, also check the remote URL — if it
# diverges from the desired source (e.g., MULTICA_FORK was just enabled or
# changed), update origin to point to the new URL before fetching. This makes
# the script idempotent across upstream → fork transitions on the same host.
if [[ ! -d "$MULTICA_REPO/.git" ]]; then
    log_info "Cloning multica repo into $MULTICA_REPO ($MULTICA_REPO_URL)..."
    # Fork builds need full git history (Dockerfile uses git for build args).
    if [[ "$MULTICA_USE_FORK" == "true" ]]; then
        sudo -u "$USERNAME" git clone "$MULTICA_REPO_URL" "$MULTICA_REPO"
    else
        sudo -u "$USERNAME" git clone --depth 1 "$MULTICA_REPO_URL" "$MULTICA_REPO"
    fi
    log_ok "Cloned multica repo"
else
    CURRENT_URL=$(sudo -u "$USERNAME" git -C "$MULTICA_REPO" remote get-url origin 2>/dev/null || echo "")
    if [[ "$CURRENT_URL" != "$MULTICA_REPO_URL" ]]; then
        log_info "Updating remote origin: $CURRENT_URL → $MULTICA_REPO_URL"
        sudo -u "$USERNAME" git -C "$MULTICA_REPO" remote set-url origin "$MULTICA_REPO_URL"
        # Switching from --depth 1 clone to a fork build needs full history.
        # Unshallowing is idempotent and safe.
        if [[ "$MULTICA_USE_FORK" == "true" ]] && \
           sudo -u "$USERNAME" git -C "$MULTICA_REPO" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
            log_info "Unshallowing repo for fork build..."
            sudo -u "$USERNAME" git -C "$MULTICA_REPO" fetch --unshallow origin main || \
                sudo -u "$USERNAME" git -C "$MULTICA_REPO" fetch origin main
        fi
    else
        log_skip "multica repo already cloned ($MULTICA_REPO_URL)"
    fi
    sudo -u "$USERNAME" git -C "$MULTICA_REPO" fetch origin main
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

# ---- Build or pull images ----
# Fork mode (MULTICA_FORK set): always build from source via the .build.yml
# overlay. The fork's HEAD is the source of truth — there's no published
# ghcr.io/${fork}/multica-* registry to pull from (unless the user sets up
# their own CI; that's Path C in our deploy story).
#
# Upstream mode (default): pull ghcr.io/multica-ai/multica-{backend,web}.
# Falls back to build-from-source on pull failure for resilience.
if [[ "$MULTICA_USE_FORK" == "true" ]]; then
    log_info "MULTICA_FORK set ($MULTICA_REPO_URL) — building images from source..."
    sudo -u "$USERNAME" docker compose \
        -f docker-compose.selfhost.yml \
        -f docker-compose.selfhost.build.yml \
        build --pull
    log_ok "Built fork images (multica-backend:dev, multica-web:dev)"
else
    log_info "Pulling multica images (ghcr.io/multica-ai/multica-{backend,web})..."
    if sudo -u "$USERNAME" docker compose -f docker-compose.selfhost.yml pull; then
        log_ok "Images pulled"
    else
        log_error "Image pull failed (images may not be published yet)"
        log_error "Falling back to building from source..."
        sudo -u "$USERNAME" docker compose \
            -f docker-compose.selfhost.yml \
            -f docker-compose.selfhost.build.yml \
            build
        log_ok "Built from source"
    fi
fi

# ---- Bring up the stack ----
# Fork mode uses the .build.yml overlay so docker compose up resolves the
# locally-built images instead of trying to pull from ghcr again.
log_info "Starting multica selfhost stack..."
if [[ "$MULTICA_USE_FORK" == "true" ]]; then
    sudo -u "$USERNAME" docker compose \
        -f docker-compose.selfhost.yml \
        -f docker-compose.selfhost.build.yml \
        up -d --force-recreate
else
    sudo -u "$USERNAME" docker compose -f docker-compose.selfhost.yml up -d
fi

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

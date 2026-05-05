#!/usr/bin/env bash
# 02-postgres-role.sh — create multica role + DB on host's native postgres.
#
# Per DEPLOYMENT_CONTEXT.md: we DO NOT spin up docker postgres. We use the
# existing system postgres-16 on 127.0.0.1:5432 and create a dedicated
# role + database for the multica daemon.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env
require_vars POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD

# Verify pg is up
if ! systemctl is-active postgresql >/dev/null 2>&1; then
    log_error "postgresql service not active. Start it: systemctl start postgresql"
    exit 1
fi

# Helper: psql as postgres superuser, idempotent
pg_run() {
    sudo -u postgres psql -tAc "$1"
}

# ---- Role --------------------------------------------------------------------
if pg_run "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'" | grep -q '^1$'; then
    log_skip "Role '${POSTGRES_USER}' already exists"
    # Always reset the password to whatever's in .env (safe; idempotent)
    pg_run "ALTER ROLE \"${POSTGRES_USER}\" WITH ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}'"
    log_ok "Refreshed password for role '${POSTGRES_USER}'"
else
    log_info "Creating role '${POSTGRES_USER}'..."
    pg_run "CREATE ROLE \"${POSTGRES_USER}\" WITH LOGIN ENCRYPTED PASSWORD '${POSTGRES_PASSWORD}'"
    log_ok "Created role '${POSTGRES_USER}'"
fi

# ---- Database ----------------------------------------------------------------
if pg_run "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" | grep -q '^1$'; then
    log_skip "Database '${POSTGRES_DB}' already exists"
else
    log_info "Creating database '${POSTGRES_DB}' owned by '${POSTGRES_USER}'..."
    pg_run "CREATE DATABASE \"${POSTGRES_DB}\" OWNER \"${POSTGRES_USER}\""
    log_ok "Created database '${POSTGRES_DB}'"
fi

# Grant just to be safe (CREATE DATABASE OWNER already implies, but explicit)
pg_run "GRANT ALL PRIVILEGES ON DATABASE \"${POSTGRES_DB}\" TO \"${POSTGRES_USER}\""

# ---- pg_hba.conf — allow connections from docker bridge ---------------------
# Multica daemon connects from docker network. The default postgres pg_hba
# typically only allows local socket and 127.0.0.1. We need to allow the
# docker bridge subnet (172.16.0.0/12 covers default + most user-defined networks).
PG_VERSION=$(sudo -u postgres psql -tAc 'SHOW server_version_num' | head -c2)
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

if [[ ! -f "$PG_HBA" ]]; then
    log_warn "pg_hba.conf not at expected path $PG_HBA — skipping pg_hba edit"
else
    HBA_RULE="host    ${POSTGRES_DB}    ${POSTGRES_USER}    172.16.0.0/12    scram-sha-256"
    if grep -qF "$HBA_RULE" "$PG_HBA"; then
        log_skip "pg_hba already permits docker bridge → ${POSTGRES_DB}"
    else
        log_info "Adding pg_hba rule for docker bridge..."
        cp "$PG_HBA" "${PG_HBA}.bak.$(date +%Y%m%d-%H%M%S)"
        echo "" >> "$PG_HBA"
        echo "# multica-server: allow docker bridge → multica DB only" >> "$PG_HBA"
        echo "$HBA_RULE" >> "$PG_HBA"
        log_info "Reloading postgres..."
        systemctl reload postgresql
        log_ok "pg_hba updated; postgres reloaded"
    fi

    # postgresql.conf — listen on docker bridge IP. Default is localhost only.
    # We listen on all interfaces but rely on pg_hba + ufw to restrict.
    PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
    if grep -qE "^listen_addresses\s*=\s*'\\*'" "$PG_CONF"; then
        log_skip "postgres listen_addresses already '*'"
    elif grep -qE "^#?listen_addresses" "$PG_CONF"; then
        log_info "Setting listen_addresses = '*' (docker bridge accessible)..."
        sed -i.bak "s/^#\\?listen_addresses\s*=.*/listen_addresses = '*'/" "$PG_CONF"
        systemctl restart postgresql
        log_ok "postgres restarted, listening on all interfaces"
    fi
fi

# ---- Smoke test the connection -----------------------------------------------
log_info "Smoke-testing connection from local..."
if PGPASSWORD="${POSTGRES_PASSWORD}" psql -h 127.0.0.1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc 'SELECT 1' | grep -q '^1$'; then
    log_ok "Connection smoke test passed"
else
    log_error "Could not connect to ${POSTGRES_DB} as ${POSTGRES_USER}"
    log_error "Check pg_hba.conf, postgresql.conf, and the password in .env"
    exit 1
fi

log_ok "02-postgres-role complete"

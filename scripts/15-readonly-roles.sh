#!/usr/bin/env bash
# 15-readonly-roles.sh — create read-only PG role for agents on host postgres.
#
# This script creates `pulse_agent_ro` on the multica-server's HOST postgres,
# intended for agents' PULSE_PG_DSN when a Pulse dev/staging copy is hosted
# on the same box. Hard limits enforced server-side (P9 — defense vs DoS):
#   - statement_timeout=5s
#   - idle_in_transaction_session_timeout=30s
#   - connection_limit=4
#   - default_transaction_read_only=on
#
# Does NOT create roles on Pulse Forge production. That's a separate PR
# in the Pulse Forge admin scripts (see agent/README.md "Not in this PR").
# CH replica role (agent_ro) lives on Pulse Forge CH instance, also separate.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

if [[ -z "${PULSE_AGENT_RO_PW:-}" ]]; then
    log_skip "PULSE_AGENT_RO_PW not set — skip role creation"
    log_info "  If you have a Pulse dev/staging copy on this host's PG and want agents to read it:"
    log_info "    1. Generate password: openssl rand -hex 32"
    log_info "    2. Add to .env: PULSE_AGENT_RO_PW=..."
    log_info "    3. Re-run: sudo ./bootstrap.sh 15"
    log_info "  Otherwise skip — agents will only have CH replica access until you decide."
    exit 0
fi

# Validate password is URL-safe (used in postgres:// DSN by agents).
if [[ "$PULSE_AGENT_RO_PW" =~ [^A-Za-z0-9_.~-] ]]; then
    log_error "PULSE_AGENT_RO_PW contains URL-unsafe characters."
    log_error "Use only [A-Za-z0-9_.~-]. Regenerate: openssl rand -hex 32"
    exit 1
fi

PULSE_DB="${PULSE_AGENT_RO_DB:-pulse}"

# Sanity: postgres available.
if ! command -v psql >/dev/null 2>&1; then
    log_error "psql not found on host"
    exit 1
fi

# If pulse DB doesn't exist on this host, skip cleanly — pulse may live elsewhere.
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$PULSE_DB'" 2>/dev/null | grep -q 1; then
    log_skip "DB '$PULSE_DB' does not exist on this host's postgres — pulse_agent_ro role not needed here"
    log_info "  This is normal if Pulse runs on Forge production with its own PG instance."
    log_info "  CH replica role lives on Pulse Forge CH (separate PR)."
    exit 0
fi

# ---- Idempotent role creation + privileges ----

sudo -u postgres psql -d "$PULSE_DB" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pulse_agent_ro') THEN
    CREATE ROLE pulse_agent_ro WITH LOGIN PASSWORD '${PULSE_AGENT_RO_PW}'
      CONNECTION LIMIT 4;
    RAISE NOTICE 'Created role pulse_agent_ro';
  ELSE
    -- Update password every run (in case .env rotated)
    EXECUTE format('ALTER ROLE pulse_agent_ro WITH PASSWORD %L', '${PULSE_AGENT_RO_PW}');
    ALTER ROLE pulse_agent_ro CONNECTION LIMIT 4;
    RAISE NOTICE 'Refreshed pulse_agent_ro password + connection limit';
  END IF;
END
\$\$;

-- Hard limits (idempotent — ALTER ROLE SET overrides any prior value)
ALTER ROLE pulse_agent_ro SET statement_timeout = '5s';
ALTER ROLE pulse_agent_ro SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE pulse_agent_ro SET default_transaction_read_only = on;

-- Read-only on existing tables; pg_read_all_data is the modern blanket grant.
GRANT pg_read_all_data TO pulse_agent_ro;

-- Default privileges for any future tables (Pulse migrations on this box).
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO pulse_agent_ro;
SQL

log_ok "pulse_agent_ro on $PULSE_DB: 4 connections, 5s statement_timeout, read-only"

# ---- Smoke test ----
DSN="postgres://pulse_agent_ro:${PULSE_AGENT_RO_PW}@localhost:5432/${PULSE_DB}?sslmode=disable"
if psql "$DSN" -tAc "SELECT 1" 2>&1 | grep -q '^1$'; then
    log_ok "smoke read OK"
else
    log_error "smoke read FAILED — check logs above"
    exit 1
fi

if psql "$DSN" -tAc "CREATE TABLE _agent_smoke_test (id int)" 2>&1 | grep -qi 'read-only'; then
    log_ok "smoke write rejected as expected (default_transaction_read_only)"
else
    log_warn "Expected write rejection — check role permissions"
fi

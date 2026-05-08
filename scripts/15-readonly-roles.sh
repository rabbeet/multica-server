#!/usr/bin/env bash
# 15-readonly-roles.sh — create read-only PG role on host pg for agent-host.
#
# This script creates a `pulse_agent_ro` role on the multica-server's HOST
# postgres. The role is intended for the agent-host container's PULSE_PG_DSN
# when a Pulse dev/staging copy is hosted on this same box.
#
# IMPORTANT — what this script does NOT do:
#   - Does NOT create a role on Pulse Forge production. That requires a
#     separate PR in the Pulse Forge admin scripts (Step 1 of design rollout).
#   - Does NOT create a CH role. CH replica role lives on Pulse Forge CH
#     instance with `agent_ro` user, configured server-side.
#
# Hard limits enforced server-side (per design P9 — defense vs. DoS-via-galuc):
#   - statement_timeout=5s         (one query max)
#   - idle_in_transaction=30s      (no long-held connections)
#   - max_connections=4             (concurrency budget for N=2-3 agents)
#   - default_transaction_read_only (refuses UPDATE/DELETE/DROP at PG level)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

if [[ -z "${PULSE_AGENT_RO_PW:-}" ]]; then
    log_skip "PULSE_AGENT_RO_PW not set — skip role creation"
    log_info "  If you have a Pulse dev/staging copy on this host's PG and want agents to read it:"
    log_info "    1. Generate a strong password: openssl rand -hex 32"
    log_info "    2. Add to .env: PULSE_AGENT_RO_PW=...  (must match agent compose env)"
    log_info "    3. Re-run: sudo ./bootstrap.sh 15"
    log_info "  Otherwise skip — agents will only have CH replica access until you decide."
    exit 0
fi

# Validate password is URL-safe — same constraint as 06-multica-stack.sh enforces.
if [[ "$PULSE_AGENT_RO_PW" =~ [^A-Za-z0-9_.~-] ]]; then
    log_error "PULSE_AGENT_RO_PW contains URL-unsafe characters (used in postgres:// DSN)."
    log_error "Use only [A-Za-z0-9_.~-]. Regenerate: openssl rand -hex 32"
    exit 1
fi

PULSE_DB="${PULSE_AGENT_RO_DB:-pulse}"

# Sanity: postgres available.
if ! command -v psql >/dev/null 2>&1; then
    log_error "psql not found on host"
    exit 1
fi

# If the DB doesn't exist on this host, skip gracefully — pulse may live elsewhere.
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$PULSE_DB'" | grep -q 1; then
    log_skip "DB '$PULSE_DB' does not exist on this host's postgres — pulse_agent_ro role not needed here"
    log_info "  This is normal if Pulse runs on Forge production with its own PG instance."
    log_info "  CH replica role lives on Pulse Forge CH (separate PR)."
    exit 0
fi

# ---- Idempotent role creation + privileges ----

# psql DO blocks let us declare the create-or-update logic transactionally.
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

-- Limits (idempotent — ALTER ROLE SET overrides any prior value)
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
# Verify role works and write attempts fail.
DSN="postgres://pulse_agent_ro:${PULSE_AGENT_RO_PW}@localhost:5432/${PULSE_DB}?sslmode=disable"
if psql "$DSN" -tAc "SELECT 1" 2>&1 | grep -q '^1$'; then
    log_ok "smoke read OK"
else
    log_error "smoke read FAILED — check logs above"
    exit 1
fi

# Verify a destructive op is rejected.
if psql "$DSN" -tAc "CREATE TABLE _agent_smoke_test (id int)" 2>&1 | grep -qi 'read-only'; then
    log_ok "smoke write rejected as expected (default_transaction_read_only)"
else
    log_warn "Expected write rejection — check role permissions"
fi

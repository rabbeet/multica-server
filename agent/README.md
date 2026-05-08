# Agent stack (A-lite)

One always-on Docker container (`agent-host`) hosts N concurrent claude processes,
each isolated by `CLAUDE_CONFIG_DIR` + git worktree from `/srv/pulse-bare.git`.

Multica daemon dispatches per-workspace by calling:

```bash
docker exec agent-host /usr/local/bin/agent-spawn.sh agent-N
```

Each spawn:
1. Sets `CLAUDE_CONFIG_DIR=/home/agent/.claude/agent-N`
2. Symlinks `/etc/agent-settings.json` into the config dir
3. Fetches latest `main` into `/srv/pulse-bare.git`
4. Cleans up any stale worktree, creates a fresh per-task branch
5. `cd` into the worktree and `exec claude`

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | ubuntu:24.04 + node + bun + php 8.3 + clickhouse + gh + claude CLI 2.1.132 (pinned) |
| `agent-spawn.sh` | Per-process spawn entrypoint (called by multica daemon via docker exec) |
| `agent-healthcheck.sh` | Cron'd liveness check for OAuth + dev-PG sidecars |
| `agent-settings.json` | Claude permissions (deny push to main, read-only PG via dedicated role) |
| `CLAUDE-agent.md` | Agent-specific system context (different from brainstorm CLAUDE.md) |
| `compose.yml` | Stack: tinyproxy + agent-host + pg-agent-1 + pg-agent-2 |
| `tinyproxy.conf` + `tinyproxy-filter.txt` | Egress allowlist (Anthropic, GitHub, host PG, CH replica) |
| `lib.sh` | Shared bash helpers for in-container scripts |

## Required `.env` variables

The host's `multica-server/.env` must include the following before
`scripts/14-agent-workers.sh` will run. Generate fresh PATs per the rules in
`docs/DESIGN.md` (security model). Keep these out of the repo — they live only
in the host's `.env` (mode 600).

```
# === Agent stack ===

# Fine-grained PATs (90-day expiry, contents:read+write, repo-scoped):
AGENT_PULSE_PAT=<fine-grained PAT for the Pulse repo (push feature/* — branch protection on main enforces no direct main push)>
AGENT_PLANS_PAT=<fine-grained PAT for the plans repo (push to main allowed; this is audit log)>
AGENT_MULTICA_PAT=<optional fine-grained PAT for multica-ai/multica when agents work on multica-core>

# Password for pulse_agent_ro role on host postgres (URL-safe: [A-Za-z0-9_.~-]):
PULSE_AGENT_RO_PW=<openssl rand -hex 32>
PULSE_AGENT_RO_DB=pulse  # optional, defaults to pulse

# CH replica access (created server-side on Pulse Forge — see docs/DESIGN.md Step 1):
PULSE_AGENT_CH_PW=<password for agent_ro user on CH replica>
PULSE_CH_REPLICA_HOST=ch-replica.tail38d0e3.ts.net  # Tailscale-routed CH replica

# Plans repo (owner/repo, no .git suffix):
PLANS_REPO_PATH=rabbeet/plans

# Reuse from notify-shipped.yml pattern (optional but recommended):
TELEGRAM_BOT_TOKEN=<existing bot token>
TELEGRAM_CHAT_ID=<existing chat id>
```

## OAuth login (manual, one-time per agent)

After `bootstrap.sh 14` brings the stack up:

```bash
# agent-1 (always required)
docker exec -it agent-host bash -c \
  'CLAUDE_CONFIG_DIR=/home/agent/.claude/agent-1 claude /login'

# agent-2 (when you start parallelizing)
docker exec -it agent-host bash -c \
  'CLAUDE_CONFIG_DIR=/home/agent/.claude/agent-2 claude /login'
```

Token persists in named volume `claude-agent-config` — survives container restart.

## Health-check + Telegram alert

`agent-healthcheck.sh` runs every 15 min via cron inside the container. On
failure (OAuth expired, claude binary unreachable, dev-PG down) it writes to
`/var/log/agent/agent-N/health.jsonl` and sends a Telegram alert with the
re-auth command.

Phone-side recovery: SSH via Tailscale → run the re-auth command → done.

## Limits + defenses (P9)

The agent runs claude with these constraints:

- **PG (server-side)**: `statement_timeout=5s`, `idle_in_transaction=30s`, `connection_limit=4`, `default_transaction_read_only=on`
- **CH (server-side)**: `max_execution_time=10s`, `max_concurrent_queries_for_user=2`, `max_memory_usage_for_user=512Mi`
- **Tinyproxy**: explicit allowlist; `FilterDefaultDeny=Yes`
- **Claude permissions** (`agent-settings.json`): no push to main/master, no force push, no `gh repo create`, no remote add/set-url
- **Branch protection** on receiving repos (Pulse + multica-core) — first defense layer (see `TODOS.md` P1)

## Lifecycle

```bash
# Bring up
sudo ./bootstrap.sh 14

# Tear down (preserves OAuth tokens in named volume; preserves bare clone)
docker compose -f agent/compose.yml down

# Tear down + wipe OAuth + worktrees (destructive)
docker compose -f agent/compose.yml down -v
sudo rm -rf /srv/pulse-bare.git /srv/agent-worktrees /var/log/agent
```

## Resource budget

| N agents | agent-host RAM | pg-agent sidecars | Total committed |
|---|---|---|---|
| 1 | 4G | 256M | ~4.3G |
| 2 | 4G | 512M | ~4.5G |
| 3 | **6G needed** (bump compose limit) | 768M | ~6.8G |

Validation in `scripts/09-validate-resources.sh`: must keep `>= 8 GiB` available
on the host after start. If N=3 needed, edit `agent/compose.yml`:
`memory: 6G`.

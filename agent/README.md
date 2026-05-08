# Agent stack — host-process, multica.ai-native

Per-agent claude isolation **using multica.ai's own primitive** (`agent.custom_env`).
No Docker container. No tinyproxy in front of agents. No spawn-script wrapper.

## How it works

```
multica daemon (host process, user multica)
     │
     │  agent created in multica.ai UI:
     │    custom_env={CLAUDE_CONFIG_DIR=/home/multica/.claude/agent-1}
     │    custom_args=[--cwd, /srv/agent-worktrees/agent-1]
     │    provider=claude
     │
     ▼  daemon spawns:
     pkg/agent/claude.go → exec.Command("claude", custom_args...)
                            with custom_env merged into child process env
     │
     ▼
claude CLI runs as user multica with:
  CLAUDE_CONFIG_DIR=/home/multica/.claude/agent-1   ← own OAuth + own .claude.json
  cwd=/srv/agent-worktrees/agent-1                  ← own git worktree
```

Each agent in the multica.ai workspace = one row in the `agent` table = one
isolated claude session. multica daemon dispatches.

## Files

| File | Purpose |
|---|---|
| `agent-settings.json` | Claude permissions — denies (push to main, repo create, force push) and allows (read+write own worktree, push to agent-*/feature/* branches, gh pr create, dev-PG access). Bind-symlinked into each `/home/multica/.claude/agent-N/settings.json`. |
| `README.md` | This file. |

## Required `.env` variables

The host's `multica-server/.env` must have these before running
`scripts/14-agent-host-prep.sh`:

```
# Fine-grained PATs (90-day expiry, contents:read+write):
AGENT_PULSE_PAT=<PAT for the Pulse repo — push agent-*/feature/* branches>
AGENT_PLANS_PAT=<PAT for the plans repo — push to main allowed (audit log)>
AGENT_MULTICA_PAT=<optional PAT for multica fork repo>

# Read-only PG role on host PG (only meaningful if Pulse dev/staging copy lives here):
PULSE_AGENT_RO_PW=<openssl rand -hex 32>
PULSE_AGENT_RO_DB=pulse        # optional, defaults to "pulse"

# Read-only CH on Pulse Forge replica (set up server-side on Pulse Forge separately):
PULSE_AGENT_CH_PW=<password for agent_ro user on CH replica>
PULSE_CH_REPLICA_HOST=ch-replica.tail38d0e3.ts.net

# Plans repo path (owner/repo):
PLANS_REPO_PATH=rabbeet/plans

# Telegram alerts (reuse from notify-shipped.yml):
TELEGRAM_BOT_TOKEN=<bot token>
TELEGRAM_CHAT_ID=<chat id>

# GitHub user (for git-credentials clone of pulse-bare):
GITHUB_USER=rabbeet
```

## Server-side install

After `bootstrap.sh` ran (or as standalone re-run after this PR lands):

```bash
sudo ./scripts/14-agent-host-prep.sh    # bare clone + worktree dirs + per-agent .claude/ dirs
sudo ./scripts/15-readonly-roles.sh     # pulse_agent_ro PG role with hard limits
```

Both are idempotent — re-run safely.

## Per-agent OAuth login (one-time per agent)

```bash
# agent-1
sudo -u multica CLAUDE_CONFIG_DIR=/home/multica/.claude/agent-1 claude /login

# agent-2
sudo -u multica CLAUDE_CONFIG_DIR=/home/multica/.claude/agent-2 claude /login
```

Follow the browser link from any device. Token saved at
`/home/multica/.claude/agent-N/.claude.json`. Survives restart.

## multica.ai agent configuration

In multica.ai web UI (or via API), create N agents in your workspace. For each
agent, set:

| Field | Value |
|---|---|
| name | `agent-1` (etc.) |
| provider | `claude` |
| model | `claude-opus-4.7` (or as appropriate) |
| runtime_mode | (whatever your daemon uses — likely `local` or `host`) |
| custom_env | `CLAUDE_CONFIG_DIR=/home/multica/.claude/agent-1` |
| custom_args | (optional — `--cwd /srv/agent-worktrees/agent-1` if claude supports it; otherwise rely on the spawn cwd from runtime_config) |
| instructions | reference to `/plan-and-implement` skill |

Repeat with `agent-2`, etc. The numeric suffix in `custom_env` must match the
on-disk directory created by `scripts/14-agent-host-prep.sh`.

## Hard limits (P9 — DoS defense)

Server-side, independent of how agents run:

- **PG `pulse_agent_ro`**: `statement_timeout=5s`, `idle_in_transaction_session_timeout=30s`,
  `connection_limit=4`, `default_transaction_read_only=on`, `pg_read_all_data` grant
  (created by `scripts/15-readonly-roles.sh`).
- **CH `agent_ro`** (server-side on Pulse Forge replica — separate PR, not in this repo):
  `max_execution_time=10s`, `max_concurrent_queries_for_user=2`,
  `max_memory_usage_for_user=512Mi`.

## Defense in depth (P5)

Three independent gates between PR and prod:

1. **Branch protection on `main`** — receiving repo (Pulse, multica fork) requires
   PR review + CI green; agents cannot push to `main` directly. Enforced server-side
   by GitHub. See TODOS.md P1 #1.
2. **Claude code review** on every PR — existing automation triggers on PR open.
3. **CI test suite** on every PR — existing.

Plus Claude-layer denies in `agent-settings.json` (no `git remote add`,
`gh repo create`, force push) as a fourth, agent-process-local layer.

## Trade-offs vs Docker-isolation approach

| Concern | Docker A-lite (PR #1, reverted) | Host-process A-lite (this PR) |
|---|---|---|
| Per-agent OAuth state | Container + named volume | `CLAUDE_CONFIG_DIR` on host |
| Per-agent worktree | Container bind-mount | `/srv/agent-worktrees/agent-N/` directly |
| Per-agent egress allowlist | tinyproxy + filter (strict) | None — agents share daemon's egress |
| Per-agent kernel namespace | Yes | No — same Linux user, same network |
| Image build & maintenance | Dockerfile, ~3GB image | None |
| RAM cost | ~3 GiB ceiling | ~claude process * N |
| Compatibility with multica.ai daemon | Required workspace API patch | Native — uses `agent.custom_env` |
| Lines in this repo | ~1500 lines | ~400 lines |

Trade: lose per-agent egress sandbox; gain native multica integration + 90% less code + zero "does multica.ai support docker workspaces" risk.

For solo personal infra with branch-protection + Claude-review + CI as belt-and-suspenders, the egress sandbox loss is acceptable.

## Not in this PR (separate work)

- **Per-agent dev-PG sidecars for migration testing** — deferred. Workaround for
  v1: agents test migrations against a per-task schema in host's PG via the
  `pulse_dev_agent` role (out of scope for this PR — open Q in `/plan-and-implement`).
- **Schema dump upgrade in Pulse Forge** — separate PR in `rabbeet/Pulse`. Closes
  the root-cause of the status_flow case.
- **CH replica + agent_ro user** — server-side on Pulse Forge.
- **Branch protection rules** — manual GitHub UI (see `TODOS.md` P1).

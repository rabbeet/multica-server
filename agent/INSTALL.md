# Agent stack — server install guide

How to deploy the A-lite agent worker stack on the existing Contabo server,
alongside (NOT inside) the multica fork that lives at `/opt/multica-server/`.

## Naming clarity

| Path on server | What it contains | Source |
|---|---|---|
| `/opt/multica-server/` | **multica fork** (rabbeet/multica) — TypeScript monorepo | `git clone rabbeet/multica.git` |
| `/opt/multica-infra/` | **infra repo** (rabbeet/multica-server) — bash + agent stack | NEW — created by this guide |
| `/opt/deploy-multica.sh` | Update wrapper for the multica fork | Existing |
| `/opt/deploy-agent.sh` | Update wrapper for the agent stack | NEW — created by this guide |

The `/opt/multica-server/` directory name is historical — it predates the multica-server infra repo getting that same name. Don't conflate them.

## First-time install (one-shot)

Run as root on the Contabo server.

### Step 1 — clone infra repo

```bash
sudo git clone https://github.com/rabbeet/multica-server.git /opt/multica-infra
sudo chmod 755 /opt/multica-infra
cd /opt/multica-infra
```

### Step 2 — env file with agent vars

The agent stack needs its own env separate from `/opt/multica-server/.env` (which is multica's runtime config, irrelevant here).

Two options for where the agent env lives:

**Option A (preferred):** dedicated env file at `/opt/multica-infra/.env`. The `agent/deploy.sh` script auto-symlinks `agent/.env` → `../env` if `agent/.env` does not exist.

**Option B:** dedicated env file at `/opt/multica-infra/agent/.env`. Use this if you want agent vars completely isolated from anything else multica-infra ever needs.

Required variables (see `agent/README.md` for value descriptions):

```
AGENT_PULSE_PAT=...        # fine-grained PAT, contents:read+write on rabbeet/Pulse
AGENT_PLANS_PAT=...        # fine-grained PAT, contents:read+write on rabbeet/plans
AGENT_MULTICA_PAT=...      # OPTIONAL — if agents work on multica-ai/multica too
PULSE_AGENT_RO_PW=...      # password for pulse_agent_ro role (URL-safe alnum + _.-~)
PULSE_AGENT_CH_PW=...      # password for agent_ro on CH replica (set up in Pulse Forge)
PULSE_CH_REPLICA_HOST=...  # e.g. ch-replica.tail38d0e3.ts.net
PLANS_REPO_PATH=rabbeet/plans
TELEGRAM_BOT_TOKEN=...     # reuse from notify-shipped.yml setup
TELEGRAM_CHAT_ID=...       # reuse
GITHUB_USER=rabbeet        # for git-credentials clone of pulse-bare
PULSE_REPO_HTTPS=https://github.com/rabbeet/Pulse.git    # OPTIONAL override
```

Permissions:

```bash
sudo chmod 600 /opt/multica-infra/.env
sudo chown root:root /opt/multica-infra/.env
```

### Step 3 — run the bootstrap scripts

These create `/srv/pulse-bare.git`, `pulse_agent_ro` PG role, and bring up the docker stack.

```bash
cd /opt/multica-infra
sudo ./scripts/14-agent-workers.sh    # bare clone + agent compose up
sudo ./scripts/15-readonly-roles.sh   # pulse_agent_ro role with hard limits (skips if pulse DB not on host)
sudo ./scripts/99-verify.sh           # smoke checks — Section 8 covers agent stack
```

If `15-readonly-roles.sh` skips with "DB does not exist on this host" — that is normal when Pulse runs on Forge prod, not on this multica server. The CH replica role is the only PROD-data path; it lives on Pulse Forge (separate PR).

### Step 4 — first-time OAuth login

```bash
sudo docker exec -it agent-host bash -c \
  'CLAUDE_CONFIG_DIR=/home/agent/.claude/agent-1 claude /login'
```

Follow the browser link on a device with a browser. Token persists in named volume `claude-agent-config` — survives container restart and host reboot.

If you want to start with N=2 agents from day one, repeat with `agent-2`.

### Step 5 — install the deploy wrapper

```bash
sudo ln -sf /opt/multica-infra/agent/deploy.sh /opt/deploy-agent.sh
sudo chmod +x /opt/deploy-agent.sh
```

Now `sudo /opt/deploy-agent.sh` updates the agent stack the same way `/opt/deploy-multica.sh` updates the multica fork.

### Step 6 — verify

```bash
sudo /opt/multica-infra/scripts/99-verify.sh
```

Section 8 covers the agent stack. Watch for:
- agent-host running + claude --version OK
- /srv/pulse-bare.git mounted
- pg-agent-1, pg-agent-2 healthy
- read-only role rejects writes (only checked if `PULSE_AGENT_RO_PW` is set)
- statement_timeout=5s enforced
- agent-tinyproxy running

## Ongoing updates

When something changes in `rabbeet/multica-server` (new agent-spawn flag, claude CLI version bump, new skill):

```bash
sudo /opt/deploy-agent.sh
```

Or with full image rebuild (e.g. claude CLI version pin changes):

```bash
sudo /opt/deploy-agent.sh --no-cache
```

OAuth tokens persist in the named volume — re-deploy does NOT log you out.

## Adding agents over time

When you decide N=2 → N=3 (per design Eng Issue 4.1, after observing queueing for 2 weeks):

1. Edit `/opt/multica-infra/agent/compose.yml`: bump `agent-host -> deploy.resources.limits.memory: 6G` (each claude process uses ~1G under load).
2. Add a `pg-agent-3` sidecar following the existing per-N pattern.
3. Update `DEV_PG_HOSTS` env to `pg-agent-1,pg-agent-2,pg-agent-3`.
4. Run `sudo /opt/deploy-agent.sh`.
5. OAuth login for agent-3:
   ```bash
   sudo docker exec -it agent-host bash -c \
     'CLAUDE_CONFIG_DIR=/home/agent/.claude/agent-3 claude /login'
   ```
6. Update multica.ai workspace config to add the new workspace.
7. Re-run `99-verify.sh`.

Run `12-validate-resources.sh` after to confirm host RAM headroom is still ≥ 8 GiB.

## Wiring multica.ai (Step 0 Check A from design)

multica daemon needs to know how to dispatch a workspace into the container. Two options the design pre-committed to:

**Option (a) — multica.ai native docker workspace**: if multica.ai supports a workspace `type: docker-exec` (or similar), config:
```yaml
workspaces:
  - id: agent-1
    type: docker-exec
    container: agent-host
    cmd: /usr/local/bin/agent-spawn.sh agent-1
```

**Option (c, fallback) — SSH-tunnel adapter**: if (a) is not supported, configure a workspace as a remote shell pointing at `localhost` with a wrapper that runs `docker exec` under the hood:
```bash
# /usr/local/bin/multica-agent-1-shell.sh
exec sudo docker exec -i agent-host /usr/local/bin/agent-spawn.sh agent-1
```
Then a multica `type: shell` workspace points at that script.

Which option works depends on multica.ai's workspace primitives. Inspect:

```bash
ls /opt/multica-server/apps/server/   # multica TypeScript daemon source
grep -ri "workspace" /opt/multica-server/server/ 2>/dev/null | head -20
```

## Removing the agent stack

```bash
cd /opt/multica-infra/agent
sudo docker compose -f compose.yml down -v   # destructive: drops OAuth tokens
sudo rm -rf /srv/pulse-bare.git /srv/agent-worktrees /var/log/agent
sudo -u postgres psql -d pulse -c "DROP ROLE IF EXISTS pulse_agent_ro"
```

The multica fork at `/opt/multica-server/` is untouched.

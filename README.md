# multica-server

Personal infrastructure repo. Bootstraps a self-hosted [multica.ai](https://multica.ai)
instance on a single server, behind Tailscale, with a separate brainstorm Claude
account whose capabilities are sharply isolated.

This is a single-developer infra project, not a product. Read [docs/DESIGN.md](docs/DESIGN.md)
for the architecture, security model, and decisions. Read [docs/DEPLOYMENT_CONTEXT.md](docs/DEPLOYMENT_CONTEXT.md)
for the actual server reality (Contabo VPS) and how this codebase adapts to it.

## What this repo does

When you run `./bootstrap.sh` on a fresh (or reasonably-clean) Ubuntu 24.04 host:

1. Installs missing host packages (yq, tailscale, mosh, tmux, direnv, jq).
2. Adds an 8 GB swapfile (idempotent — skips if present).
3. Joins Tailscale tailnet `tail38d0e3.ts.net` (idempotent — skips if `BackendState=Running`).
4. Creates Linux user `multica` (dynamic UID 1100-1199, avoids collision with existing `claude` user from happy CLI).
5. Creates a `multica_brainstorm` PostgreSQL role + `multica` database on the host's existing native postgres (does NOT spin up docker pg).
6. Reserves Redis DB index 5 (host's existing native redis; happy uses 0/1).
7. Deploys multica + tinyproxy (egress allowlist) + caddy (TLS via Tailscale MagicDNS) via `docker compose up -d`.
8. Installs gstack-style skills (`/publish-plan`, `/archive-plan`) into the multica container.
9. Sets up daily PostgreSQL backups via systemd timer (retention configurable).
10. (Optional) Clones `rabbeet/Pulse` (`:ro`) and `rabbeet/agent-context` (`:ro`, auto-generated DB schema dumps) into `/srv/` and installs an hourly `git fetch + reset --hard` timer — lets the brainstorm Claude reference real Pulse code + DB stats during travel-mode planning. Skips cleanly if `PULSE_READONLY_PAT` / `AGENT_CONTEXT_READONLY_PAT` are not in `.env`.
12. (Optional, A-lite worker stack) Brings up the `agent-host` container — one always-on Docker container hosting N concurrent claude processes via `CLAUDE_CONFIG_DIR` + git worktrees from `/srv/pulse-bare.git`. Multica daemon dispatches per-workspace via `docker exec`. Each agent gets full project access: read-only PROD PG/CH (hard limits), per-N dev-PG sidecar for migration testing, push to `agent-*/feature/*` branches only. Replaces the old brainstorm → /pickup-plan handoff with single-agent end-to-end flow. Skips cleanly if `AGENT_PULSE_PAT` / `AGENT_PLANS_PAT` not set. See `agent/README.md`.
11. Verifies everything via `99-verify.sh`.

Re-running `./bootstrap.sh` is safe — every script is idempotent and short-circuits when its work is already done.

## What it intentionally does NOT do

- **No Pulse worktrees on this host.** Pulse stays on the user's Mac. The `pickup-plan` skill ships separately and is installed on the Mac, not here. See `mac-skills/`.
- **No docker postgres / docker redis.** The host has native installations. We reuse via `host.docker.internal`.
- **Not a multi-tenant deployment.** One Tailscale identity (`rabbeet@github`), one Linux user (`multica`).
- **Not portable across providers without edits.** Assumes Ubuntu 24.04, systemd, Contabo-class VPS. Other providers may need swap/firewall tweaks.

## Layout

```
multica-server/
├── README.md                    # this file
├── bootstrap.sh                 # single entrypoint (idempotent)
├── update.sh                    # docker compose pull + up -d + verify
├── teardown.sh                  # clean reset
├── .env                         # YOU create this; never committed
├── .env.example                 # template; copy to .env and fill from password manager
├── docker-compose.yml           # multica + tinyproxy + caddy
├── config/
│   ├── caddy/Caddyfile          # TLS via tailscale auto-cert
│   ├── tinyproxy/tinyproxy.conf # egress allowlist for brainstorm container
│   └── claude/settings.json     # deny/allow rules for brainstorm-Claude
├── scripts/                     # numbered; bootstrap.sh runs them in order
│   ├── _lib.sh                  # shared helpers (set -euo pipefail, log)
│   ├── 01-host-deps.sh
│   ├── 02-postgres-role.sh
│   ├── 03-tailscale-up.sh
│   ├── 04-multica-user.sh
│   ├── 05-swapfile.sh
│   ├── 06-docker-compose.sh
│   ├── 07-skills.sh
│   ├── 08-postgres-backup.sh
│   ├── 09-validate-resources.sh
│   └── 99-verify.sh
├── skills/                      # bundled with this repo, deployed in container
│   ├── publish-plan/SKILL.md
│   └── archive-plan/SKILL.md
├── mac-skills/                  # NOT installed on this server; for user's Mac
│   └── pickup-plan/SKILL.md
├── systemd/                     # installed by 08-postgres-backup.sh
│   ├── multica-pg-backup.service
│   └── multica-pg-backup.timer
└── docs/
    ├── DESIGN.md                # architectural source of truth
    └── DEPLOYMENT_CONTEXT.md    # server-specific overrides + locked decisions
```

## First-time deployment

On the server (Ubuntu 24.04, root or sudo-able account):

```bash
# 1. Clone
cd /opt
sudo git clone https://github.com/rabbeet/multica-server.git
sudo chown -R "$USER":"$USER" /opt/multica-server
cd /opt/multica-server

# 2. Fill .env from password manager
cp .env.example .env
chmod 600 .env
${EDITOR:-vim} .env
# Required:
#   TAILSCALE_AUTHKEY
#   BRAINSTORM_PAT
#   POSTGRES_PASSWORD       (generate fresh: openssl rand -base64 24)
# Reused from Pulse Forge:
#   none (Telegram secrets are GH Actions secrets in plans repo, not here)

# 3. Run bootstrap
./bootstrap.sh
```

After bootstrap finishes (~3-5 min on this hardware):

```bash
# 4. First-time Claude OAuth in container
docker exec -it multica claude /login
# Follow browser link, authenticate as your brainstorm account.
# Token persists in named volume claude-brainstorm-config; survives restarts.

# 5. Open multica web UI from your phone
# https://multica.tail38d0e3.ts.net
```

## Day-to-day operations

```bash
# Update images and restart
./update.sh

# Tear down (preserves /srv/plans-multica clone and pg data; removes containers)
./teardown.sh

# Manual health check
./scripts/99-verify.sh

# Restore Postgres from a daily backup
ls /var/backups/multica/         # find the dump you want
sudo -u postgres pg_restore -d multica /var/backups/multica/multica-2026-05-04.dump
```

## Plans flow

This repo is half of a system. The other half is [`rabbeet/plans`](https://github.com/rabbeet/plans):

```
PHONE (Safari)
  ↓
multica.tail38d0e3.ts.net  (this repo)
  ↓
brainstorm Claude in container runs /office-hours
  ↓
/publish-plan skill commits to /srv/plans-multica + push to rabbeet/plans
  ↓                                                              ↓
GitHub Action: notify-shipped.yml watches main             Cloudflare Pages: deploy plans dashboard
  ↓                                                              ↓
Telegram nudge when status: shipped                          plans dashboard at *.pages.dev
                                                                 ↓
                                                          MAC: pickup-plan skill claims a ready plan
                                                                 ↓
                                                          /executing-plans in pulseN worktree on Mac
                                                                 ↓
                                                          /ship → status: shipped → loop closes
```

## Security model — short version

Five layers of isolation for the brainstorm Claude container. Each is a separate
defense; even if one fails the others hold:

1. **Filesystem**: rootfs read-only, only `/srv/plans-multica/` and named config volume are writable. No host secrets mounted.
2. **Network egress**: tinyproxy with allowlist (api.anthropic.com, github.com:443, host.docker.internal). No default gateway in the container's docker network.
3. **Claude permissions** (`config/claude/settings.json`): deny ssh/scp/forge/curl-to-anywhere; allow Read/Edit only in `/srv/plans-multica/` and read-only `/workdir/pulse-docs/` (no source code from Pulse on this host anyway).
4. **No DB access**: the container connects to the host's postgres ONLY for multica's own tables. It cannot reach Pulse production DBs.
5. **Git deploy creds**: only fine-grained PAT for `rabbeet/plans`. Cannot push to any other repo.

Full details in `docs/DESIGN.md` Security Model section.

## Disaster recovery

| Scenario | Recovery time | Steps |
|---|---|---|
| VPS dies, fresh server | ~15-20 min | new VPS + `git clone` + `cp .env.example .env` + fill secrets + `./bootstrap.sh` |
| Multica DB corrupted | ~2-5 min | `pg_restore` from `/var/backups/multica/` (daily dumps via systemd timer) |
| Plans repo lost | ~1 min | already on GitHub; `git clone` again into `/srv/plans-multica/` |
| Tailscale identity compromised | ~10 min | revoke key in admin, generate new auth-key, edit `.env`, `./bootstrap.sh` |
| GitHub PAT leaked | ~2 min | revoke at github.com/settings/tokens; generate new fine-grained PAT; edit `.env`; `docker compose restart multica` |

## Why not Forge / Ansible / k8s

This is personal infra for one developer on one server. Forge is for app servers
running PHP/Node behind nginx — wrong shape. Ansible is overkill for a single
host with a deterministic install. Kubernetes is comically wrong-sized.

`bootstrap.sh` + idempotent shell scripts is the right shape: zero learning curve,
inspectable, version-controlled, reproducible. If this grows beyond one host, we
can migrate to Ansible later — the shell scripts are already structured to translate
cleanly.

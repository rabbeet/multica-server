# Deployment Context — Contabo VPS (2026-05-05 recon)

This document amends `docs/DESIGN.md` with **actual server state** discovered post-design.
DESIGN.md remains the architectural source of truth. Where this file conflicts with DESIGN.md,
**this file wins** for `/executing-plans` and `bootstrap.sh` scope.

## Server Facts

| Field | Value |
|---|---|
| Provider | Contabo |
| Hostname | `vmi3257524` (Contabo default — keep as-is, MagicDNS handles naming) |
| OS | Ubuntu 24.04.4 LTS (Noble Numbat) |
| Kernel | Linux 6.8.0-106-generic |
| Architecture | x86_64 |
| CPU | 8 vCPU, AMD EPYC 7282 |
| RAM | 31 GiB total (21 GiB available at recon) |
| **Swap** | **0 B — bootstrap should add 4–8 GiB swapfile** |
| Disk | 232 GiB total, 210 GiB free on `/` |
| IPv4 | `79.143.186.231/24` (eth0) |
| IPv6 | `2a02:c207:2325:7524::1/64` (eth0) |
| Default user | `root` (we operate as root for bootstrap, then drop privileges) |

## Existing Services (must coexist, not collide)

| Service | Where | Owner | Decision |
|---|---|---|---|
| `postgres 16` | `127.0.0.1:5432`, system package | `postgres` | **Reuse**: create role `multica_brainstorm` + DB `multica` on existing cluster. No docker-pg in compose. |
| `redis-server` | `127.0.0.1:6379`, system package | `redis` | **Reuse**: dedicated DB index `5` (avoid `0/1` likely used by happy). No docker-redis in compose. |
| `happy` daemon + 4 workers + 1 active session | user `claude`, mise-installed | `claude` | **Coexist**: do not touch. happy stays as user's existing remote-Claude tool. multica is brainstorm-only. |
| docker container `igor` (ubuntu:24.04) | docker | unknown | **Preserve**: do not stop, do not migrate. Confirm with user if it still serves a purpose. |
| `sshd` | `0.0.0.0:22` | system | **Preserve**: only public listener. Tailscale will add `100.x.y.z:443` for multica HTTPS via Caddy. |
| `containerd` + `fail2ban` | system | system | Already fine, no action. |

## Scope Deltas to DESIGN.md

DESIGN.md was written with assumption "existing 5 Pulse-clones on server (`~/coding/pulse{,2..5}`)".
Reality: `/root/coding/` does not exist; `/srv/` is empty. Pulse-worktrees live on user's Mac mini.

This means **multica-server scope shrinks**:

### REMOVED from bootstrap

- `scripts/07-pulse-worktrees.sh` — not needed (Pulse stays on Mac).
- `/srv/plans-pulse{,2,3,4,5}` clones — only `/srv/plans-multica` is created on Contabo.
- `systemd/tmux-pulse@.service` — no Pulse on this host.
- Lock #2 (Eng review): port mapping `pulse=8000…pulse5=8004` — not relevant on Contabo.
- Lock #4 (5 worktrees RAM budget): does not apply on this host (no worktrees here). Validation moves to user's Mac.

### ADDED 2026-05-06 (Pulse-context extension)

- `scripts/13-context-clones.sh` — clones `rabbeet/Pulse` (main, depth=1) → `/srv/pulse-code/` and `rabbeet/agent-context` (full) → `/srv/agent-context/`. Both owned `root:multica` 750. Installs `multica-context-pull.timer` (hourly + on boot) for `git fetch + reset --hard origin/main`. PATs land in `/root/.git-credentials` (mode 600), never visible to user `multica`.
- New env vars required: `PULSE_READONLY_PAT`, `AGENT_CONTEXT_READONLY_PAT` (both fine-grained, contents:read, single-repo scope, 90d expiry).
- Optional override env vars (defaults shown): `PULSE_REPO_HTTPS=https://github.com/rabbeet/Pulse.git`, `AGENT_CONTEXT_REPO_HTTPS=https://github.com/rabbeet/agent-context.git`.
- `99-verify.sh` Section 7 — checks both clones exist, timer is active, and `agent-context/pulse/INDEX.md` `last_dump_at` is fresh (<30h).
- `config/claude/settings.json` — adds `Read(/srv/pulse-code/**)` + `Read(/srv/agent-context/**)` to allow list. Edit/Write on these paths NOT in allow → file mode + Claude permission both enforce read-only.
- See `.gstack/projects/rabbeet-multica-server/rabbeeet-main-design-20260506-120148.md` for the full design rationale (CEO + Eng + outside-voice cleared).

### KEPT from bootstrap

- `scripts/01-host-deps.sh` — slimmer (docker, fail2ban already present; install yq, tailscale, mosh, tmux, direnv, jq).
- `scripts/02-postgres-role.sh` — **new**, replaces docker-pg setup. Creates role `multica_brainstorm`, DB `multica`, password from `.env`.
- `scripts/03-tailscale-up.sh` — unchanged.
- `scripts/04-multica-user.sh` — creates `multica` user (UID dynamic 1100–1199, avoids collision with existing `claude` UID). NOT `claude` user (that's happy's).
- `scripts/05-docker-compose.sh` — multica + tinyproxy + caddy, no pg/redis services (reuse host).
- `scripts/06-skills.sh` — copies `skills/{publish-plan,archive-plan}/` into `~multica/.claude/skills/` and bind-mounts into multica container. **`pickup-plan` skill goes to user's Mac, not this server** (Pulse runs there).
- `scripts/08-swapfile.sh` — **new**, adds 8 GiB swapfile (server has 0 swap).
- `scripts/09-validate-resources.sh` — checks `free -m` after multica starts. Alert if `<6 GiB available`.
- `scripts/99-verify.sh` — write+read+delete test inside multica container, plans-repo deploy access, egress allowlist test.

### CHANGED from bootstrap

- DSN in `docker-compose.yml`: multica daemon connects to `host.docker.internal:5432/multica` (host pg) and `host.docker.internal:6379/5` (host redis), NOT internal docker network services.
- `04-multica-user.sh`: home is `/home/multica`, repo checkout at `/home/multica/multica-server/`, plans clone at `/srv/plans-multica/` (root-owned, group `multica` writable).
- Egress allowlist (tinyproxy): + `host.docker.internal` for pg/redis.

## Tailscale

- Tailnet: `tail38d0e3.ts.net`
- multica MagicDNS name: `multica.tail38d0e3.ts.net`
- Auth-key & ACL setup: user has key in password manager (paste into `.env` as `TAILSCALE_AUTHKEY`).
- ACL tag: `tag:multica-host`. Only `rabbeet@github` has access.

## Identities

- GitHub handle: `rabbeet` (from `git remote -v`).
- Linux user (multica owner on Contabo): `multica`.
- Linux user (happy owner, untouched): `claude`.
- Domain for plans dashboard: **deferred** — start with Cloudflare Pages fallback `*.pages.dev`, add custom domain later.

## Open Items (non-blocking for bootstrap, surface during /executing-plans)

1. **`igor` container** — what is it? If user confirms it's stale, add cleanup step.
2. **Telegram notifier** — bot token + chat ID required for `notify-shipped.yml`. If user hasn't created bot yet, GH Action will be committed but secret unset (Action will skip with non-fatal warning per existing design).
3. **Backups** — DESIGN.md Open Question #3 (off-server pg backup destination). Defer to post-bootstrap; for now, daily local pg_dump under `/var/backups/multica/`.

## Verification Checklist (pre-`/executing-plans`)

- [x] DESIGN.md committed to `rabbeet/multica-server` main
- [x] plans-repo initialized (`rabbeet/plans` main)
- [x] Server reachable, OS confirmed Ubuntu 24.04
- [x] Existing services catalogued
- [x] Tailnet name known
- [x] User decision on coexistence captured
- [ ] `.env` filled on server (deferred to user — secret manager → `/home/multica/multica-server/.env`)

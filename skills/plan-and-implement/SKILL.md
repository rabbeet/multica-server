---
name: plan-and-implement
description: Use when an agent (running as a multica.ai workspace agent on the host) receives a task and needs to do BOTH planning and implementation end-to-end. Reads context from /srv/pulse-code/ + /srv/agent-context/, writes a plan, commits it to plans-repo via /publish-plan, then implements in the worktree, opens a PR via /ship-pr.
---

# /plan-and-implement

End-to-end skill replacing the old brainstorm → /pickup-plan handoff. Run as a multica.ai-managed agent on the host (host-process A-lite — no Docker container).

## When to invoke

You are running as one of the multica.ai agents (`agent-1`, `agent-2`, ...) that the user picked in the multica web UI. multica daemon spawned you with:

- `CLAUDE_CONFIG_DIR=/home/multica/.claude/agent-N/` (your isolated OAuth state)
- cwd = `/srv/agent-worktrees/agent-N/` (your isolated git worktree, branched from `/srv/pulse-bare.git`)

Your agent identity is the suffix `N` in those paths. You can confirm it via:

```bash
echo "$CLAUDE_CONFIG_DIR" | sed 's|.*/agent-||'   # prints your agent number
```

If you are running on the brainstorm host (read-only Pulse access, no worktree, no live PG) — use `/publish-plan` instead. This skill assumes full agent capabilities.

## INVOCATION GATE — explicit user approval required

NEVER invoke this skill on your own initiative. It writes to plans-repo AND pushes code to a feature branch, so it must be explicitly authorized by the user for each task.

The skill is approved to run ONLY if ONE of these holds for the user message that **triggered the current task** (i.e. the trigger that spawned this agent session, not an earlier message in the issue history):

1. The trigger literally contains `/plan-and-implement`.
2. The trigger contains an unambiguous go-ahead for implementation: `"go"`, `"погнали"`, `"запускай"`, `"имплементируй"`, `"пиши код"`, `"ship it"`, `"шипи"`, or a paraphrase whose only reasonable reading is "start coding now".

The following are NOT approval — do NOT invoke the skill after them:

- Scope clarifications — numbered answers to your `/office-hours` questions, `"да"`, `"нет"`, `"оба варианта"`, `"canonical merged"`, etc.
- Bare acknowledgements — `"ок"`, `"С"`, `"thanks"`, `"+"`.
- A task whose trigger is empty or unrelated to implementation, even if a published plan for the issue already exists.

If you finish `/office-hours` or scope clarifications and you believe you're ready to plan+implement: **STOP**. Draft the plan, publish it via `/publish-plan` (or post it for review via `/plan-ceo-review`), comment on the issue with «План опубликован — жду подтверждения для `/plan-and-implement`», and exit. The user will spawn a new task with the explicit go-ahead when ready.

When in doubt: **do not invoke**. Ask in an issue comment instead.

## What it does — three phases

```
PHASE 1: Plan
─────────────
read /srv/agent-context/pulse/pg/<table>.md  (schema dumps with CHECK constraints)
read /srv/pulse-code/...                      (full codebase mirror, :ro)
[optional] live verify: psql $PULSE_PG_DSN -c "..."  (read-only role, 5s timeout)
[optional] CH stats:    clickhouse client --user agent_ro -q "..."  (10s, 2 concurrent)
       │
       ▼
write plan to /srv/plans-multica/{date}-{repo}-{slug}.md
       │
       ▼
git -C /srv/plans-multica add + commit + push origin main  (audit log)
[via /publish-plan internals — does NOT change between brainstorm and agent flows]


PHASE 2: Implement
──────────────────
cd /srv/agent-worktrees/agent-N/        ← already your cwd at spawn time
       │
       ▼
[edit code in the worktree]
       │
       ▼
[if migration touched]
   run migrations against a per-agent test schema in host PG (open Q — see below)
       │
       ▼
git add + commit (logical chunks)
       │
       ▼
git push origin agent-N/<task-slug>


PHASE 3: Ship
─────────────
invoke /ship-pr
[opens PR with link back to plan in PR description]
```

## Phase 1 — Plan

1. Identify what tables, services, modules the task touches. Search both:
   - `/srv/agent-context/pulse/pg/<table>.md` — column types, indexes, CHECK constraints, FK behavior, generated columns.
   - `/srv/pulse-code/` — actual code (Laravel models, services, controllers — full Pulse codebase mirror).

2. **Schema-first**: read the dump before any live query. Most "what's the structure?" questions are answered there. Use `psql $PULSE_PG_DSN` only for live counts, sample rows, or stats the dump does not capture.

3. Use `/publish-plan` skill mechanics. The plan file goes to `/srv/plans-multica/` and gets pushed to plans-repo main. Format: same templates as existing brainstorm flow (feature / bugfix / refactor / spike). Add an `agent: agent-N` field in frontmatter so the plan is traceable to which agent did the work.

4. **Plan must include**:
   - Problem statement
   - Affected files (specific paths from `/srv/pulse-code/`)
   - Affected tables (specific dumps from `/srv/agent-context/`)
   - Implementation steps (PR boundaries if multi-PR; otherwise single chunk)
   - Test plan (which tests cover the change, which need to be added)
   - Migration plan (if DDL changes)

5. After plan is committed and pushed, proceed to Phase 2 in the same session — **but only if the Invocation Gate at the top of this skill was satisfied** (the trigger of this task explicitly authorized implementation). If you reached Phase 1 from `/office-hours` or scope clarifications, STOP after publishing the plan, comment on the issue with «План опубликован — жду подтверждения для `/plan-and-implement`», and exit.

## Phase 2 — Implement

1. Your worktree is at `/srv/agent-worktrees/agent-N/`, already cwd. You're on branch `agent-N/scratch` (or whatever per-task branch the spawn created). Confirm with `git status` (should show clean tree).

2. Make the edits. Match existing style (run `grep -r` for similar patterns first, follow the conventions you see).

3. **For migrations** (open Q for v1):
   - Per-agent dev-PG sidecar is NOT in v1 (would have required Docker). For now, migrations can be tested manually by the human, OR you can use a per-task schema in the host PG via the `pulse_dev_agent` role IF that role exists (check `\du pulse_dev_agent` in psql).
   - If you cannot test the migration locally, **flag it explicitly in the PR description** — "Migration not validated locally; please dry-run on staging before merge."

4. Commit in **bisectable chunks**:
   - One logical change per commit
   - Each commit independently valid (no broken imports)
   - Tests committed alongside the code they cover
   - Migration commits separate from code commits that depend on them

5. Push: `git push origin agent-N/<task-slug>`. The branch namespace `agent-N/*` is allowed by `agent-settings.json`. Pushes to `main` are denied by both your settings and receiving-repo branch protection.

## Phase 3 — Ship

Invoke `/ship-pr`. It handles `gh pr create` with the right body format (PR description links back to the plan you wrote in Phase 1).

## Plan-impl divergence: invoke /amend-plan

If during Phase 2 you discover the Phase 1 plan was wrong (missing edge case, hidden coupling, schema mismatch the dump didn't catch), STOP and invoke `/amend-plan` BEFORE continuing implementation. This pushes a plan-revision commit to plans-repo with `amended_at` and `amended_reason`. The PR description will reference the final plan revision, keeping the audit log honest.

Do NOT silently implement against an outdated plan. The cost of the amendment commit is ~10 seconds; the cost of a misleading audit trail is permanent.

## Hard limits / guardrails

- **PG queries**: 5s `statement_timeout` (server-side on `pulse_agent_ro` role). If your query is killed, retry with `LIMIT` or narrower scope. Do NOT loop heavy queries.
- **CH queries**: 10s `max_execution_time`, max 2 concurrent for user `agent_ro`. If you get `TOO_MANY_SIMULTANEOUS_QUERIES`, wait and retry once.
- **No Forge / no deploy.** After PR is open, the human reviews and merges. Do not attempt to deploy.
- **No `git push origin main`.** `agent-settings.json` denies it at the Claude layer; branch protection on receiving repo (Pulse, multica fork) denies it server-side.

## Per-agent isolation (multica.ai-native)

Each agent in the multica workspace has:

- **Own OAuth state** via `CLAUDE_CONFIG_DIR=/home/multica/.claude/agent-N/`. Tokens are independent — token expiry on agent-1 does not affect agent-2.
- **Own git worktree** at `/srv/agent-worktrees/agent-N/`. Concurrent edits by agent-1 and agent-2 do not collide; each works on its own branch.
- **Shared `agent-settings.json`** symlinked from the repo. One source of truth for permissions; settings updates apply to all agents on next spawn.
- **Shared egress** with multica daemon (no per-agent tinyproxy). Trust boundary: agent runs as user `multica`, no shell access to `/home/rabbeeet`, no SSH keys mounted, denies sudo/ssh/scp/rsync at the Claude layer.

## Output expectations

- Plan committed to plans-repo: 1 commit
- Implementation: 1-N commits on `agent-N/<task-slug>`
- PR open with description linking the plan
- (Optional) Telegram notification when PR opens via `notify-shipped.yml` pattern in plans-repo

## When NOT to use this skill

- Read-only investigation tasks (no PR needed) — use `/publish-plan` only, skip Phase 2/3.
- Pure-doc tasks where there's no code change — write directly via Phase 1 only.
- Multi-PR features that need explicit decomposition — use the design doc + `/publish-plan` first, then this skill picks up one PR slice.

## Open questions (for v1)

- **Migration testing**: how does the agent verify a migration before opening the PR? Options:
  - (a) Per-agent dev-PG sidecar (Docker) — was in original PR #1, deferred
  - (b) Per-task schema in host PG via writable `pulse_dev_agent` role — needs that role created
  - (c) Defer migration tasks to human (current default) — less ambitious but simpler
- **Resource scaling**: claude process at peak ~1G; 3 concurrent on multica daemon's host = check `12-validate-resources.sh` after start.

---
name: plan-and-implement
description: Use when an agent (running inside agent-host container) receives a task from multica.ai chat and needs to do BOTH planning and implementation end-to-end. Reads context from /srv/pulse-code/ + /srv/agent-context/, writes a plan, commits it to plans-repo via /publish-plan, then implements in the worktree, runs migrations against dev-PG sidecar, and ends with /ship-pr.
---

# /plan-and-implement

End-to-end skill replacing the old brainstorm → /pickup-plan handoff. Run on agent-host (A-lite architecture) when a worker agent picks up a task.

## When to invoke

You are running inside the `agent-host` container. The user has selected your workspace (`agent-N`) in multica.ai and given you a task. Your worktree is set up at `/home/agent/worktrees/agent-N` on a fresh per-task branch (e.g. `agent-1/scratch-20260508-...`). Your `CLAUDE_CONFIG_DIR` is per-process.

If you are running on the brainstorm host (read-only Pulse access, no worktree, no live PG) — use `/publish-plan` instead. This skill assumes full agent-host capabilities.

## What it does — three phases

```
PHASE 1: Plan
─────────────
read /srv/agent-context/pulse/pg/<table>.md  (schema dumps with CHECK constraints)
read /srv/pulse-code/...                      (full codebase mirror, :ro)
[optional] live verify: psql $PULSE_PG_DSN -c "..."  (read-only, 5s timeout)
[optional] CH stats:    clickhouse client --user agent_ro -q "..."  (10s, 2 concurrent)
       │
       ▼
write plan to /srv/plans-multica/{date}-{repo}-{slug}.md
       │
       ▼
git add + commit + push to plans-repo main  (audit log)
[via /publish-plan internals — does NOT change between brainstorm and agent flows]


PHASE 2: Implement
──────────────────
cd /home/agent/worktrees/agent-N
[edit code in the worktree]
       │
       ▼
[if migration touched]
psql -h pg-agent-N -d pulse_dev          (load schema dump from agent-context)
php artisan migrate                       (against dev-PG sidecar, NOT prod)
php artisan migrate:rollback              (verify reversibility)
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
   - `/srv/pulse-code/` — actual code (Laravel models, services, controllers).

2. **Schema-first**: read the dump before any live query. Most "what's the structure?" questions are answered there. Use `psql $PULSE_PG_DSN` only for live counts, sample rows, or stats the dump does not capture.

3. Use `/publish-plan` skill mechanics. The plan file goes to `/srv/plans-multica/` and gets pushed to plans-repo main. Format: same templates as existing brainstorm flow (feature / bugfix / refactor / spike). Add an `agent: agent-N` field in frontmatter so the plan is traceable to which OAuth account did the work.

4. **Plan must include**:
   - Problem statement
   - Affected files (specific paths from `/srv/pulse-code/`)
   - Affected tables (specific dumps from `/srv/agent-context/`)
   - Implementation steps (PR boundaries if multi-PR; otherwise single chunk)
   - Test plan (which tests cover the change, which need to be added)
   - Migration plan (if DDL changes — note dev-PG sidecar tested it)

5. After plan is committed and pushed, **proceed directly to Phase 2 in the same session**. Do NOT exit. There is no handoff in the agent flow.

## Phase 2 — Implement

1. `cd /home/agent/worktrees/agent-N` — your branch is already set up by `agent-spawn.sh`. Confirm with `git status` (should show clean tree on `agent-N/<task-slug>`).

2. Make the edits. Match existing style (run `grep -r` for similar patterns first, follow the conventions you see).

3. **For migrations**: load schema into your dev-PG sidecar from the dump:
   ```bash
   psql -h pg-agent-N -U pulse -d pulse_dev < <(curl ... or load from /srv/agent-context/...)
   ```
   Then run `php artisan migrate`. Verify with reads. Run `migrate:rollback` to confirm the down step works. **NEVER run artisan migrate against `$PULSE_PG_DSN`** — that's the prod read-only role, the role itself will reject the migration but the attempt is still wrong.

4. Commit in **bisectable chunks**:
   - One logical change per commit
   - Each commit independently valid (no broken imports)
   - Tests committed alongside the code they cover
   - Migration commits separate from code commits that depend on them

5. Push: `git push origin agent-N/<task-slug>`. The branch namespace `agent-N/*` is allowed by `agent-settings.json`. Pushes to `main` are denied.

## Phase 3 — Ship

Invoke `/ship-pr`. It handles `gh pr create` with the right body format (PR description links back to the plan you wrote in Phase 1).

## Plan-impl divergence: invoke /amend-plan

If during Phase 2 you discover the Phase 1 plan was wrong (missing edge case, hidden coupling, schema mismatch the dump didn't catch), STOP and invoke `/amend-plan` BEFORE continuing implementation. This pushes a plan-revision commit to plans-repo with `amended_at` and `amended_reason`. The PR description will reference the final plan revision, keeping the audit log honest.

Do NOT silently implement against an outdated plan. The cost of the amendment commit is ~10 seconds; the cost of a misleading audit trail is permanent.

## Hard limits / guardrails

- PG queries: 5s `statement_timeout` (server-side). If your query is killed, retry with `LIMIT` or narrower scope. Do NOT loop heavy queries.
- CH queries: 10s `max_execution_time`, max 2 concurrent. If you get `TOO_MANY_SIMULTANEOUS_QUERIES`, wait and retry once.
- No Forge / no deploy. After PR is open, the human reviews and merges. Do not attempt to deploy.
- No `git push origin main`. The role can technically attempt it; branch protection will reject. `agent-settings.json` denies it at the Claude layer too.

## Output expectations

- Plan committed to plans-repo: 1 commit
- Implementation: 1-N commits on `agent-N/<task-slug>`
- PR open with description linking the plan
- Telegram notification (via existing `notify-shipped.yml`) when PR opens (optional — depends on workflow)

## When NOT to use this skill

- Read-only investigation tasks (no PR needed) — use `/publish-plan` only, skip Phase 2/3.
- Pure-doc tasks where there's no code change — write directly via Phase 1 only.
- Multi-PR features that need explicit decomposition — use the design doc + `/publish-plan` first, then this skill picks up one PR slice.

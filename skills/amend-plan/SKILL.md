---
name: amend-plan
description: Use mid-implementation when the agent discovers the original plan in plans-repo was wrong (missing edge case, hidden coupling, schema mismatch). Pushes a plan-revision commit to plans-repo with amended_at and amended_reason fields, keeping the audit log honest. Defends against "published-plan-then-implemented-something-different" lying-by-omission.
---

# /amend-plan

Mid-implementation correction. Run when you (the agent) realize the plan you committed in Phase 1 of `/plan-and-implement` does not match what the implementation actually needs.

## When to invoke

You're in Phase 2 of `/plan-and-implement`. While editing code, you found:
- A constraint you missed in Phase 1 (CHECK constraint, FK cycle, generated column).
- A hidden coupling — the change touches a file/table the plan didn't enumerate.
- A schema mismatch — agent-context dump was stale OR the plan misread it.
- The original approach won't work and you're switching to a different design.

You have two choices:
1. Continue implementing, ship a PR that contradicts its own plan, leave a misleading audit log → **NEVER do this.**
2. Invoke this skill → push a plan-revision commit → continue implementing → ship a PR that links to the up-to-date plan. **Always do this.**

## What it does

```
read /srv/plans-multica/{plan-filename}.md  (the plan you wrote in Phase 1)
       │
       ▼
edit the plan file:
  - update content (sections that changed)
  - update frontmatter:
      amended_at: <ISO 8601 timestamp>
      amended_reason: <one-line why>
      revision: 2  (incremented; first amendment = 2)
       │
       ▼
git -C /srv/plans-multica add {plan-filename}.md
git -C /srv/plans-multica commit -m "amend: {plan-slug} — {one-line reason}"
git -C /srv/plans-multica push origin main
       │
       ▼
return to Phase 2 implementation against the revised plan
```

## Plan frontmatter format

Original plan (Phase 1):

```yaml
---
title: Fix issue.status flow rework rev 2
type: feature
agent: agent-1
created_at: 2026-05-08T01:23:45Z
revision: 1
---
```

After first amendment:

```yaml
---
title: Fix issue.status flow rework rev 2
type: feature
agent: agent-1
created_at: 2026-05-08T01:23:45Z
amended_at: 2026-05-08T02:14:11Z
amended_reason: "Discovered issue.status has a CHECK constraint, not an ENUM — DDL approach changed from ALTER TYPE to ALTER TABLE DROP/ADD CONSTRAINT"
revision: 2
---
```

After second amendment (rare):

```yaml
---
amended_at: 2026-05-08T03:01:22Z
amended_reason: "Migration order matters: must drop FK from issues_history before altering issue.status_check"
revision: 3
---
```

The `amended_reason` should be specific enough that a reviewer reading the plan in 6 months understands what changed and why, without re-reading the diff. Aim for one sentence, technical, no apologies.

## What to amend in the body

- **Implementation steps** — update the steps to reflect the revised approach. Strike-through old steps if they were attempted: `~~Step 3: ALTER TYPE issue_status~~` → `Step 3: ALTER TABLE issue DROP/ADD CONSTRAINT issue_status_check`.
- **Open questions** — if the amendment closed an open question, mark it resolved with timestamp.
- **Test plan** — if the test list changed.
- **Distribution / dependencies** — if PR boundaries changed.

Do NOT delete the original content. The point of amendment is to preserve the history of what was thought, then learned.

## Commit message format

```
amend: {plan-slug} — {one-line reason}
```

Examples:
- `amend: 2026-05-06-status-flow-rework — discovered CHECK constraint, switched DDL approach`
- `amend: 2026-05-08-router-coverage-fix — found N+1 in resolver, plan adjusted to add eager load`
- `amend: 2026-05-09-supplier-portfolio-sync — plan misread fds_remote_schema, retargeting to canonical config`

NOT acceptable:
- `amend: fix plan` (no info)
- `amend: oops` (no info)
- `amend: small tweak` (vague)

## Push semantics

Plans-repo `main` allows direct push (it's an audit log, not an implementation branch). The PAT used (`AGENT_PLANS_PAT`) is scoped specifically for this. No PR for plan amendments.

If push fails (e.g., concurrent amendment from a second agent):
1. `git -C /srv/plans-multica fetch origin main`
2. `git -C /srv/plans-multica rebase origin/main` — usually fast-forward since amendments touch different files
3. Retry push
4. If still failing, escalate — there's something wrong with the plans-repo state.

## After amendment

Return to Phase 2 of `/plan-and-implement`. Your worktree branch is unchanged. Continue editing code.

When you reach Phase 3 (`/ship-pr`), the PR description automatically references the latest revision (it reads `revision:` from the plan frontmatter). Reviewers see "Plan was amended at {timestamp}: {reason}" inline.

## When NOT to use this skill

- Cosmetic plan edits (typo, formatting) — just edit + commit normally with `chore:` prefix, no `amend_at` needed.
- Adding test cases that were already implied by the plan's "test plan" section — extend the section, no amendment.
- Phase 1 mistakes you catch BEFORE pushing the plan — just rewrite the plan locally and push the corrected version. Amendment is for AFTER push.

## Why this exists

Outside-voice review (Codex/Claude subagent) on the original A-lite design surfaced this gap: "Plan published → starts implementation → discovers plan was wrong mid-implementation. Now plans-repo has a wrong plan as audit truth, and the PR description contradicts it. No premise covers plan amendment."

This skill is the resolution. The plans-repo audit log stays honest by allowing — and requiring — explicit amendment when reality diverges from the plan.

---
name: ship-pr
description: Use after agent finishes implementation in worktree — opens a PR via gh pr create, links the plan committed via /publish-plan, ensures the PR description points reviewers at the audit log entry. End-of-task wrapper for /plan-and-implement Phase 3.
---

# /ship-pr

Wrapper around `gh pr create` for the multica.ai-native agent flow. Closes the loop on `/plan-and-implement`.

## When to invoke

Phase 3 of `/plan-and-implement`. You have:
- Committed your code on branch `agent-N/<task-slug>` (in `/srv/agent-worktrees/agent-N/`) and pushed.
- Already pushed a plan to plans-repo (`/srv/plans-multica/{date}-...md`). The plan path is your link target in the PR body.

## What it does

```
git rev-parse --abbrev-ref HEAD          → confirm branch is agent-N/* or feature/*
git log origin/main..HEAD --oneline      → list commits for PR title/summary
read /srv/plans-multica/{plan path}      → extract title, problem statement
       │
       ▼
gh pr create --base main \
  --title "<type>: <plan title>" \
  --body "<formatted body — see below>" \
  --assignee "@me"                        # if PAT user is in repo collaborators
       │
       ▼
PR URL printed to stdout
```

## Branch-name guardrail

If current branch is `main`, `master`, `develop`, or any other primary branch, refuse to ship. The agent should never reach this skill from main — `/srv/agent-worktrees/agent-N/` always sits on a per-task branch (created by `scripts/14-agent-host-prep.sh` as `agent-N/scratch`, then renamed by your task).

```bash
branch="$(git rev-parse --abbrev-ref HEAD)"
case "$branch" in
  main|master|develop) echo "ERROR: refusing to ship from $branch" >&2; exit 1 ;;
  agent-*|feature/*) ;;  # ok
  *) echo "WARN: unusual branch name '$branch' — proceeding but verify before merge" >&2 ;;
esac
```

## PR title

Inferred from the plan + commit prefix:

- Plan type `feature` → `feat(<scope>): <one-line summary>`
- Plan type `bugfix` → `fix(<scope>): <one-line summary>`
- Plan type `refactor` → `refactor(<scope>): <one-line summary>`
- Plan type `spike` → `spike(<scope>): <one-line summary>`

Cap at 70 chars. If the plan title is too long, keep the prefix and truncate the summary.

## PR body format

```markdown
## Summary

<One paragraph from the plan's problem statement.>

## Plan

This PR implements [{plan-filename}](https://github.com/{owner}/{plans-repo}/blob/main/{plan-path}).

The plan was published before implementation started (audit log).
{If /amend-plan was invoked: "Plan was amended at {timestamp}: {reason}.
See [revision history]({github-url-to-commits-on-plan-file})."}

## Changes

<Bullet list — one per commit on this branch, excluding the plan publish commit.>
- `<file>`: <what changed>
- `<file>`: <what changed>

## Test plan

- [ ] {test 1 from plan}
- [ ] {test 2 from plan}
- [ ] (if migration touched, see /plan-and-implement open Q) Migration validation strategy

## Agent context

Built by `agent-{N}` running as a multica.ai workspace agent on the host
(`CLAUDE_CONFIG_DIR=/home/multica/.claude/agent-{N}/`,
worktree=`/srv/agent-worktrees/agent-{N}/`). Plan + implementation in one session.
Worktree branch: `{branch}`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Use a HEREDOC for the body to avoid shell quoting issues:

```bash
gh pr create --base main \
  --title "$pr_title" \
  --body "$(cat <<'EOF'
<body content>
EOF
)"
```

## After PR is open

1. Print the PR URL to stdout — multica.ai chat user sees it.
2. Optionally: post a comment on the plan file in plans-repo linking back to this PR (closes the audit loop both ways). Use `gh api` to comment on the plan file commit.
3. Do NOT auto-merge. Human reviews and merges via Forge deploy.

## What this skill does NOT do

- It does NOT run `gh repo create` (denied by `agent-settings.json`).
- It does NOT push to `main` (denied — branch protection on receiving repo + Claude-layer deny).
- It does NOT bump VERSION or write CHANGELOG (those land on merge, by humans or by `notify-shipped.yml`).
- It does NOT run tests (run them in your worktree before invoking this skill).

## Failure modes

| Failure | What to do |
|---|---|
| `gh pr create` returns "branch already has open PR" | use `gh pr edit` to update body instead, print existing URL |
| PAT lacks PR-create permission | likely the wrong PAT in `AGENT_PULSE_PAT` — ask user to regenerate with `pull-requests:write` |
| Branch protection rejects | verify the receiving repo has the right protection rules; do NOT try to bypass — it's the P5 second defense layer |
| Plan file path missing | ensure `/publish-plan` ran first; plan body should reference an existing file in `/srv/plans-multica/` |

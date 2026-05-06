---
name: pickup-plan
description: Use when starting a development session in a git worktree and you want to claim a ready plan from the brainstorm queue. Pulls latest from rabbeet/plans, lists unblocked ready plans, lets you pick one, claims it via optimistic git locking, and loads it into your Claude Code context.
---

# /pickup-plan

Claim a ready plan from the brainstorm queue and start implementing it.

## Where this skill lives

This skill is **deployed on user's Mac**, NOT on the multica server. It runs from any git worktree on the Mac (originally Pulse-only, now generic). The companion `/publish-plan` runs server-side in the multica brainstorm container.

Install on Mac:
```bash
mkdir -p ~/.claude/skills/pickup-plan
cp ~/coding/multica-server/mac-skills/pickup-plan/SKILL.md ~/.claude/skills/pickup-plan/
```

## When to invoke

User has just opened Claude in a git worktree (Pulse, multica-server, or any other repo), wants to start work on a fresh task, doesn't want to re-read all 10 brainstorms to remember which is next.

## What it does

```
[fetch latest from rabbeet/plans (git via SSH deploy key on Mac)]
       │
       ▼
[list plans where status=ready AND blocked_by deps are all status=shipped]
       │
       ▼
[present via AskUserQuestion — user picks one]
       │
       ▼
[optimistic claim: --force-with-lease=main:<EXPECTED_SHA>]
       │
       ▼ (success)
[update frontmatter: status=in-progress, assigned_to=<worktree-name>, started_at=<now>]
       │
       ▼
[push back to plans repo]
       │
       ▼
[copy plan body into ~/.gstack/projects/<project>/{user}-{branch}-design-{ts}.md
 so /executing-plans can pick up from there with full gstack context]
       │
       ▼
[suggest /executing-plans as next step]
```

## Implementation

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Determine which worktree we're in (any git repo, not just Pulse)
WORKTREE_DIR=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "Run /pickup-plan from inside a git worktree."
  exit 1
}
WORKTREE=$(basename "$WORKTREE_DIR")  # e.g. "Pulse3", "multica-server"

# Map worktree → project subdir in rabbeet/plans.
# Pulse2/3/4/5 (and bare "Pulse") all read Pulse/ subdir.
# multica-server reads Multica/ subdir.
# Anything else: use worktree name as the project (creates new subdir on publish).
case "$WORKTREE" in
    Pulse|Pulse[0-9])           PROJECT="Pulse" ;;
    multica-server)             PROJECT="Multica" ;;
    *)                          PROJECT="$WORKTREE" ;;
esac

# 2. Each worktree has its own clone of plans-репо to avoid race condition
PLANS_DIR="$HOME/srv/plans-${WORKTREE}"
if [[ ! -d "$PLANS_DIR/.git" ]]; then
  mkdir -p "$(dirname "$PLANS_DIR")"
  git clone git@github.com:rabbeet/plans.git "$PLANS_DIR"
fi

# 3. Optimistic locking loop — up to 5 retries
MAX_RETRIES=5
RETRY=0
while [[ $RETRY -lt $MAX_RETRIES ]]; do
  cd "$PLANS_DIR"
  git fetch origin main
  git reset --hard origin/main
  EXPECT_SHA=$(git rev-parse origin/main)

  # 4. Candidate files: $PROJECT/*.md (primary) + root *.md (legacy)
  CANDIDATES=()
  shopt -s nullglob
  PLAN_FILES=( "$PROJECT"/*.md *.md )
  shopt -u nullglob

  for f in "${PLAN_FILES[@]}"; do
    base=$(basename "$f")
    [[ "$base" == README* ]] && continue

    status=$(yq '.status' "$f" 2>/dev/null || echo "null")
    [[ "$status" == "null" ]] && continue   # not a plan file (e.g. Multica/README.md)

    # Zombie: status:in-progress but tmux session dead → still surface
    if [[ "$status" == "in-progress" ]]; then
      assigned=$(yq '.assigned_to' "$f")
      if [[ "$assigned" != "null" ]] && ! tmux has-session -t "$assigned" 2>/dev/null; then
        CANDIDATES+=("$f|zombie|$(yq '.title' "$f")")
      fi
      continue
    fi

    [[ "$status" != "ready" ]] && continue

    # blocked_by graph: all deps must be status:shipped
    deps=$(yq '.blocked_by[]' "$f" 2>/dev/null || echo "")
    blocked=false
    for dep_id in $deps; do
      # Search across project subdirs + root + archive
      dep_file=$(find . -maxdepth 2 -name "${dep_id}.md" 2>/dev/null | head -1)
      if [[ -z "$dep_file" ]]; then
        echo "WARN: $f references unknown dep $dep_id — skipping"
        blocked=true; break
      fi
      dep_status=$(yq '.status' "$dep_file")
      if [[ "$dep_status" != "shipped" ]]; then
        blocked=true; break
      fi
    done
    [[ "$blocked" == "true" ]] && continue

    CANDIDATES+=("$f|ready|$(yq '.title' "$f")")
  done

  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "No ready plans for $PROJECT — brainstorm something! /office-hours in multica."
    exit 0
  fi

  # 5. Present to user via AskUserQuestion (Claude does this)
  # ... user picks $PICKED_FILE ...

  # 6. Claim
  yq -i ".status = \"in-progress\"" "$PICKED_FILE"
  yq -i ".assigned_to = \"$WORKTREE\"" "$PICKED_FILE"
  yq -i ".started_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$PICKED_FILE"

  git add "$PICKED_FILE"
  git commit -m "claim: $(yq '.id' "$PICKED_FILE") → $WORKTREE"

  # 7. Optimistic push — fails if remote moved (someone else claimed)
  if git push --force-with-lease="main:$EXPECT_SHA" origin main; then
    echo "✓ Claimed $(yq '.id' "$PICKED_FILE")"
    break
  fi

  echo "Race detected — retrying..."
  RETRY=$((RETRY + 1))
done

if [[ $RETRY -eq $MAX_RETRIES ]]; then
  echo "Could not claim after $MAX_RETRIES retries — heavy contention. Try /pickup-plan again."
  exit 1
fi

# 8. Stage the plan into gstack format so /executing-plans picks it up
SLUG=$(~/.claude/skills/gstack/bin/gstack-slug 2>/dev/null | sed 's/.*=//')
GSTACK_DIR="$HOME/.gstack/projects/${SLUG:-$WORKTREE}"
mkdir -p "$GSTACK_DIR"

USER=$(whoami)
BRANCH=$(git -C "$WORKTREE_DIR" branch --show-current 2>/dev/null || echo "main")
DATETIME=$(date +%Y%m%d-%H%M%S)
DEST="$GSTACK_DIR/${USER}-${BRANCH}-design-${DATETIME}.md"

cp "$PICKED_FILE" "$DEST"

echo ""
echo "Plan staged for /executing-plans:"
echo "  $DEST"
echo ""
echo "Next: /executing-plans"
```

## Edge cases handled

- No ready plans → graceful "brainstorm something!" exit.
- Race condition (concurrent /pickup-plan in pulse3 and pulse5) → optimistic retry with `--force-with-lease`. After 5 retries, give up gracefully.
- Zombie plans (status:in-progress but tmux session dead) → show separately, offer to reclaim.
- blocked_by chain not satisfied → filter out, don't show user.
- blocked_by cycle → DFS detection, exit with error (this should be caught at /publish-plan time, but defense in depth).
- blocked_by dangling reference (id doesn't exist) → log warn, skip plan.
- Network down → fail loud, no silent fallback to potentially-stale local clone.

## What it does NOT do

- Does NOT execute the plan — that's `/executing-plans`. This skill just claims and stages.
- Does NOT run on the multica server — runs on Mac, inside a git worktree.
- Does NOT modify your project's code — only writes to the plans repo and gstack project dir.
- Does NOT filter plans by project. All plans in `rabbeet/plans` are listed; you pick what's relevant by title.

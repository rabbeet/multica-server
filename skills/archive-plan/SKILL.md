---
name: archive-plan
description: Use when a published plan is no longer relevant (idea died, superseded by another plan, or completed but you want it out of the active list). Soft-deletes by moving to plans/archive/ with status:abandoned, preserving git history.
---

# /archive-plan

Soft-delete a plan — move from active list to `archive/` directory with explicit `status: abandoned` (or `superseded`).

## When to invoke

Three reasons to archive:
1. Idea didn't survive the test of time (a week passed, no longer interesting).
2. A new plan supersedes the old one (different approach, same problem).
3. Plan was shipped manually outside the workflow and you want to clean up the queue.

Note: "shipped via the workflow" doesn't need archiving — `/ship` writes `status: shipped` and the plan stays as historical record.

## Step-by-step

1. **Pre-flight:** `cd /srv/plans-multica && git fetch origin main && git reset --hard origin/main`.

2. **List candidates:** all `.md` in plans-repo root with `status: ready` or `status: in-progress`. Use yq:
   ```bash
   for f in /srv/plans-multica/*.md; do
     [[ "$f" == */templates/* ]] && continue
     [[ "$f" == */archive/* ]] && continue
     status=$(yq '.status' "$f")
     case "$status" in
       ready|in-progress)
         title=$(yq '.title // .id' "$f")
         echo "$f|$status|$title"
         ;;
     esac
   done
   ```

3. **Ask user via AskUserQuestion:** "Which plan to archive?" — list candidates with title + status.

4. **Ask for reason via AskUserQuestion:**
   - A) abandoned — idea died, no longer pursuing
   - B) superseded — replaced by a newer plan; ask for `superseded_by` plan ID
   - C) duplicate — already exists elsewhere

5. **Move + update frontmatter:**
   ```bash
   PLAN_ID=$(yq '.id' "$PLAN_FILE")
   ARCHIVE_FILE="/srv/plans-multica/archive/${PLAN_ID}.md"
   mkdir -p /srv/plans-multica/archive

   # Update frontmatter via yq (preserves body)
   yq -i ".status = \"$REASON\"" "$PLAN_FILE"
   yq -i ".archived_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$PLAN_FILE"
   [[ "$REASON" == "superseded" ]] && yq -i ".superseded_by = \"$NEW_PLAN_ID\"" "$PLAN_FILE"

   git mv "$PLAN_FILE" "$ARCHIVE_FILE"
   ```

6. **Commit + push:**
   ```bash
   git add -A "$ARCHIVE_FILE" "$(dirname $PLAN_FILE)"
   git commit -m "archive($REASON): $PLAN_ID"
   git push origin main || {
     echo "Push failed. Plan moved locally; recovery: cd /srv/plans-multica && git push"
     exit 1
   }
   ```

7. **Confirm:**
   ```
   ✓ Archived: $PLAN_ID
   Reason:     $REASON
   Location:   /srv/plans-multica/archive/$PLAN_ID.md
   ```

## Edge cases

- Plan in `status: shipped` → block with "Don't archive shipped plans, they're history. Use git rm if you really need to."
- Plan with `assigned_to` set (someone is working on it) → confirm twice. Risk of stomping their work.
- Empty plans list → "Nothing to archive — all plans are shipped or already archived."
- Push fail → explicit recovery instructions; never silently leave inconsistent state.

## What it does NOT do

- Does not git rm — file stays in repo (just under archive/) so git log preserves history.
- Does not Telegram-notify (archives are not events worth pinging).
- Does not auto-archive based on age — that's the deferred stale-plan watchdog (TODO).

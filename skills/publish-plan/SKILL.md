---
name: publish-plan
description: Use when finalizing a brainstorm session into a plan that's ready for someone to pick up. Reads the latest design doc from gstack output, prompts for plan type (feature/bugfix/refactor/spike), wraps it in the matching template, commits to /srv/plans-multica, and pushes to the plans repo.
---

# /publish-plan

Publish a brainstorm output as a plan that the dev side (Mac, Pulse worktrees) can pick up via `/pickup-plan`.

## When to invoke

After running `/office-hours` or another design skill that produced a design doc in `~/.gstack/projects/$SLUG/`. The user is in the multica brainstorm container, on phone or laptop, and wants to "ship the idea downstream."

If invoked without a fresh design doc, the skill detects this and either prompts for one or fails gracefully.

## What it does

```
~/.gstack/projects/{slug}/{user}-{branch}-design-{ts}.md
       │
       ▼
[publish-plan reads latest design doc]
       │
       ▼
[user picks template: feature | bugfix | refactor | spike]
       │
       ▼
[merge template + extracted metadata + design content]
       │
       ▼
/srv/plans-multica/2026-05-05-multica-server-{slug}.md
       │
       ▼
[git add + commit + push (HTTPS+PAT)]
       │
       ▼
GitHub: rabbeet/plans main updated
       │
       ▼
[GH Action: deploy-cf-pages → dashboard refresh]
```

## Step-by-step

1. **Pre-flight:**
   ```bash
   cd /srv/plans-multica
   git fetch origin main
   git reset --hard origin/main
   ```
   (clean state, otherwise abort with clear error)

2. **Find latest design doc:**
   ```bash
   eval "$(~/.claude/skills/gstack/bin/gstack-slug 2>/dev/null)" || SLUG="unknown"
   DESIGN=$(ls -t ~/.gstack/projects/$SLUG/*-design-*.md 2>/dev/null | head -1)
   ```
   If empty → tell user "No design doc to publish — run /office-hours first." Exit clean.

3. **Determine target project subdir** from `$SLUG`:
   ```bash
   case "$SLUG" in
       rabbeet-Pulse*|clickavia-Pulse|clickavia-Pulse-*) PROJECT="Pulse" ;;
       rabbeet-multica-server)                            PROJECT="Multica" ;;
       rabbeet-agent-context)                             PROJECT="Multica" ;;
       *)                                                 PROJECT="" ;;
   esac
   ```
   If `$PROJECT` is empty → ask user via AskUserQuestion: "Which project does this plan belong to?" Options: existing subdirs in `/srv/plans-multica/` (excluding `templates/`, `archive/`) + "Other (type name)". Whatever they pick becomes `$PROJECT`. If "Other", create `/srv/plans-multica/<name>/` on the fly.

4. **Ask user via AskUserQuestion:** "What type is this plan?"
   - A) feature — full design with alternatives + recommended approach
   - B) bugfix — incident-style: симптом → root cause → fix → regression test
   - C) refactor — scope, motivation, before/after, migration plan
   - D) spike — exploration, success criteria, time budget

5. **Read template** at `/srv/plans-multica/templates/{type}.md`. If template missing, fall back to `feature.md` and warn.

6. **Generate plan path** under the project subdir:
   ```bash
   PLAN_ID=$(date +%Y-%m-%d)-$(echo "$DESIGN" | sed 's/.*design-//; s/\.md$//' | tr -cd 'a-z0-9-')
   mkdir -p "/srv/plans-multica/${PROJECT}"
   PLAN_FILE="/srv/plans-multica/${PROJECT}/${PLAN_ID}.md"
   ```

7. **Build frontmatter via yq** (NOT sed — handles multiline, quotes correctly):
   ```yaml
   ---
   id: <PLAN_ID>
   project: <PROJECT>
   title: <extract from design doc # heading>
   type: feature|bugfix|refactor|spike
   status: ready
   created_by: multica
   created_at: 2026-05-05T15:30:00Z
   started_at: null
   shipped_at: null
   assigned_to: null
   blocked_by: []
   related_pr: null
   source_design_doc: <basename of $DESIGN>
   ---
   ```

8. **Concatenate template body + design content:** template provides section headers; design fills them. If sections don't match, append design as-is under "## Design notes" so nothing is lost.

9. **Commit + push:**
   ```bash
   cd /srv/plans-multica
   git add "$PLAN_FILE"
   git commit -m "publish: ${PROJECT}/${PLAN_ID}

   Project: $PROJECT
   Type:    $TYPE
   Source:  $(basename $DESIGN)"

   # Retry once if push fails
   if ! git push origin main; then
     git pull --rebase origin main
     git push origin main || {
       echo "Push failed twice. Plan saved locally at $PLAN_FILE"
       echo "Recovery: cd /srv/plans-multica && git push origin main"
       exit 1
     }
   fi
   ```

10. **Optional cascade enroll (PUL-198 Part 2):** if the design doc's
    frontmatter contains a multica issue identifier or UUID — typically
    `multica_issue: PUL-N`, `multica_issue_id: <uuid>`, or both — the
    skill MAY enroll that issue's cascade against the freshly-published
    plan URL. This is what stops single-PR-style spawn skipping on a
    multi-PR cascade: after enroll, the next `pr_merged` event on that
    issue passes the worker's spawn gate.

    Read the frontmatter:
    ```bash
    ISSUE_ID=$(yq -r '.multica_issue_id // .multica_issue // empty' "$PLAN_FILE")
    ```
    If `$ISSUE_ID` is empty → silently skip (architecture / no-ticket plans
    have no issue to enroll).

    Otherwise ask the user via **AskUserQuestion** (default N — this
    is a behaviour-changing action on the issue):

    > Enroll issue `${ISSUE_ID}` in cascade against this plan? Setting
    > `cascade_plan_url=https://github.com/rabbeet/plans/blob/main/${PROJECT}/${PLAN_ID}.md`
    > makes the cascade worker wake the assigned agent on each future
    > `pr_merged` for this issue.
    >   - **N** (default) — skip. Plan is published; issue's cascade
    >     behaviour is unchanged.
    >   - **Y** — call `multica issue update --cascade-plan-url <url>`
    >     and report the result in the final summary.

    On Y, run:
    ```bash
    PLAN_URL="https://github.com/rabbeet/plans/blob/main/${PROJECT}/${PLAN_ID}.md"
    multica issue update "${ISSUE_ID}" --cascade-plan-url "${PLAN_URL}" --output json \
        | jq -r '.cascade_plan_url' > /tmp/enroll.out 2>&1
    ```
    Surface success in the final summary; on failure (exit non-zero or
    empty cascade_plan_url) report the error but do NOT roll back the
    plan push — the plan is still useful even if enroll failed.

11. **Tell user:**
    ```
    ✓ Published: ${PROJECT}/${PLAN_ID}
    File:       $PLAN_FILE
    Status:     ready
    Cascade:    enrolled (cascade_plan_url=<URL>)   ← only if step 10 enrolled
    Pickup:     run /pickup-plan in your ~/coding/<project> worktree on Mac
    ```

## Edge cases handled

- No design doc → graceful exit, suggest /office-hours.
- Multiple design docs same branch → pick latest by mtime; tell user which one.
- Template missing → fall back to feature.md, warn.
- Network down on push → retry once with rebase, save locally if both fail with explicit recovery cmd.
- Plan ID collision (someone else just published the same slug) → append `-2`, `-3` and retry.
- yq not installed → fail loud with install instructions; do NOT fall back to sed (which would corrupt YAML).
- Cascade enroll (step 10) — issue lookup fails or returns non-zero → surface the error but never block the plan push; the plan is already useful as a published artifact. The user can rerun `multica issue update --cascade-plan-url <url>` manually.
- Cascade enroll on an issue that was already enrolled → `multica issue update` simply overwrites cascade_plan_url; no special handling.

## What it does NOT do

- Does not run /office-hours itself — user must have done that already.
- Does not modify or delete the source design doc — that stays in ~/.gstack/.
- Does not pickup or claim — that's `/pickup-plan` on the Mac side.
- Does not Telegram-notify on publish (notifications fire on `status: shipped`, not `ready`).

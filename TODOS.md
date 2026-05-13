# TODOS — multica-server

Tracked from `/plan-ceo-review` 2026-05-08 (host-process A-lite, multica.ai-native).

---

## P1: Branch protection rules audit (CRITICAL — blocks agent rollout)

**What:** Verify branch protection rules on `rabbeet/Pulse` `main` and `multica-ai/multica` (or `rabbeet/multica` fork) `main` before issuing fine-grained PATs to agents.

**Why:** P5 defense-in-depth (no Forge/deploy access from agent) leans on three layers — branch protection is the first. If `main` allows direct push or admin override is too liberal, an agent's PAT could push directly to `main` despite intent.

**Required rules per repo:**
- Require pull request reviews before merging (≥1 approval)
- Require status checks to pass (CI green)
- Restrict who can push to matching branches (only specific accounts, NOT the agent PAT user)
- Disable force pushes
- No administrators bypass

**Effort:** Human ~10 min (manual GitHub UI work).
**Priority:** P1 — blocks agent rollout into production use.
**Blocks:** Issuing `AGENT_PULSE_PAT` and `AGENT_MULTICA_PAT` for actual ship-to-prod work. Hard prereq for PUL-94 Phase 5 prod rollout (see `plans://Multica/2026-05-12-pul-94-agent-worktree-per-task.md`).

---

## P3: Verify Claude OAuth token TTL

**What:** Determine exact TTL of Claude OAuth tokens so per-agent re-auth alerting can be calibrated.

**Why:** When the agent host has 2-3 agents each with their own OAuth state, token expiry on one of them silently breaks that agent's spawning. We need to alert before the user notices via failed task. Telemetry on first natural expiry will reveal real TTL.

**How:** Check Anthropic docs (`https://code.claude.com/docs/en/overview`) or read multica.ai source for token refresh logic.

**Effort:** Human ~15 min.
**Priority:** P3 — nice to have. First natural OAuth failure reveals TTL anyway.
**Blocks:** Nothing.

---

## P0.5: Verify `author_type='system'` exists in multica-ai/multica schema (BLOCKS PUL-13 P1)

**What:** Before starting PUL-13 P1 (auto round-trip status flips), verify whether `issue_comments.author_type` already accepts `'system'` value in multica-ai/multica schema.

**Why:** PUL-13 P1 design (rabbeeet-feat-agent-multica-native-design-20260508-190000.md) assumes three actor types: `member | agent | system`. The `decideFlip` function has a defensive guard: if `author_type='system'` → null. If `system` is not yet a valid value AND no system actors exist in practice, the guard is dead code (safe). If `system` is needed but not yet supported, that's a separate prerequisite PR (P0.5) before P1 ships.

**How:** Open `/Users/rabbeeet/coding/multica-pul-13-status-flow-p0/multica`. Grep for `author_type` definition (likely in a migration or model). Check whether `'system'` is in the allowed values. Decide:
- Already supported → ✓, P1 can proceed
- Not supported, no system actors exist → ✓, P1 can proceed (defensive guard is dead code)
- Not supported, system actors needed (CI bots etc) → P0.5 separate PR before P1

**Effort:** Human ~5 min (single grep + decision).
**Priority:** P0.5 — blocks PUL-13 P1.
**Blocks:** PUL-13 P1 implementation.

---

## P2: Notification on auto-flip → waiting (PUL-13 P1.5 follow-up)

**What:** When server auto-flips a ticket from `in_progress → waiting`, notify the ticket owner that "your turn" has arrived. Push notification, email, or other channel.

**Why:** PUL-13 P1 makes the board reflect "whose turn is it" via column placement (waiting = to-reply list). Without notification, the user has to actively check the board to know they have a new ticket to attend to. Notification closes the loop and makes the workflow truly hands-off for agents while ensuring humans don't miss handoffs.

**Pros:** Real-time signal "agent finished, your turn." Eliminates need to refresh the board. Reduces latency between agent's response and human pickup.

**Cons:** Notification stack is its own domain (channel selection, template, delivery semantics, opt-out). Doesn't block P1 functionality — board placement already gives the visual signal.

**Context:** Should reuse existing notification infrastructure in multica.ai (if any). If none exists, this is a larger build that includes notification architecture itself. Worth investigating BEFORE designing — don't build a notification system from scratch for one event type.

**Depends on:** PUL-13 P1 shipped. Existing notification infrastructure in multica.ai (verify).

**Effort:** Human ~1 day if notification stack exists / 3-5 days if needs building from scratch.
**Priority:** P2 — improves UX significantly but P1 functionality stands without it.
**Blocks:** Nothing.

---

## P2: Prometheus exporter for daemon `worktree.*` slog events (post-PUL-94)

**What:** After PUL-94 ships, build a Prometheus exporter (or Loki/Promtail pipeline) that turns the daemon's `worktree.spawn_*`, `worktree.remove`, `worktree.sweeper_run`, `worktree.legacy_fallback` slog events into time-series metrics.

**Why:** PUL-94 currently emits structured slog events but no aggregator → no alerts. Want to alert on: `sweeper_run` not happening for 48h, `spawn_failed` rate > 1/h, disk usage > 60% of `/srv`, legacy_fallback count not reaching 0 during sunset. Without an aggregator, ops has to grep `~/.multica/daemon.log` manually — works for rollout week, doesn't scale.

**Pros:** Continuous visibility, runtime alerts, graphable migration progress (legacy_path → 0). Promotes existing slog kv into proper metrics without changing emission code.

**Cons:** Adds Prometheus to the stack — currently absent. Needs Grafana or similar for visualization. Operational overhead.

**Context:** Approach B for PUL-94 (CEO review 2026-05-13) explicitly deferred Prometheus because there's no aggregator yet. This TODO captures the deferred work. When picking up: choose between (a) `prometheus/client_golang` exporter in daemon + scraper, or (b) Loki/Promtail parsing slog JSON. Latter is lighter and reuses log shipping if it exists.

**Depends on / blocked by:** PUL-94 shipped + sunset complete (so `legacy_path` metric isn't useless).

**Effort:** Human ~1 day / CC ~1-2 h.
**Priority:** P2.

---

## P2: Cross-agent filesystem isolation (post-PUL-94, security)

**What:** Run each agent worker under a distinct Unix UID with its worktree dir chowned to that UID. Today all agents run as user `multica` with `/srv/agent-worktrees/` at chmod 750 — `agent-1` can read `agent-2`'s files.

**Why:** Single-tenant solo-dev: low concern. But PUL-94 introduces multi-repo: an agent assigned to Pulse can read `/srv/multica-bare.git` worktrees, and vice versa. If a different agent gets a more constrained PAT later, the FS layer should match the credential boundary, not undercut it.

**Pros:** Defense-in-depth. Aligns FS perms with credential scope. Limits blast radius of a single agent's compromise.

**Cons:** Bigger change than it looks — needs separate UIDs, per-agent ReadWritePaths drop-ins instead of one shared, per-agent `CLAUDE_CONFIG_DIR` ownership. May break the current `sudo -u multica` patterns in `scripts/14`.

**Context:** Identified during PUL-94 eng review 2026-05-13. Not blocking PUL-94 rollout (current shared-UID model preserves status quo). Worth doing when there's a real multi-tenant or shared-agent-host scenario.

**Depends on:** PUL-94 shipped (settles the per-task vs per-agent worktree shape first).

**Effort:** Human ~1 week / CC ~2-3 h.
**Priority:** P2.

---

*Append future TODOs above this line.*

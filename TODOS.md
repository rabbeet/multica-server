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
**Blocks:** Issuing `AGENT_PULSE_PAT` and `AGENT_MULTICA_PAT` for actual ship-to-prod work.

---

## P3: Verify Claude OAuth token TTL

**What:** Determine exact TTL of Claude OAuth tokens so per-agent re-auth alerting can be calibrated.

**Why:** When the agent host has 2-3 agents each with their own OAuth state, token expiry on one of them silently breaks that agent's spawning. We need to alert before the user notices via failed task. Telemetry on first natural expiry will reveal real TTL.

**How:** Check Anthropic docs (`https://code.claude.com/docs/en/overview`) or read multica.ai source for token refresh logic.

**Effort:** Human ~15 min.
**Priority:** P3 — nice to have. First natural OAuth failure reveals TTL anyway.
**Blocks:** Nothing.

---

*Append future TODOs above this line.*

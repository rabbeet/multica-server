# TODOS — multica-server

Tracked from `/plan-ceo-review` 2026-05-08 on design `rabbeeet-main-design-20260507-224221.md` (multica multi-worker pivot, A-lite).

---

## P1: Branch protection rules audit (CRITICAL — blocks Step 2)

**What:** Verify branch protection rules on `rabbeet/Pulse` `main` and `multica-ai/multica` `main` before issuing fine-grained PATs to agent containers.

**Why:** P5 defense-in-depth (no Forge/deploy access from agent) leans on three layers — branch protection is the first. If `main` allows direct push or admin override is too liberal, an agent's PAT could push directly to `main` despite intent.

**Required rules per repo:**
- Require pull request reviews before merging (≥1 approval)
- Require status checks to pass (CI green)
- Restrict who can push to matching branches (only specific accounts, not the agent PAT)
- Disable force pushes
- No administrators bypass

**Effort:** Human ~10 min / CC N/A (manual GitHub UI work).
**Priority:** P1 — blocks Step 2 (worker rollout).
**Blocks:** Issuing `AGENT_PULSE_PAT` and `AGENT_MULTICA_PAT`.

---

## P1: Settings.json deny list extension inside agent container

**What:** Extend `config/claude/settings.json` deny list to include `git remote add`, `git remote set-url`, `gh repo create`, `gh repo clone <not-allowed-repo>`.

**Why:** Outside-voice review surfaced prompt-injection vector — malicious string in a Pulse PR description, agent-context dump, or read-only file could try to get the agent to push code to an attacker-controlled repo. Tinyproxy egress allowlist mitigates exfiltration to non-allowed hosts but explicit Claude-level deny is cheaper second layer.

**Effort:** Human ~5 min / CC ~2 min (5-line addition to settings.json).
**Priority:** P1 — ship as part of Step 2 (worker rollout).
**Blocks:** Nothing critical, but should ship with first agent.

---

## P3: Verify Claude OAuth token TTL

**What:** Determine exact TTL of Claude OAuth tokens (design currently estimates ~30 days, marked TBD).

**Why:** Health check + Telegram alert system (§9) needs to set re-auth alert threshold (e.g., alert at TTL-3-days). Knowing actual TTL informs whether 15-min healthcheck cadence is appropriate or could be lower-frequency.

**How:** Check Anthropic docs (`https://code.claude.com/docs/en/overview`) or read multica.ai source for token refresh logic.

**Effort:** Human ~15 min / CC ~5 min.
**Priority:** P3 — nice to have. Telegram alert on first failure will reveal real TTL anyway.
**Blocks:** Nothing.

---

*Append future TODOs above this line.*

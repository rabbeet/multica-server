# multica-server CI/CD pipeline

This document describes the CI pipeline being ported into `rabbeet/multica-server`
from `rabbeet/Pulse` under PUL-235 (multica-server side, S1-S4).

## Status (2026-05-23)

- **Phase**: S1 landed (this PR). Telegram composite + smoke-claude-action +
  `ci.yml` (shellcheck/shfmt/actionlint/yamllint) + this doc.
- **Next**: S2 (code-review + code-review-fix), S3 (auto-shfmt + auto-merge),
  S4 (pr-test-autofix + ci-autofix, scoped to shell-lint failures).
- **NOT planned**: release-watchdog (S5) — multica-server has no release
  pipeline (it's an infra/bootstrap repo, no tags published).
- **Follow-up**: PUL-236 extracts duplicated workflows from Pulse + multica
  + multica-server into reusable workflows (`workflow_call`) hosted in
  `rabbeet/Pulse`, reducing these repos to thin caller stubs.

See the design doc at
[`rabbeet/plans:Multica/2026-05-23-pul-235-pulse-pipeline-port-to-multica.md`](https://github.com/rabbeet/plans/blob/main/Multica/2026-05-23-pul-235-pulse-pipeline-port-to-multica.md)
for the full rollout plan + Approach C rationale.

## Architecture overview

After all S-PRs land, agent PRs against `rabbeet/multica-server` flow through
this cascade (mirrors multica's M1-M5 cascade):

```
PR opened (agent-* branch)
    │
    ├─► auto-shfmt           (formats shell on agent-* branches — S3)
    │       │
    │       └─► push triggers CI re-run
    │
    ├─► CI                   (shellcheck + shfmt + actionlint + yamllint — this PR)
    │       │
    │       ├─► [green]   code-review        (Claude posts verdict + labels — S2)
    │       │             ├─► [claude-approved]     auto-merge-on-approval (S3)
    │       │             ├─► [claude-fix-needed]   code-review-fix       (S2)
    │       │             └─► [needs-human-review]  STOP, human required
    │       │
    │       └─► [red]     pr-test-autofix    (Claude fixes shell-lint failures — S4)
    │
    └─► (after merge to main)
            │
            └─► [main CI red]     ci-autofix          (S4, opens follow-up PR)
```

multica-server has no app test layer. The "pr-test-autofix" in S4 fixes
shellcheck/shfmt/actionlint/yamllint failures only — pipeline scaffolding for
when an app test layer is eventually added.

## Required secrets

Provision in `rabbeet/multica-server` Settings → Secrets and variables →
Actions. **Phase 0 prerequisite** — must be set before S2-S4 land.

| Secret | Used by | Source |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | code-review, code-review-fix, ci-autofix, pr-test-autofix | `op://Pulse-Dev/Pulse-env/CLAUDE_CODE_OAUTH_TOKEN` |
| `AGENT_PULSE_PAT` | auto-shfmt, auto-merge-on-approval, code-review-fix, ci-autofix, pr-test-autofix | `op://Pulse-Dev/Pulse-env/AGENT_PULSE_PAT` (same PAT shared across Pulse + multica + multica-server) |
| `TELEGRAM_BOT_TOKEN` | code-review, ci-autofix, pr-test-autofix | `op://Pulse-Dev/Pulse-env/TELEGRAM_BOT_TOKEN` |
| `TELEGRAM_CHAT_ID` | (same as above) | `op://Pulse-Dev/Pulse-env/TELEGRAM_CHAT_ID` |

One-liner (from a machine with 1Password CLI + `gh` auth):

```bash
for K in CLAUDE_CODE_OAUTH_TOKEN AGENT_PULSE_PAT TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
  gh secret set --repo rabbeet/multica-server "$K" --body "$(op read "op://Pulse-Dev/Pulse-env/$K")"
done
```

## CI workflow tooling notes

- **shellcheck**: pre-installed on ubuntu-latest runners. Lints all `*.sh`
  under `scripts/` and `agent/hooks/`. Default ruleset (no per-file
  disables).
- **shfmt**: installed on demand if not pre-installed. Settings: `-i 4`
  (4-space indent), `-bn` (binary ops at line start), `-s` (simplify).
  Runs in `--diff` mode — fails on drift, does NOT modify in place.
  auto-shfmt (S3) handles the format-and-commit cycle separately.
- **actionlint**: downloaded from upstream (rhysd/actionlint) pinned to
  1.7.7. Apt version is too old. Lints all of `.github/workflows/` +
  `.github/actions/`.
- **yamllint**: pre-installed via pip; falls back to `pip install --user`
  if not present. Loose config — line-length 200, document-start disabled.

## Bypass labels (S2-S4 will recognize)

Same semantics as multica side:

| Label | Effect |
|---|---|
| `claude-approved` | Auto-merge on CI green (S3). |
| `claude-fix-needed` | Triggers code-review-fix (S2). |
| `needs-human-review` | All autofix workflows skip. |
| `fix-round-N` | Round counter; round 4 → `needs-human-review`. |
| `pr-test-autofix-disabled` | Per-PR escape hatch for S4. |
| `ci-autofix` (PR label) | Identifies ci-autofix-generated PR; loop guard. |

## Manual escape hatches (S2-S4)

- `[ci-autofix]` in commit msg → ci-autofix skips itself.
- `[auto-review-fix]` in commit msg → code-review-fix skips re-triggering.
- `[auto-test-fix]` in commit msg → pr-test-autofix skips re-triggering.
- `[skip ci]` in commit msg → CI workflow skips.
- Repo variable `ENABLE_PR_TEST_AUTOFIX=false` → kills pr-test-autofix.

## Approach choice + follow-up

Same rationale as multica side: lift-and-shift now (Approach C from
office-hours premise challenge), reusable-workflow extraction in PUL-236
later. PUL-235 design Q9 = `@v1` immutable tag; Q10 = per-repo prompt
files — both decisions pre-committed to feed PUL-236's design phase.

## References

- Design doc: [`rabbeet/plans:Multica/2026-05-23-pul-235-pulse-pipeline-port-to-multica.md`](https://github.com/rabbeet/plans/blob/main/Multica/2026-05-23-pul-235-pulse-pipeline-port-to-multica.md)
- Originating issue: [PUL-235](https://multica.ai/issues/PUL-235)
- Sibling: multica side `docs/CI.md` (covers M1-M5 cascade)
- Source pipeline: `rabbeet/Pulse/.github/workflows/` (11 workflows, 2436 LOC pre-refactor)

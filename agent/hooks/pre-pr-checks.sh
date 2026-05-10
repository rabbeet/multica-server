#!/usr/bin/env bash
# pre-pr-checks.sh — PreToolUse hook gating `gh pr create` on static checks.
#
# Wired in via agent/agent-settings.json (hooks.PreToolUse, matcher=Bash).
# Stdin: JSON tool-call payload from Claude Code.
# Exit 0 = allow (or no-op); exit 2 = block (stderr surfaces to the agent).
#
# Stage 1 scope: pint + npm lint/format/types. Pest gated separately (Stage 2)
# once a stable test DB is wired for the agent host.
#
# Escape hatch: SKIP_PR_CHECKS=1 in the agent's env.

set -uo pipefail

input="$(cat)"
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
cmd=$(printf '%s' "$input"  | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
cwd=$(printf '%s' "$input"  | jq -r '.cwd // empty' 2>/dev/null || echo "")
[ -z "$cwd" ] && cwd="$PWD"

# Pass-through for everything that's not `gh pr create`.
if [ "$tool" != "Bash" ]; then exit 0; fi
case "$cmd" in
    "gh pr create"*|*" gh pr create"*|*"&& gh pr create"*|*"; gh pr create"*) ;;
    *) exit 0 ;;
esac

# Escape hatch for genuine WIP/draft pushes (CI still gates).
if [ "${SKIP_PR_CHECKS:-0}" = "1" ]; then
    echo "[pre-pr-checks] SKIP_PR_CHECKS=1 — bypassing local checks (CI will still run)" >&2
    exit 0
fi

# Skip non-PHP worktrees (brainstorm, plans-multica, etc.).
if [ ! -f "$cwd/composer.json" ]; then
    exit 0
fi

cd "$cwd" || { echo "[pre-pr-checks] cannot cd to $cwd" >&2; exit 1; }

fail() {
    echo "" >&2
    echo "[pre-pr-checks] BLOCKED — $1 failed (see output above)." >&2
    echo "[pre-pr-checks] Fix the failures, or set SKIP_PR_CHECKS=1 to bypass" >&2
    echo "[pre-pr-checks] (only for genuine WIP drafts — CI will still gate)." >&2
    exit 2
}

# Idempotent dep install — first run will be slow, subsequent runs are no-ops.
if [ ! -f vendor/autoload.php ]; then
    echo "[pre-pr-checks] composer install (vendor/ missing)..." >&2
    composer install --no-interaction --prefer-dist --no-progress --no-scripts >&2 \
        || fail "composer install"
fi
if [ ! -d node_modules ]; then
    echo "[pre-pr-checks] npm ci (node_modules missing)..." >&2
    npm ci --no-audit --no-fund >&2 || fail "npm ci"
fi

echo "[pre-pr-checks] running static checks before PR..." >&2

echo "[pre-pr-checks]   -> vendor/bin/pint --test" >&2
vendor/bin/pint --test >&2 || fail "pint --test"

echo "[pre-pr-checks]   -> npm run lint:check" >&2
npm run --silent lint:check >&2 || fail "npm lint:check"

echo "[pre-pr-checks]   -> npm run format:check" >&2
npm run --silent format:check >&2 || fail "npm format:check"

echo "[pre-pr-checks]   -> npm run types:check" >&2
npm run --silent types:check >&2 || fail "npm types:check"

echo "[pre-pr-checks] OK — static checks passed, allowing gh pr create" >&2
exit 0

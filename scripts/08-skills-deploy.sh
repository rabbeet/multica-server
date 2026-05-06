#!/usr/bin/env bash
# 08-skills-deploy.sh — deploy our /publish-plan and /archive-plan skills
# into ~multica/.claude/skills/ so the brainstorm Claude (spawned by multica
# daemon as user multica) can use them.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_root
require_env

USERNAME="${MULTICA_USER:-multica}"
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
SKILLS_DEST="$USER_HOME/.claude/skills"
SKILLS_SRC="$(repo_root)/skills"

# ---- Ensure dest dir exists with right ownership ----
mkdir -p "$SKILLS_DEST"
chown -R "$USERNAME":"$USERNAME" "$USER_HOME/.claude"

# ---- Validate source ----
if [[ ! -d "$SKILLS_SRC" ]]; then
    log_error "skills/ source dir not found: $SKILLS_SRC"
    exit 1
fi

# ---- rsync — additive only (NO --delete) ----
# Earlier version used --delete which wiped third-party skills the user had
# installed independently (gstack, etc). We now only add/update our own
# skills and leave everything else alone. Removing one of our own skills
# from the repo means it stays on the host until the user wipes it manually.
log_info "Syncing skills $SKILLS_SRC -> $SKILLS_DEST (additive)..."
rsync -a \
    --chown="$USERNAME":"$USERNAME" \
    "$SKILLS_SRC/" "$SKILLS_DEST/"

# ---- Deploy claude settings (deny rules) — host filesystem version ----
SETTINGS_SRC="$(repo_root)/config/claude/settings.json"
SETTINGS_DEST="$USER_HOME/.claude/settings.json"

if [[ -f "$SETTINGS_SRC" ]]; then
    cp "$SETTINGS_SRC" "$SETTINGS_DEST"
    chown "$USERNAME":"$USERNAME" "$SETTINGS_DEST"
    chmod 644 "$SETTINGS_DEST"
    log_ok "Deployed claude settings.json (deny/allow rules)"
fi

# ---- List deployed skills ----
log_info ""
log_info "Skills deployed in $SKILLS_DEST:"
for skill_dir in "$SKILLS_DEST"/*/; do
    [[ -d "$skill_dir" ]] || continue
    name=$(basename "$skill_dir")
    desc=$(grep -m1 '^description:' "$skill_dir/SKILL.md" 2>/dev/null | sed 's/^description:\s*//' || echo "")
    log_info "  /$name - ${desc:0:80}"
done

log_ok "08-skills-deploy complete"

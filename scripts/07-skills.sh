#!/usr/bin/env bash
# 07-skills.sh — install bundled skills into multica container.
#
# Skills live in skills/ in this repo. They are mounted read-only into the
# multica container at /home/claude/.claude/skills/. Container's brainstorm
# Claude picks them up automatically.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
require_env

REPO=$(repo_root)
SKILLS_DIR="$REPO/skills"

if [[ ! -d "$SKILLS_DIR" ]]; then
    log_error "skills/ directory not found at $SKILLS_DIR"
    exit 1
fi

# ---- Validate skill structure -----------------------------------------------
# Each skill must have a SKILL.md
log_info "Validating skill bundle..."
errors=0
for skill_dir in "$SKILLS_DIR"/*/; do
    name=$(basename "$skill_dir")
    if [[ ! -f "$skill_dir/SKILL.md" ]]; then
        log_error "Skill '$name' missing SKILL.md"
        errors=$((errors+1))
    fi
done

if [[ $errors -gt 0 ]]; then
    log_error "Skill validation failed ($errors issues)"
    exit 1
fi
log_ok "All skills have SKILL.md"

# ---- The bind-mount happens via docker-compose volume — we just need to ----
# trigger a re-read. Container picks up changes on every Claude session start.
# If multica is running, restart it to pick up changes.
if docker ps --filter "name=multica" --format '{{.Names}}' | grep -q '^multica$'; then
    log_info "multica is running — restarting to pick up skills..."
    docker restart multica >/dev/null
    log_ok "multica restarted; skills active"
else
    log_skip "multica not running yet (06-docker-compose.sh will start it)"
fi

# ---- List active skills ------------------------------------------------------
log_info ""
log_info "Skills bundle:"
for skill_dir in "$SKILLS_DIR"/*/; do
    name=$(basename "$skill_dir")
    desc=$(grep -m1 '^description:' "$skill_dir/SKILL.md" 2>/dev/null | sed 's/^description:\s*//' || echo "(no description)")
    log_info "  /$name — $desc"
done

log_ok "07-skills complete"

#!/usr/bin/env bash
# 18-github-webhook-cleanup.sh — revoke the GitHub webhooks that PUL-166
# replaced with polling. Run as part of the cutover after the poller
# has been live for the G2 dry-run gate. See docs/PUL-166-CUTOVER.md.
#
# Scope: per-repo classic webhooks (REST /repos/{owner}/{repo}/hooks)
# pointing at the multica Funnel hostname. As of the PUL-166 cutover
# date (2026-05-18), no per-repo webhooks match — the live integration
# delivers via the `multica-cascade-rabbeet` GitHub App installation
# webhook (PUL-141 / PUL-167 investigation history). App-installation
# webhooks live on the App settings (GET /app/hook/config), NOT on
# the repo. This script still ships:
#   (a) as a belt-and-braces sweep for any classic webhook that
#       sneaks in via a future change,
#   (b) as the documented entry point operators run during the
#       cutover so the App-webhook update can be cross-referenced
#       (the runbook covers the App-webhook step separately).
#
# For App-installation webhooks: edit the App at
# https://github.com/organizations/<org>/settings/apps/multica-cascade-rabbeet/advanced
# and either disable the webhook URL or uninstall the App from the
# four watched repositories. There is no GitHub REST endpoint that
# lets a PAT update another App's webhook config.
#
# Idempotent: re-running after a successful pass finds zero matches
# and exits 0.
#
# Usage:
#   GH_TOKEN=<token-with-admin:repo_hook>   ./18-github-webhook-cleanup.sh                                # dry-run
#   GH_TOKEN=<...> CONFIRM=yes              ./18-github-webhook-cleanup.sh                                # actually delete
#   REPOS="rabbeet/Pulse,rabbeet/multica"   ./18-github-webhook-cleanup.sh                                # restrict scope
#
# Default repo set matches MULTICA_GITHUB_POLL_REPOS — the same four
# repositories the poller now ingests events from. Override via
# REPOS=... when iterating, or use MULTICA_GITHUB_POLL_REPOS directly
# (env var on the host).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# ---- Configuration ----
DEFAULT_REPOS="rabbeet/Pulse,rabbeet/multica,rabbeet/multica-server,rabbeet/agent-context"
DEFAULT_PATTERN="multica.tail38d0e3.ts.net"

REPOS_CSV="${REPOS:-${MULTICA_GITHUB_POLL_REPOS:-$DEFAULT_REPOS}}"
HOSTNAME_PATTERN="${WEBHOOK_HOSTNAME_PATTERN:-$DEFAULT_PATTERN}"
CONFIRM="${CONFIRM:-no}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if [[ -z "$TOKEN" ]]; then
    log_error "GH_TOKEN (or GITHUB_TOKEN) must be set with admin:repo_hook scope"
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required (apt install jq)"
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    log_error "curl is required"
    exit 1
fi

if [[ "$CONFIRM" != "yes" ]]; then
    log_warn "DRY RUN — set CONFIRM=yes to actually delete webhooks"
fi
log_info "Scoping to repos: $REPOS_CSV"
log_info "Matching webhook URLs containing: $HOSTNAME_PATTERN"

# ---- Iterate ----
total_matched=0
total_deleted=0
IFS=',' read -ra REPOS_ARR <<< "$REPOS_CSV"
for repo in "${REPOS_ARR[@]}"; do
    repo="$(echo "$repo" | tr -d '[:space:]')"
    [[ -z "$repo" ]] && continue

    log_info "[$repo] listing webhooks..."
    hooks=$(curl -sS \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$repo/hooks")

    # The response is either an array of hooks or an error object.
    if ! echo "$hooks" | jq -e 'type == "array"' >/dev/null 2>&1; then
        err=$(echo "$hooks" | jq -r '.message // "unknown"')
        log_error "[$repo] API error: $err"
        continue
    fi

    matches=$(echo "$hooks" | jq -c \
        --arg pat "$HOSTNAME_PATTERN" \
        '.[] | select(.config.url // "" | contains($pat)) | {id, url: .config.url, active}')

    if [[ -z "$matches" ]]; then
        log_skip "[$repo] no matching webhooks"
        continue
    fi

    echo "$matches" | while IFS= read -r hook; do
        id=$(echo "$hook" | jq -r '.id')
        url=$(echo "$hook" | jq -r '.url')
        active=$(echo "$hook" | jq -r '.active')
        total_matched=$((total_matched + 1))
        log_info "[$repo] match: hook id=$id active=$active url=$url"

        if [[ "$CONFIRM" == "yes" ]]; then
            status=$(curl -sS -o /dev/null -w '%{http_code}' \
                -X DELETE \
                -H "Authorization: Bearer $TOKEN" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/$repo/hooks/$id")
            if [[ "$status" == "204" ]]; then
                log_ok "[$repo] deleted hook $id"
                total_deleted=$((total_deleted + 1))
            else
                log_error "[$repo] DELETE returned $status for hook $id"
            fi
        else
            log_info "[$repo] (dry-run) would DELETE /repos/$repo/hooks/$id"
        fi
    done
done

log_info ""
if [[ "$CONFIRM" == "yes" ]]; then
    log_ok "Cutover webhook cleanup complete."
else
    log_warn "Dry-run complete. Re-run with CONFIRM=yes to delete."
fi

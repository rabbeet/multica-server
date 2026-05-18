# PUL-166 cutover runbook — webhook → polling

This is the operator-driven cutover for [PUL-166](https://multica.ai/issues/PUL-166).
The polling code lives in `rabbeet/multica` (`server/internal/githubpoll/`,
shipped via PR1/PR2/PR3). The Funnel removal + GitHub-side webhook revocation
lives in this repo (`rabbeet/multica-server`, this PR).

Run this sequence end-to-end. Each step has a verification — if the verify
fails, stop and roll back (rollback at the bottom). Total time: ~30 minutes
including the 5-minute drain.

---

## 0. Pre-flight

```bash
# On multica-server host, as root (or via the deploy mechanism).
# Verify rabbeet/multica deployed binary contains PR1+PR2+PR3.
docker exec multica-postgres-1 psql -U multica -d multica -c \
    "SELECT version FROM schema_migrations WHERE version = '080_github_poll_cursor';"
# Expect: 1 row.

docker exec multica-backend-1 multica version 2>/dev/null || \
    docker inspect multica-backend-1 --format '{{.Image}}' | head -1
# Image SHA should match a build AFTER PR3 merge (commit 23cade2f or later).
```

Also confirm Tailscale iOS is installed on the iPhone and the device is connected
to the tailnet — without it AC5 of PUL-166 cannot be verified.

## 1. Bring the poller up — parallel with webhook (G2 dry-run)

Goal: 24 hours of observation that the poll-channel sees the same events the
webhook-channel sees, **without** turning the webhook off yet. Duplicate rows
are absorbed by `cascade_retrigger.event_id` UNIQUE, but webhook and poll use
DIFFERENT UUIDv5 namespaces — so they will NOT collide at the row level.
Worker-level duplicate cascade fires ARE possible during overlap; PUL-166's
plan accepts this for the G2 window only.

```bash
# Edit /opt/multica-server/.env (or wherever the deploy env lives) and append:
MULTICA_GITHUB_POLL_ENABLED=true
MULTICA_GITHUB_POLL_REPOS=rabbeet/Pulse,rabbeet/multica,rabbeet/multica-server,rabbeet/agent-context
# MULTICA_GITHUB_POLL_INTERVAL_SEC=30   # optional, default 30

# Restart the backend so it picks up the new env.
docker compose -f /home/multica/multica/docker-compose.selfhost.yml \
    --env-file /opt/multica-server/.env \
    up -d --force-recreate backend
```

**Verify (within 60 seconds):**

```bash
docker logs --tail=200 multica-backend-1 2>&1 | grep githubpoll | head -10
# Expect lines like:
#   githubpoll.started repos=rabbeet/Pulse,...
#   githubpoll.poller.tick_complete repo=rabbeet/Pulse events_seen=N classified=M ...
# OR (steady state, no new events):
#   githubpoll.poller.tick_not_modified repo=rabbeet/Pulse ...

# Confirm cursor rows are being written:
docker exec multica-postgres-1 psql -U multica -d multica -c \
    "SELECT repo, last_event_id, last_polled_at, etag IS NOT NULL AS has_etag
     FROM github_poll_cursor ORDER BY repo;"
```

**G2 gate (24 hours observation):**

```bash
# Compare poll-channel classified events against webhook-channel for the same
# period. They should match ±5% (both ingress channels see the same upstream
# events; namespaces differ but counts should align).
# Via Prometheus /metrics if scraping is set up:
#   sum(rate(multica_github_poll_events_total{event_type=~"ci_failure|pr_merged|pr_review_change|pr_title_edit"}[24h])) by (event_type)
# Or directly against the DB rows:
docker exec multica-postgres-1 psql -U multica -d multica -c \
    "SELECT event_type, count(*) FILTER (WHERE event_id::text LIKE '9e2d4f1c-%') AS poll,
                                  count(*) FILTER (WHERE event_id::text NOT LIKE '9e2d4f1c-%') AS webhook
     FROM cascade_retrigger
     WHERE fired_at > now() - interval '24 hours'
     GROUP BY event_type
     ORDER BY event_type;"
# (9e2d4f1c is the poll-namespace UUIDv5 prefix — distinct from the webhook
# namespace a3b6f8e2.)
```

If poll/webhook counts diverge by more than 5%, do NOT proceed to step 2.
Investigate the discrepancy first (likely classifier gap or rate-limit
throttling).

## 2. Cut the webhook channel off

Once G2 is green:

```bash
# Edit /opt/multica-server/.env again and set:
MULTICA_CASCADE_WEBHOOK_ENABLED=false
# (Leave MULTICA_GITHUB_POLL_ENABLED=true.)

# Restart the backend.
docker compose -f /home/multica/multica/docker-compose.selfhost.yml \
    --env-file /opt/multica-server/.env \
    up -d --force-recreate backend
```

**Verify:**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
    http://localhost:8080/webhooks/github -H "X-GitHub-Event: ping"
# Expect: 404 (the route no longer exists on the parent router).

# Tail the backend logs for 5 minutes — confirm githubpoll.poller.tick_complete
# keeps producing rows, and no `webhooks.signature_failed` or similar from
# straggling GitHub retries.
docker logs -f multica-backend-1 2>&1 | grep -E "githubpoll|webhooks"
```

Wait 5 minutes after the flag flip so GitHub's webhook retry queue drains. The
webhook delivery side will see 404s for that window — that's the signal to
GitHub that this endpoint is gone.

## 3. Remove the Tailscale Funnel

This is the step that makes `multica.tail38d0e3.ts.net` NXDOMAIN in public DNS,
which is the user-visible fix from PUL-160 (iPhone Safari).

```bash
# On multica-server host, as root:
sudo bash /opt/multica-server/scripts/10-tailscale-serve.sh
# This script now (PR4) explicitly disables any Funnel on :8443/:443 as
# an idempotent cleanup before re-asserting tailnet-only HTTPS:443.

tailscale serve status
# Expect:
#   https://multica.tail38d0e3.ts.net (tailnet only)
#   |-- / proxy http://localhost:3000
# NO "Funnel on" line should appear.
```

## 4. Verify public DNS is gone

Funnel publishes hostnames in Tailscale's public DNS zone with TTL 300s. After
Funnel-off, the record disappears at the next TTL expiry.

```bash
# Should immediately go to NXDOMAIN inside the tailnet (MagicDNS only):
dig multica.tail38d0e3.ts.net @100.100.100.100

# From public resolver — wait up to 5 minutes for TTL expiry, then:
dig multica.tail38d0e3.ts.net @8.8.8.8
# Expect: empty answer / NXDOMAIN.
```

## 5. Revoke the GitHub webhooks

`cascade_retrigger` rows from the webhook channel will stop flowing as soon as
the GitHub-side webhook is gone (no more POSTs at all). The poller continues
to backfill.

Two distinct revocation paths — both are part of the cutover.

### 5a. Classic per-repo webhooks (script-driven)

```bash
# Dry-run first to see what would be deleted:
GH_TOKEN=<a PAT with admin:repo_hook on the four watched repos> \
    bash /opt/multica-server/scripts/18-github-webhook-cleanup.sh

# If matches appear, re-run with CONFIRM=yes:
GH_TOKEN=<same token> CONFIRM=yes \
    bash /opt/multica-server/scripts/18-github-webhook-cleanup.sh
```

The script lists hooks via `GET /repos/{owner}/{repo}/hooks` and deletes those
whose `config.url` contains `multica.tail38d0e3.ts.net`. Idempotent.

As of the PUL-166 cutover date (2026-05-18) this returns zero matches in the
four watched repos — the live integration uses an App-installation webhook,
not per-repo webhooks (see step 5b). The script still ships as a belt-and-braces
sweep for future drift.

### 5b. GitHub App installation webhook (manual via Settings UI)

The active integration is the `multica-cascade-rabbeet` GitHub App (history
in [PUL-141](https://multica.ai/issues/PUL-141), root cause investigation
in [PUL-167](https://multica.ai/issues/PUL-167)). Its single webhook URL is
configured at the App level, not per-repo, and is reachable only by the App
owner — there is no PAT-driven REST endpoint to mutate another App's webhook
config.

Open:

```
https://github.com/organizations/<org>/settings/apps/multica-cascade-rabbeet/advanced
```

Then either:

- **Option A (recommended):** clear the **Webhook URL** field (set Active = off
  if the field is required). The App stays installed (so any other capabilities
  like the agent context API still work) but emits no webhook deliveries.
- **Option B:** uninstall the App from the four watched repos via the App's
  Install page. Cleaner but also removes any non-webhook permissions; only do
  this if the App had no other use.

Verify the deliveries stop:

```
https://github.com/organizations/<org>/settings/apps/multica-cascade-rabbeet/advanced
```

Under **Recent Deliveries**, no new entries should appear after ~1 minute. If
GitHub keeps trying to deliver, double-check the Active toggle / Webhook URL.

## 6. Verify iPhone Safari works (AC5)

From the user's iPhone connected to the tailnet via the Tailscale iOS app:

1. Open Safari.
2. Visit `https://multica.tail38d0e3.ts.net`.
3. Multica UI loads.

If Safari shows `ERR_SSL_PROTOCOL_ERROR` or `ERR_NAME_NOT_RESOLVED`, check:

- Tailscale iOS app is connected (green icon).
- DNS settings → Use Tailscale DNS (in the iOS Tailscale settings).
- `tailscale serve status` on the host shows the tailnet route (step 3 verify).

---

## Rollback

If anything in steps 1-5 misbehaves, restore the webhook channel:

```bash
# 1. Set MULTICA_CASCADE_WEBHOOK_ENABLED=true (and optionally
#    MULTICA_GITHUB_POLL_ENABLED=false to avoid duplicates), restart backend.
# 2. Re-enable Funnel:
sudo tailscale funnel --bg 8443 / http://localhost:8080
# Then restrict path with `tailscale serve` (the old config —
# /webhooks/github only).
# 3. Re-create the webhooks in GitHub UI for each of the four repos with
#    URL https://multica.tail38d0e3.ts.net:8443/webhooks/github and
#    the same HMAC secret as before (MULTICA_GITHUB_WEBHOOK_SECRET_CURRENT).
# 4. Wait 5 minutes, confirm new events flow to cascade_retrigger via the
#    webhook namespace UUIDs.
```

Time to roll back: ~10 minutes if all four webhook re-creations happen in
parallel.

## Post-merge cleanup (PR5, separate)

Seven days of stability after this cutover triggers PR5:

- Remove `server/internal/webhooks/github/` adapter from `rabbeet/multica`.
- Remove env vars `MULTICA_GITHUB_WEBHOOK_SECRET_{CURRENT,PREVIOUS}` from
  `/opt/multica-server/.env` and from 1Password.
- Remove the `MULTICA_CASCADE_WEBHOOK_ENABLED` flag entirely (it's already
  off; the code path is dead).

Track that as a separate ticket once the stability window closes.

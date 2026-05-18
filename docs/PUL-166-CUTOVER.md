# PUL-166 cutover runbook — webhook → polling

This is the operator-driven cutover for [PUL-166](https://multica.ai/issues/PUL-166).
The polling code lives in `rabbeet/multica` (`server/internal/githubpoll/`,
shipped via PR1/PR2/PR3). The Funnel removal + GitHub-side webhook revocation
lives in this repo (`rabbeet/multica-server`, this PR).

Run this sequence end-to-end. Each step has a verification — if the verify
fails, stop and roll back (rollback at the bottom). Total time: ~30 minutes
including the 5-minute drain.

> ⚠️ **Do not skip steps and do not reorder them.** Step 2 (turn webhook OFF)
> is only safe to run *after* step 1's G2 verify succeeds. Skipping step 1
> means there is no live poll-channel during the webhook-off → Funnel-off
> window, so events arriving in that window simply vanish. If unsure, stop
> and re-read.

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

Compare poll-channel counts against webhook-channel counts. They should match
±5% — both ingress channels see the same upstream events from GitHub.

**Important:** the channels CAN'T be disambiguated at the `cascade_retrigger`
row level by event_id prefix. UUIDv5 mixes the namespace into a SHA1 — the
namespace UUID does NOT survive as a hex prefix in the resulting id. Use the
two channels' own emit-side counters instead.

```bash
# Poll-channel: read the Prometheus counter the poller increments per event.
# (Requires METRICS_LISTEN_ADDR set on the backend so /metrics is reachable.)
curl -sS http://localhost:9100/metrics | grep '^multica_github_poll_events_total'
# Expected lines, one per (repo, event_type) seen in the last 24h:
#   multica_github_poll_events_total{event_type="ci_failure",repo="rabbeet/Pulse"} 17
#   multica_github_poll_events_total{event_type="pr_merged",repo="rabbeet/Pulse"} 4
#   ...
# Also confirm the poller hasn't been silently stuck:
curl -sS http://localhost:9100/metrics | grep '^multica_github_poll_cursor_age_seconds'
# All values must be < 2 * MULTICA_GITHUB_POLL_INTERVAL_SEC (default 60s).

# Webhook-channel: tail the backend log for completed deliveries the inbound
# adapter handled in the same window. The adapter logs at info on every accepted
# event, and the cascade_retrigger row insert is observable via
# webhooks.signature_failed / webhooks.adapter_unsupported / cascade_retrigger
# row count for events fired in the window.
docker logs --since=24h multica-backend-1 2>&1 \
    | grep -E 'webhooks\.github\.normalize_ok|webhooks\.signature_failed' \
    | awk '/normalize_ok/ {ok++} /signature_failed/ {fail++} END {print "ok=" ok " sig_failed=" fail}'

# Alternatively, count cascade_retrigger rows in the window (this includes
# BOTH channels — useful for sanity, but does NOT discriminate):
docker exec multica-postgres-1 psql -U multica -d multica -c \
    "SELECT event_type, count(*)
     FROM cascade_retrigger
     WHERE fired_at > now() - interval '24 hours'
     GROUP BY event_type
     ORDER BY event_type;"
```

If the poll-channel `events_total` rate is more than 5% off the webhook log
event counts for the same window, do NOT proceed to step 2. Investigate the
discrepancy first (most likely candidates: classifier gap on a new GitHub
event variant, rate-limit throttling, or events older than what `/events`
keeps as history).

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

Wait 5 minutes after the flag flip. GitHub does NOT retry 404 responses
(retries fire only on 5xx, over ~8h with backoff), so a 404 wall is final
from GitHub's perspective — no straggler-retries to drain. The 5-minute
wait is for in-flight POSTs that GitHub had already queued before the flip
to land and resolve cleanly.

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
# Inside the tailnet, MagicDNS keeps resolving `multica.tail38d0e3.ts.net`
# to the host's 100.x tailnet IP — that's by design and unaffected by
# Funnel-off. This is NOT the test that matters; it's a sanity check
# that the tailnet hostname still works for tailnet-connected devices.
dig multica.tail38d0e3.ts.net @100.100.100.100
# Expect: AN answer with a 100.x address.

# The actual test: from a PUBLIC resolver the hostname must go away.
# Wait up to 5 minutes for the public-DNS TTL to expire (60–300s
# depending on Tailscale's edge), then:
dig multica.tail38d0e3.ts.net @8.8.8.8
# Expect: empty answer / NXDOMAIN. THIS is the signal that the
# PUL-160 root cause (public DNS leak) is fixed.
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

If anything in steps 1-5 misbehaves, restore the webhook channel.

### Rollback step 1 — re-enable receiver

```bash
# /opt/multica-server/.env: set
MULTICA_CASCADE_WEBHOOK_ENABLED=true
# (Optionally MULTICA_GITHUB_POLL_ENABLED=false if you want to silence
# poll-channel writes during the rollback investigation.)

docker compose -f /home/multica/multica/docker-compose.selfhost.yml \
    --env-file /opt/multica-server/.env \
    up -d --force-recreate backend

curl -sS -X POST http://localhost:8080/webhooks/github \
    -H "X-GitHub-Event: ping" -o /dev/null -w '%{http_code}\n'
# Expect 401 (signature missing — proves the route is alive again).
```

### Rollback step 2 — re-enable Funnel

```bash
sudo tailscale funnel --bg 8443 http://localhost:8080
tailscale serve status --json | jq .AllowFunnel
# Should now show the :8443 funnel route.
```

### Rollback step 3 — re-create the deletion target

**This is the step where pick the right path matters** — there are two
possible sources of the live webhook deliveries, the rollback for each is
different. Pick based on which step 5 path was used:

- **3a (App-installation webhook — the path used by the multica-cascade-rabbeet
  App):** re-open the App settings at
  `https://github.com/organizations/<org>/settings/apps/multica-cascade-rabbeet/advanced`
  and re-enter the previous **Webhook URL**
  (`https://multica.tail38d0e3.ts.net:8443/webhooks/github`) + flip the Active
  toggle back on. The HMAC secret stays the same on the App side; no rotation
  needed. New deliveries start arriving within 1 minute.

- **3b (classic per-repo webhooks — only if step 5a actually deleted any):**
  re-create webhooks in each of the four watched repos via the GitHub repo
  Settings → Webhooks UI, with URL
  `https://multica.tail38d0e3.ts.net:8443/webhooks/github` + the HMAC secret
  matching `MULTICA_GITHUB_WEBHOOK_SECRET_CURRENT`. As of 2026-05-18 step 5a
  deletes nothing — skip 3b unless you confirmed step 5a's dry-run showed
  matches.

### Rollback step 4 — verify

Wait 5 minutes, then confirm new events flow to `cascade_retrigger`:

```bash
docker exec multica-postgres-1 psql -U multica -d multica -c \
    "SELECT event_type, count(*)
     FROM cascade_retrigger
     WHERE fired_at > now() - interval '5 minutes'
     GROUP BY event_type ORDER BY event_type;"
```

If counts are zero AND your test PR produced no row, deliveries are still
broken — check the App settings page (3a) for **Recent Deliveries** errors.

Time to roll back: ~10 minutes for App-webhook path; longer for classic-webhook
path because each repo's UI takes ~1 minute.

## Post-merge cleanup (PR5, separate)

Seven days of stability after this cutover triggers PR5:

- Remove `server/internal/webhooks/github/` adapter from `rabbeet/multica`.
- Remove env vars `MULTICA_GITHUB_WEBHOOK_SECRET_{CURRENT,PREVIOUS}` from
  `/opt/multica-server/.env` and from 1Password.
- Remove the `MULTICA_CASCADE_WEBHOOK_ENABLED` flag entirely (it's already
  off; the code path is dead).

Track that as a separate ticket once the stability window closes.

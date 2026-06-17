# multica-mattermost-bot — operator runbook

PUL-328. Brainstorm-VPS daemon that bridges a Mattermost channel into multica
issues in the marimo project, bidirectionally. One MM thread = one multica
issue; agent comments flow back as MM posts (with PNG screenshots of
matplotlib charts).

- Plan: [`rabbeet/plans:Multica/2026-06-17-pul-328-mattermost-bot-marimo.md`](https://github.com/rabbeet/plans/blob/main/Multica/2026-06-17-pul-328-mattermost-bot-marimo.md)
- Source: `rabbeet/multica:server/cmd/multica-mattermost-bot/` +
  `server/internal/mmbot/`
- Install script: `scripts/19-multica-mattermost-bot.sh` (this repo)
- Systemd unit: `multica-mattermost-bot.service`
- Working dir: `/var/lib/multica-mattermost-bot/`
- Lockfile: `/var/lib/multica-mattermost-bot/state.db.lock` (held by the
  running daemon — `flock` enforces single-instance)

## First-time install (one-time)

Run as root on the brainstorm-VPS:

```bash
cd /srv/multica-server-bare.git  # or wherever the working checkout lives
sudo bash scripts/19-multica-mattermost-bot.sh
```

The script:

1. Installs `chromium` (Lane C screenshot pipeline).
2. Creates `/var/lib/multica-mattermost-bot/` owned by the `multica` user.
3. Scaffolds `/etc/multica-mattermost-bot.env` with `REPLACE_ME` placeholders.
4. Drops `/usr/local/bin/multica-mattermost-bot-op-read` (the wrapper that
   resolves `MM_BOT_TOKEN` from 1Password into tmpfs at startup).
5. Drops the systemd unit at `/etc/systemd/system/multica-mattermost-bot.service`.
6. Enables (but does **not** start) the service.

You still need to:

1. **Build & install the binary** (from a `rabbeet/multica` checkout):
   ```bash
   make build
   sudo install -m 0755 server/bin/multica-mattermost-bot \
     /usr/local/bin/multica-mattermost-bot
   ```
2. **Set up the Mattermost bot account** (see "Mattermost-side setup" below).
3. **Populate `/etc/multica-mattermost-bot.env`** with real values.
4. **Store `MM_BOT_TOKEN` in 1Password** (see "Token rotation").
5. `sudo systemctl start multica-mattermost-bot`
6. Watch logs: `journalctl -u multica-mattermost-bot -f`

## Mattermost-side setup

In the Mattermost admin console:

1. **Create the bot account.** System Console → Integrations → Bot Accounts → Add Bot
   Account → Username `multica-bot`. Save the resulting `user_id` — you'll
   need it for `MM_BOT_USER_ID`.
2. **Generate a Personal Access Token** for the bot. Copy the value once
   (it's never displayed again).
3. **Create or pick the channel** the bot will watch (e.g. `#data-requests`).
   Add the bot user to the channel. Copy the `channel_id` from the channel's
   URL or via `mmctl channel search data-requests` — you'll need it for
   `MM_ALLOWED_CHANNELS`.
4. **Invite the humans** who will be allowed to trigger the bot. Collect
   their MM `user_id`s for `MM_ALLOWED_USER_IDS`.

The bot **only** acts on posts that satisfy BOTH:
- `channel_id ∈ MM_ALLOWED_CHANNELS`
- `user_id ∈ MM_ALLOWED_USER_IDS`

So inviting someone to the channel without listing them in `MM_ALLOWED_USER_IDS`
is harmless — the bot stays silent.

## Token storage in 1Password

The bot's MM PAT lives at `op://Pulse-Dev/Pulse-env/MM_BOT_TOKEN`. Install:

```bash
op item edit Pulse-env MM_BOT_TOKEN='<the-PAT-value>' --vault Pulse-Dev
```

`/usr/local/bin/multica-mattermost-bot-op-read` is invoked by the systemd unit's
`ExecStartPre` and resolves this into `/run/multica-mattermost-bot/secrets.env`
(tmpfs, mode 0600, gone on reboot). The bot reads `MM_BOT_TOKEN` from that file.

**Never** put the token directly into `/etc/multica-mattermost-bot.env` — it
would land in disk backups and ops dashboards. The 1Password indirection
keeps the token off persistent disk.

## Token rotation

Rotation takes ≤30 seconds end-to-end:

```bash
# 1. Revoke the old PAT in the MM admin console (System Console → Bot Accounts → multica-bot → Tokens).
# 2. Generate a fresh PAT, copy the value.
# 3. Update 1Password:
op item edit Pulse-env MM_BOT_TOKEN='<new-PAT-value>' --vault Pulse-Dev

# 4. Restart the daemon — ExecStartPre re-resolves the token from 1Password.
sudo systemctl restart multica-mattermost-bot
```

No code redeploy needed.

## Daily operations

### Health check

```bash
systemctl status multica-mattermost-bot
journalctl -u multica-mattermost-bot --since '10 min ago' | grep -iE 'err|warn'
```

A healthy unit shows `active (running)` and an empty grep result.

### Common queries (sqlite3 on the state DB)

```bash
sudo sqlite3 /var/lib/multica-mattermost-bot/state.db <<'SQL'
SELECT COUNT(*) AS thread_count FROM mm_threads;
SELECT multica_issue_id, last_seen_status, last_render_ts FROM mm_threads ORDER BY created_at DESC LIMIT 10;
SELECT COUNT(*) AS pending_outbound FROM pending_outbound;
SELECT key, value FROM meta;
SQL
```

### Forcing a re-sync of one thread

If a single MM thread got out of sync (rare), delete its mapping; the next
top-level post by Лина in the same thread root will re-create a multica
issue.

```bash
sudo sqlite3 /var/lib/multica-mattermost-bot/state.db \
  "DELETE FROM mm_threads WHERE multica_issue_id = '<issue-uuid>';"
sudo systemctl restart multica-mattermost-bot
```

### Wiping all state (development only)

```bash
sudo systemctl stop multica-mattermost-bot
sudo rm /var/lib/multica-mattermost-bot/state.db*
sudo systemctl start multica-mattermost-bot
```

## Failure modes

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| `journalctl` shows `config: required env vars unset: ...` | `/etc/multica-mattermost-bot.env` has REPLACE_ME or missing keys | Edit env file, `systemctl restart multica-mattermost-bot` |
| `unauthorized (rotate MM_BOT_TOKEN)` in logs | PAT was revoked, expired, or wrong | Rotate per "Token rotation" above |
| `flock` failure at startup | Another daemon instance already running (or a stale lock file from an OOM-killed prior run) | Check `pgrep -af multica-mattermost-bot`; if no process, `rm /var/lib/multica-mattermost-bot/state.db.lock` and restart |
| Screenshots not appearing in MM thread | Local marimo (127.0.0.1:2718) down OR chromium crashed OR rate-limit window | `curl http://127.0.0.1:2718`; check `journalctl` for `mmbot/render` warnings |
| Persistent WS reconnect failures (≥10 in a row) | MM down OR token revoked OR network broken | Lane D logs an `ERROR`; check connectivity; multica issue with `pulse-alert` label is created (Lane E TODO — escalation wiring) |
| Лина's message never became a multica issue | She's not in `MM_ALLOWED_USER_IDS` OR channel not in `MM_ALLOWED_CHANNELS` | `journalctl` shows `ignored unallowed user`; add her id, restart |

## Resource limits

The unit caps memory at 1G and tasks at 128 (see
`scripts/19-multica-mattermost-bot.sh`). The screenshot pipeline launches a
fresh chromium process per call and reaps it on exit, so steady-state memory
sits well under 100M; the 1G cap is headroom for screenshot bursts.

## Security model summary

See plan revision 2 § "Defense layers" for the full audit. Briefly:

- **MM_BOT_TOKEN never on disk** — only in 1Password + tmpfs at runtime.
- **Bot sees only invited channels** — MM-side enforced.
- **Allowlisted users only** — code-level filter chain.
- **`--project marimo` + `--assignee-id agent-2` are constants** in
  `multicacli.Client` — no MM message body can override (tested with 10
  adversarial bodies in PR-1 Lane D).
- **agent-2's `custom_env` lacks `FORGE_API_TOKEN`/`OP_SERVICE_ACCOUNT_TOKEN`** — so
  even if a Лина-side prompt-injection tries to make agent-2 write code or
  push, it has no credentials to do so. This is the foundational defense
  layer; everything above is belt-and-braces.

## Removing the bot

```bash
sudo systemctl stop multica-mattermost-bot
sudo systemctl disable multica-mattermost-bot
sudo rm /etc/systemd/system/multica-mattermost-bot.service
sudo rm -r /var/lib/multica-mattermost-bot
sudo rm /etc/multica-mattermost-bot.env
sudo rm /usr/local/bin/multica-mattermost-bot{,-op-read}
sudo systemctl daemon-reload
op item edit Pulse-env MM_BOT_TOKEN='' --vault Pulse-Dev  # blank out
```

In MM: revoke the PAT and (optionally) delete the bot account.

# Migrating Conduit → Tuwunel (verified procedure)

Why migrate: upstream Conduit (≤ v0.10.15) returns an always-empty receipts
extension in its simplified sliding sync, so Element X unread badges get stuck
and never clear. Tuwunel implements the receipts extension and can import a
Conduit database **in place** — accounts, rooms, history, media, and access
tokens all survive, so neither Element X nor bots need to log in again.

Verified on a live server (Oct 2026): Conduit v0.10.15 → Tuwunel v1.9.4,
~2 minutes of downtime, zero client-side changes.

## 0. What you need

- Tuwunel image: `ghcr.io/matrix-construct/tuwunel:latest` (multi-arch)
- A backup of the Conduit DB directory (the migration rewrites it in place)
- Your `server_name` (must not change), registration token, and the knowledge
  of whether your media lives in the DB dir (`db/media/`) — Conduit 0.10.x
  keeps it there

## 1. Pre-flight on a copy (no downtime)

Copy the DB (from a cold/consistent copy — e.g. your nightly standby or a
short stop) to a test directory, rename `media/` to `media_conduit/`, and run
Tuwunel on a side port:

```toml
[global]
server_name = "your.server.name"      # same as before
port = 6167
address = "0.0.0.0"
database_path = "/var/lib/matrix-conduit"
allow_federation = false
allow_registration = true
registration_token = "your-token"
conduit_source_media_path = "/var/lib/matrix-conduit/media_conduit"
log = "info"
```

```bash
docker run -d --name tuwunel-test -p 127.0.0.1:8009:6167 \
  -e TUWUNEL_CONFIG=/etc/tuwunel.toml \
  -v /path/tuwunel.toml:/etc/tuwunel.toml:ro \
  -v /path/db-copy:/var/lib/matrix-conduit \
  ghcr.io/matrix-construct/tuwunel:latest
```

Check the logs — a successful import looks like:

```
migrations::conduit: Imported Conduit media originals imported=65
migrations::conduit: Split Conduit last-notification-read rows ... moved=12
migrations::fix_referencedevents_missing_sep: Fixed ... total=13352
migrations::rebuild_roomid_tscount_pducount: Rebuilt ... count=13353
```

Then verify against port 8009:

- An **existing access token** still works (classic `/sync` returns your rooms)
- The **receipts extension** returns data — POST to
  `/_matrix/client/unstable/org.matrix.simplified_msc3575/sync` with
  `{"room_subscriptions": {"<room_id>": {"required_state": [], "timeline_limit": 5}},
  "extensions": {"receipts": {"enabled": true}}}`
  and look for `extensions.receipts.rooms.<room>` (this is the part Conduit
  never returned)

## 2. Cutover (short downtime)

```bash
docker stop matrix-server                        # Conduit down
tar czf backup-pre-tuwunel.tgz -C . db           # full backup
mv db/media db/media_conduit                     # Tuwunel reads it via conduit_source_media_path
docker rename matrix-server conduit-old          # keep for rollback
docker run -d --name matrix-server --restart always \
  -p 127.0.0.1:8008:8008 \
  -e TUWUNEL_CONFIG=/etc/tuwunel.toml \
  -v /path/tuwunel.toml:/etc/tuwunel.toml:ro \
  -v /path/db:/var/lib/matrix-conduit \
  ghcr.io/matrix-construct/tuwunel:latest
```

Verify the same three things as the pre-flight (versions, token, receipts
extension), then watch your bot reconnect on its own.

## 3. Rollback

```bash
docker stop matrix-server && docker rm matrix-server
rm -rf db && tar xzf backup-pre-tuwunel.tgz       # restores Conduit-format db
mv db/media_conduit db/media
docker rename conduit-old matrix-server && docker start matrix-server
```

## Gotchas

- **`registration_token` is read when the DB is first created.** Changing it
  in the config later has no effect on an existing DB — rotating the token
  effectively requires a fresh DB.
- Don't set `force_migration` unless the import refuses to run — it skips
  safety checks (startup warning makes this clear).
- Unknown config keys are ignored with a warning (`database_migration` does
  not exist anymore; the import is automatic).
- If a standby/secondary machine runs the old Conduit image against the
  migrated DB, it cannot read it — install the Tuwunel image there too.
- The media directory rename (`media` → `media_conduit`) is part of the
  import; don't "clean it up" afterwards.

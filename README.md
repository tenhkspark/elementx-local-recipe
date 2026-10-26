[English](README.md) | [한국어](README-ko.md) | [简体中文](README-zh.md) | [日本語](README-ja.md)

# Element X × Conduit × Tailscale — a fully local chat recipe

**No matrix.org, no open ports, no cloud accounts.** A Matrix chat that runs
entirely between your phone and your own server — with an AI bot powered by a
local LLM on top. Every step below is from a configuration in daily use on a
Mac mini + iPhone + Element X.

```
iPhone (Element X) ──HTTPS──▶ tailscale serve (443)
                                 ├── /_matrix     ─▶ 127.0.0.1:8008   Conduit/Tuwunel (Docker)
                                 └── /.well-known ─▶ 127.0.0.1:9111   static JSON
On the server:
  Homeserver ── RocksDB (./db/)
  bot (Hermes Agent gateway) ── 127.0.0.1:8008 ── OpenAI-compatible endpoint (local LLM)
```

What you get:

- Private chat between your iPhone and your home server (using Element X as-is)
- An AI bot (anything OpenAI-compatible; a local LLM is recommended)
- Push notifications to your phone (see "Notifications & privacy" for how it works)
- Only two external dependencies: Tailscale (free tier) and the Element X app.
  Message bodies and media stay on your own disk.

Prerequisites:

- A Mac (Mac mini recommended, Apple Silicon tested) or a Linux box
- Docker (colima recommended on macOS)
- Tailscale (MagicDNS enabled) + the Tailscale app and Element X on your iPhone
- Time: 30–60 minutes (about 20 without the bot)

---

## 0. Decide these first (they cannot be changed later)

**`server_name` is forever.** It is baked into every user ID (`@you:server_name`),
and changing it later invalidates all accounts, rooms and history. With
Tailscale, the easy choice is to use your server's tailnet hostname (for
example `matrix.example.ts.net`) as the server_name from day one.

> Field note: on our own server, for historical reasons, server_name differs
> from the hostname clients connect to (with federation off, the name is just
> a label and it works). But for a fresh install, **make them the same from
> the start** — that is simply the right call.

Federation is off (`allow_federation = false`). You lose connectivity to other
Matrix servers and gain an attack surface close to zero.

---

## 1. Homeserver: Conduit (or Tuwunel) in Docker

[Conduit](https://conduit.rs) is a lightweight Matrix homeserver (Rust, a
single binary). Everything lives in one RocksDB directory, so backing up means
copying that directory.

**Use 0.10.15 (the latest at the time of writing) or newer.** Element X
requires Simplified Sliding Sync (MSC4186), which Conduit supports since
0.10.0. Mind the security history too: CVE-2025-68667 and CVE-2026-24471
(account-takeover issues around federation invites) were fixed in 0.10.11, and
further auth-bypass vulnerabilities were fixed in 0.10.13/0.10.14. **The
minimum is 0.10.14; prefer the latest** (Conduit releases are slow, so track
CVEs yourself).

```bash
git clone https://github.com/<you>/elementx-local-recipe.git
cd elementx-local-recipe/scripts
cp conduit.toml.example conduit.toml
# edit conduit.toml:
#   server_name         ← the name you will use forever (read the note above)
#   registration_token  ← a long random string (e.g. openssl rand -hex 16)
./run-matrix.sh
curl -s http://127.0.0.1:8008/_matrix/client/versions   # JSON = OK
```

On a Mac, use colima for Docker. **Configure outbound DNS for the containers**
(needed to reach the push gateway for notifications; with a broken default,
notifications silently never arrive):

```bash
brew install colima docker
colima start --vm-type vz --cpu 2 --memory 2 --disk 20 --mount-type virtiofs \
  --dns 1.1.1.1 --dns 8.8.8.8
```

The homeserver listens on `127.0.0.1:8008` only. TLS is terminated by
tailscale serve in front of it, so the server itself needs no certificates.

> If you hit the stuck-unread-badge problem described in gotcha #15, migrating
> the homeserver to Tuwunel fixes it permanently — see
> [`docs/migrate-conduit-to-tuwunel.md`](docs/migrate-conduit-to-tuwunel.md).

---

## 2. Discovery: `/.well-known/matrix/client`

Element X fetches `GET /.well-known/matrix/client` from **the hostname you
type on the login screen** and uses the `base_url` found there. Serving that
file is the authoritative discovery path.

```bash
# static file (serve-wellknown.py generates it for you)
mkdir -p wellknown-root/matrix
echo '{"m.homeserver":{"base_url":"https://matrix.example.ts.net"}}' \
  > wellknown-root/matrix/client

# serve it on 127.0.0.1:9111 (--homeserver-url = your hostname)
python3 scripts/serve-wellknown.py --root wellknown-root --port 9111 \
  --homeserver-url https://matrix.example.ts.net
```

To keep it running, register it with launchd (macOS) or systemd (Linux). It is
just static JSON, so `python3 -m http.server 9111 --directory wellknown-root
--bind 127.0.0.1` works too.

> Field + source note: upstream Conduit's (v0.10.15) well-known setting must be
> written as the `[global.well_known]` **subtable**. The flat
> `well_known_client` key you see in conduwuit/continuwuity configs is a
> fork-only key name — **upstream Conduit silently ignores it** (unknown keys
> fall into a catchall; no warning, no error). When ignored, Conduit's own
> `8008/.well-known` returns a `server_name`-derived default URL. The login
> response contains no `well_known` either, so **the only discovery path that
> matters is the `/.well-known` of the hostname you type**. Get that right and
> it does not matter what Conduit's own well-known says. Serving well-known
> from a separate web server is explicitly allowed by the spec (CORS headers
> are a SHOULD — `python3 -m http.server` does not send them; use
> `serve-wellknown.py` if you want them).

---

## 3. Expose it with tailscale serve (no port forwarding)

TLS and exposure are handled by tailscale serve. No router port forwarding;
the server is reachable only inside your tailnet.

```bash
tailscale serve --bg --https=443 --set-path=/_matrix http://127.0.0.1:8008/_matrix
sleep 2
tailscale serve --bg --https=443 --set-path=/.well-known http://127.0.0.1:9111/.well-known
sleep 2
tailscale serve status   # make sure BOTH lines are present
```

Or run `scripts/serve-paths.sh` (it verifies for you).

**ACL note**: your tailnet policy must allow `tcp:443` from your phone to this
server (Tailscale denies by default). Until then, only the phone times out —
which is easy to miss because the server can see itself. Testing from the
server itself can also give false negatives, so verify from another tailnet
device.

---

## 4. Create accounts

**Element X can only log in, not register** (the in-app account-creation flow
targets servers with a managed authentication service). Create accounts via
the API with a registration token:

```bash
export REGISTRATION_TOKEN='the token you put in conduit.toml'
./scripts/create-account.sh https://matrix.example.ts.net you
# you will be asked for a password → use the same pair to log in on Element X
```

What it does is a single request:

```
POST /_matrix/client/v3/register
{"username": "you", "password": "...", "inhibit_login": true,
 "auth": {"type": "m.login.registration_token", "token": "..."}}
```

---

## 5. Log in with Element X (iPhone)

1. Install the Tailscale app (connected) and Element X on the iPhone
2. On the Element X sign-in screen choose "Sign in manually → Change account
   provider → Other" and enter `https://matrix.example.ts.net`
   (QR-code login requires Matrix Authentication Service and does not work
   with Conduit. You log in with username + password. Element X first checks
   for OIDC auth metadata and falls back to password login, so it goes through
   cleanly without MAS.)
3. Log in with the account from step 4
4. Create a room → invite the bot (after step 6)
5. Right after login you will be offered recovery keys and device
   verification — if you are not using encrypted rooms, you can skip all of it

**Phone-side notes (iPhone)**: enable Tailscale's MagicDNS. iCloud Private
Relay / "Limit IP Address Tracking" on Wi-Fi intermittently breaks `*.ts.net`
connections (a known issue) — turn it off on that Wi-Fi. Always-on VPNs and
privacy browser extensions can also break `*.ts.net`; disable or exclude them.

**Do not encrypt these rooms** (the bot in this recipe cannot do E2EE — see
gotchas). Element X works fine with unencrypted rooms.

---

## 6. Add the AI bot (Hermes Agent)

The bot living in your chat room is implemented with the gateway feature of
[Hermes Agent](https://hermes-agent.nousresearch.com) (Nous Research). The
bot's brain is anything OpenAI-compatible — point it at a local LLM server
(via LiteLLM, for example) for a fully offline setup.

```bash
# 1) create the bot account
REGISTRATION_TOKEN=... ./scripts/create-account.sh https://matrix.example.ts.net bot

# 2) prepare the bot home and the environment file
mkdir -p ~/matrix-bot-home
cp scripts/matrix.env.example ~/matrix-bot-home/.env
chmod 600 ~/matrix-bot-home/.env
#   MATRIX_HOMESERVER=http://127.0.0.1:8008
#   MATRIX_USER_ID=@bot:matrix.example.ts.net
#   MATRIX_PASSWORD=...
#   MATRIX_DEVICE_ID=botdev01          ← keep it fixed (avoids ghost devices)
#   MATRIX_ALLOWED_USERS=@you:matrix.example.ts.net
#   MATRIX_HOME_ROOM=!…:…              ← the bot's home room
#   MATRIX_E2EE_MODE=optional
#   OPENAI_BASE_URL / OPENAI_API_KEY   ← the brain (anything OpenAI-compatible)

# 3) register with launchd (edit the plist template to match your paths)
cp scripts/com.example.matrix-bot.plist.example \
   ~/Library/LaunchAgents/com.example.matrix-bot.plist
#   (set the hermes CLI path, WorkingDirectory and HERMES_HOME)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.matrix-bot.plist
```

Credentials are read from `$HERMES_HOME/.env` (never put secrets in the
plist). To verify, just DM the bot from Element X — a reply arrives in about
15 seconds depending on the brain.

---

## 7. Operations

### Watchdog

Run `scripts/matrix-watchdog.sh` every 5 minutes and it repairs whichever link
broke:

```
tailscaled → colima/Docker → container → 127.0.0.1:8008 → tailscale serve → bot process
```

- The same stage is repaired at most once per 10 minutes. After 3 consecutive
  failed repairs it stops trying and only alerts (pass a notification script
  via `ALERT_HOOK`).
- Stop: `touch .watchdog-stop` / dry run: `WD_DRY=1 ./matrix-watchdog.sh`

### Backup

`scripts/standby-backup.sh` — syncs the DB to another machine once a day.

- **Hot mode (macOS)**: rsync from an APFS local snapshot = the server never
  stops. RocksDB yields a consistent point-in-time copy from a snapshot.
- **Cold mode (fallback)**: `docker stop → rsync → docker start` (about a
  30-second outage; a trap guarantees recovery). On Linux use cold mode or
  rocksdb checkpoint.

### Common failures

| Symptom | Where to look |
|---|---|
| Only the phone cannot connect | tailnet ACL `tcp:443` permission |
| Bot goes silent (process alive) | `stopping sync` / `No adapter` markers in gateway.log → restart |
| Notifications never arrive | container outbound DNS (`colima --dns`) and push-gateway reachability |
| `/_matrix` returns 502 | check `serve status` for lost paths → re-run `serve-paths.sh` |

---

## 8. Notifications & privacy (measured)

- **Element X notifications on iOS** arrive through the push gateway operated
  by Element (Sygnal, on `matrix.org`) → Apple APNs. Running your own Sygnal
  requires a self-built app plus APNs keys, which is **not possible with the
  App Store version of Element X**. So if you want iOS notifications,
  notification metadata travels via Apple/Element — that is the trade-off
  (even with encrypted bodies, the fact that something arrived does pass
  through).
- **In unencrypted rooms the payload contains the message body.** In E2EE
  rooms the push payload only carries room_id and event_id (no body until
  decryption), but in plain rooms the room name, sender and body flow to APNs
  as-is. **Encrypt sensitive rooms or turn their notifications off.** This
  recipe's bot setup assumes plain rooms — mind what flows through
  notifications.
- Element X on Android can use UnifiedPush (self-hosted ntfy, etc.), so on
  Android even notifications can be fully self-hosted (iOS has the limits
  above).
- **How to test notifications**: Element X → Settings → Notifications →
  Troubleshooting → run **Test Push Gateway** / **Test Push Loop Back** and
  check **Push History**. If they fail, work through: ① container outbound
  DNS/HTTPS (`colima --dns 1.1.1.1`) ② toggle "Enable notifications on this
  device" off→on (works around a known bug where the pusher is not
  re-registered after logout→login) ③ device MagicDNS ④ Private Relay / VPN.
- **Delivery is two-stage** (the push gateway rings the bell → Element X
  fetches the body from the homeserver). The second stage rides Tailscale, so
  if Tailscale is down you get the sound but no body, or delays.

---

## 9. Gotchas (field-tested)

1. **server_name is forever.** Changing it invalidates every ID, room and
   history.
2. **E2EE kills the bot.** On macOS the bot-side crypto library (libolm) does
   not build. If a room gets `m.room.encryption`, the bot can no longer read
   it. Run plain rooms.
3. **Never run two homeservers with the same server_name at once** (split
   brain = the same account written into two databases, histories never
   reconcile). With a standby machine, always stop one before starting the
   other.
4. **Conduit v0.10.15 ignores `well_known_client`.** Discovery is the
   `/.well-known` of the hostname you typed (step 2). Nobody reads Conduit's
   own `8008/.well-known`, even if it returns an outdated name.
5. **The login response has no `well_known`.** The client keeps using the URL
   you typed, so a typo fails immediately at login.
6. **tailnet ACL.** A newly served port times out from the phone until the
   policy allows `tcp:443`. curl from the server itself can false-negative —
   verify from another device.
7. **tailscale serve entries can vanish on races.** Check `serve status` after
   every change and re-add what disappeared (the watchdog does this).
8. **Container DNS.** colima's default can leave outbound resolution broken,
   and then only notifications die silently (the push gateway is unreachable).
   `--dns 1.1.1.1` is recommended.
9. **You cannot create accounts from Element X.** Use the API + registration
   token (step 4).
10. **M_UNRECOGNIZED** usually means a client API version (`v3`) mismatch with
    the server. Conduit v0.10.15 supports v3 endpoints.
11. **QR-code login and calls do not work.** QR login (MSC4108) needs MAS;
    calls (Element Call) need a separately built LiveKit SFU. Adding coturn
    (TURN) does not fix Element X calls.
12. **Favourites (tags) and full-text search are silently dropped / unsupported
    on Conduit.** There are also reports of new room invites not showing up
    (sliding-sync related) and Element X taking minutes to catch up. Opening
    the room once usually makes it appear.
13. **Media cannot be purged** (no S3 either) — DB and media only grow. Watch
    your disk. If you raise `max_request_size` (default 20 MB), clients need a
    restart to pick it up.
14. **The registration token is a single static value** (just a config entry).
    If you need multiple expiring tokens, consider a fork (Continuwuity's
    admin-room tokens, for example).
15. **"Read but the unread badge never clears" is a known, unfixed upstream
    Conduit bug.** Element X learns read state via the sliding-sync receipts
    extension (MSC3960), but Conduit v0.10.15 returns an always-empty response
    (source-verified: `receipts.rooms` / `typing.rooms` are hardcoded empty in
    `sync.rs`). The receipt itself IS stored server-side, so no data is lost.
    The workaround is clearing the Element X cache (Settings → tap the version
    number 7 times → developer menu → Clear cache). **But cache clearing is
    temporary** — on our reference server it recurred within hours: one new
    message showed a 99+ badge, and 30 stuck entries remained even after
    clearing. **The permanent fix is migrating the server to Tuwunel** (which
    implements the receipts extension; the in-place Conduit DB import keeps
    accounts, rooms, history and logins; about 2 minutes of downtime). The
    verified procedure is in
    [`docs/migrate-conduit-to-tuwunel.md`](docs/migrate-conduit-to-tuwunel.md).

---

## 10. Standby machine (optional)

Sync the DB to another machine daily and a dead server comes back in minutes
(procedure and return steps: `docs/failover.md`). Keep the standby powered off
and, on failure, swap the DB in and boot it.

## 11. Long-term: Conduit's stalled development and the forks

Conduit's development is effectively a one-person project that has slowed down
(no media purge, no S3, slow features). The community has been moving to
forks:

- **Tuwunel** — officially supports migrating from Conduit (a verified
  migration kept every account and all content intact)
- **Continuwuity** — community fork of the conduwuit lineage (features Conduit
  lacks, like expiring registration tokens issued from an admin room)

If the current setup does not bother you, staying on Conduit is fine. When you
do migrate, **server_name and the DB backup carry over** (the documented
migrations kept everything), and the tailscale serve / well-known / bot sides
of this recipe should need no changes.

> Field note: we stood Tuwunel up on a side port and measured its receipts
> extension — sliding sync's `extensions.receipts` returns read data correctly
> (where Conduit v0.10.15 returns an always-empty map). After that we actually
> migrated from Conduit to Tuwunel — the unread-badge problem disappeared and
> even the cache-clear workaround became unnecessary. The full procedure is in
> [`docs/migrate-conduit-to-tuwunel.md`](docs/migrate-conduit-to-tuwunel.md).

---

## Credits

- [Conduit](https://conduit.rs) — the Matrix homeserver (Apache-2.0); settings
  verified against the [official docs](https://docs.conduit.rs/) and the
  [v0.10.15 source](https://gitlab.com/famedly/conduit)
- [Element X](https://element.io) — the client app; see the
  [requirements issue (element-meta#1915)](https://github.com/element-hq/element-meta/issues/1915)
  and the [native sliding sync announcement](https://matrix.org/blog/2024/11/14/moving-to-native-sliding-sync/)
- [Tailscale](https://tailscale.com) — networking (serve / ACL)
- [Hermes Agent](https://hermes-agent.nousresearch.com) — the bot gateway (Nous Research)
- Community knowledge: self-hosting threads on r/selfhosted and Hacker News,
  the [Tailscale × iCloud Private Relay issue](https://github.com/tailscale/tailscale/issues/21677),
  and the [Element X iOS pusher re-registration bug](https://github.com/element-hq/element-x-ios/issues/2602)

### Contributors

- **tenhkspark** — design, operations, field testing
- **local LLM fleet** — documentation review and translation review:
  GLM-5.3-Flash, Qwen3.8-Flash-Next, Nemotron 3.5 Lightning (all running
  on-premises)

## License

MIT — see [LICENSE](LICENSE)

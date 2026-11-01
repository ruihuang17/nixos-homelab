# iMessage Group Chat Digest

Status: **v1 implemented** — 2026-11-01. Scheduled digests, grounded event
alerts, Matrix + Discord delivery, SQLite state, a Prometheus heartbeat and
cloud digest synthesis are running on lime.

> **Resumed 2026-11-01 13:25.** The bridge's profile migration created duplicate
> portals; the live rooms were re-audited with `lime/digest/audit_portals.py`
> and remain `!ngLm…` (BLUNT) and `!rDOM…` (Blunt Wraps 2.0). `[service] paused`
> is false. The first live run polled 3 new Blunt Wraps 2.0 messages, sent 0
> alerts, and updated the heartbeat; the next scheduled digest is 18:00. The
> final digest uses OpenRouter Claude Haiku 5.5 on a zero-data-retention route;
> event detection stays on-device.

Goal: summarise a couple of iMessage group chats, deliver scheduled digests, and
push live alerts for concrete events, using Apple's on-device model where
possible.

See [[SMS Matrix Bridge]] for the bridge, [[lime (macOS)]] for the host, and
[[Monitoring]] / [[System Mail (Alerts)]] for the existing notification paths.

## At a glance

| Area | Decision | Why |
| ---- | -------- | --- |
| Rooms | **BLUNT WRAPS 🌯** `!ngLmKbjUJtXXLFjtZc:estrogenuinely.ca` and **Blunt Wraps 2.0** `!rDOMDGOdIIFzTKbtzm:estrogenuinely.ca` | Live portals after the 2026-11-01 migration; older duplicate portals are stale |
| Source of messages | Matrix portal rooms (mautrix-imessage) | No new Full Disk Access grant, no `chat.db` parser, bridge already normalises iMessage |
| Inference (alerts) | Apple on-device via `apfel` | Free, private, no request cap; verified `available: yes`, 8,192 tokens on lime |
| Inference (digest) | OpenRouter `anthropic/claude-haiku-5.5`, ZDR route | The 8k on-device model reversed who offered/asked; Claude Haiku is faster, cheaper on input/output than DeepSeek V4.1 Flash, and not a reasoning model |
| Trigger | launchd `StartInterval = 300` | macOS-native scheduler; no iMessage webhook exists |
| Delivery | Matrix `#imessage-digest` for digests; Discord DM for alerts | Digest is archived; Discord DM actually pushes to Takeko |
| Host | lime (service), satsuma (Synapse) | Model must run on the Mac; Matrix is already there |
| State | SQLite on lime | Cursors, dedupe, chunk notes, digest history |
| Secrets | agenix (`lime/secrets/imessage-digest.age`) | Matrix token, Hermes Discord bot token, OpenRouter key |

## What we are not doing

- **Reading `chat.db` in the live path.** The bridge already does it, and a new
  binary would need its own FDA grant and a stable cdhash —
  see [[lime (macOS)]] → *TCC grants that matter*. A one-off historical export
  is fine (`LembicKit`, `macos-messages-reader-skill`), but not the service.
- **BlueBubbles.** Removed 2026-10-31; it required SIP off and a permissive
  boot policy.
- **`fm serve` as the service backend.** Beta, no authentication, ignores
  `max_tokens`, and the `fm` CLI licence has a broad “no programmatic access
  except as expressly permitted” clause. Use `fm` for manual tests only.
- **A dedicated `@digestbot` for v1.** `@rhuang` is not a Synapse admin and the
  registration-shared-secret HMAC path rejected new users, so the service uses
  a dedicated long-lived `@rhuang` device token (`iMessage Digest`). It only
  reads the two portal rooms and writes to `#imessage-digest`, so it never
  relays anything into iMessage. This also sidesteps the bot-relay caveat.
- **Per-message inference.** Batch and debounce; model calls are the expensive
  part (in latency, quota, and noise).

## Data source: Matrix

The iMessage bridge is configured `platform: mac` and its portal rooms are
**unencrypted** — checked 2026-10-31:

```sh
grep -A6 '^ *encryption:' /run/agenix/imessage-config
# allow: false / default: false / require: false
```

So a plain Matrix client can read them.

### Room discovery

Selected on 2026-11-01:

| Chat | Portal room |
| ---- | ----------- |
| BLUNT WRAPS 🌯 | `!ngLmKbjUJtXXLFjtZc:estrogenuinely.ca` (live; guid `any;+;chat123…`) |
| Blunt Wraps 2.0 | `!rDOMDGOdIIFzTKbtzm:estrogenuinely.ca` (live; guid `any;+;77cbc…`) |

**Duplicate portals (2026-11-01 profile migration).** The bridge created
~1,853 portal rows; after cleanup it was ~1,357 at 13:25, with several rows per
chat name (`iMessage;+;chat860…`, `any;+;chat860…`, `RCS;+;chat598…`,
`any;+;77cbc…`). The live portal is the one with the newest
`origin_server_ts` and ghost traffic; the older rows stopped when the profile
was rebuilt. The table above was audited at 13:25 on 2026-11-01. Re-audit after
any bridge migration:

```sh
sqlite3 ~/mautrix-imessage/mautrix-imessage.db \
  "select mxid, name from portal where name like '%BLUNT%' or name like '%Blunt%';"
# for each room, compare /messages?dir=b&limit=200:
#   number of senders, ghosts, last origin_server_ts, messages in the last 24 h
```

Do not select a portal by name alone — that is how the first digest ended up
reading the stale `RCS;+;chat598…` duplicate.

The service reads with a dedicated `@rhuang` device token (`iMessage Digest`),
stored in `lime/secrets/imessage-digest.age`. The digest room is
`!m6_R299IGBbrqGIlKwEd-jGJZ1W-eYVXd-BOstrIyo0` (alias
`#imessage-digest:estrogenuinely.ca`); note that rooms created on this Synapse
return their ID **without** the `:server` suffix.

Useful discovery commands (still valid):

```sh
curl -s -H "Authorization: Bearer $TOKEN" \
  https://matrix.local.estrogenuinely.ca/_matrix/client/v3/joined_rooms \
  | jq -r '.joined_rooms[]'

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://matrix.local.estrogenuinely.ca/_matrix/client/v3/rooms/$ROOM/state/m.room.name" \
  | jq -r .name
```

`matrix.local.estrogenuinely.ca` is the LAN vhost for Synapse (see
[[SMS Matrix Bridge]]); it avoids hairpin NAT but **cannot be used by the
launchd agent** because of macOS Local Network Privacy (see *Known limits*).
The service uses `https://matrix.estrogenuinely.ca`.

**Bot caveat (resolved):** a bot would relay Matrix messages into iMessage
depending on `bridge.permissions`, so the service reads with a read-only
`@rhuang` device token instead. Its only write is to `#imessage-digest`; it
never sends into a portal room. If a bot is added later, send one test message
inside a portal first and confirm it does *not* appear in iMessage.

### History

The bridge only backfills **100 messages / 12 hours per new portal**
(`initial_limit`, `initial_sync_max_age` in the iMessage config). That is enough
for “from now on”. For a retrospective digest, export the chat once from
`chat.db` and feed the same chunker; do not make that part of the service.

## Model options

| Option | Context | Cost | Privacy | Automation |
| ------ | ------- | ---- | ------- | ---------- |
| Apple on-device (AFM 3 Core Advanced on this M4/16 GB) | ~8k | free | never leaves lime | `apfel`, official Python SDK, or a signed app |
| Apple Private Cloud Compute (PCC) | ~32k | quota | leaves lime; Apple says not stored | Shortcuts `Use Model → Cloud`; custom apps need the `com.apple.developer.private-cloud-compute` entitlement |
| OpenRouter `:free` | 65k–1M | $0 | provider may retain/train on prompts | any OpenAI client; 20 req/min, 50 req/day (1,000/day after $10 lifetime credits) |
| OpenRouter paid / ZDR | model-dependent | pennies for this workload | no-training providers available | same |

Notes:

- On macOS 27 with an M3+ and ≥12 GB, `SystemLanguageModel` selects **AFM 3 Core
  Advanced** (20B sparse, 1–4B active) and reports **8,192 tokens**. Verify with
  `apfel --model-info`; Apple's docs still say 4,096.
- PCC is **not** a general API. `fm --model pcc` is macOS 27.2+ and
  Terminal-hosted; `fm serve` with PCC only works when started from Terminal.app.
  A custom service needs an Apple-managed entitlement.
- Free OpenRouter is for the **prototype**, not the pipeline. The catalog
  changes monthly, free endpoints may train on prompts, and failed requests
  count against the daily cap.
- Recommendation: **on-device for the always-on watcher, cloud only for the
  daily synthesis** (PCC via Shortcuts, or a paid no-training OpenRouter model).
  That keeps every message local and limits cloud exposure to one transcript a
  day.

## Architecture

```
iMessage group chats
        │
        │  mautrix-imessage (already running on lime)
        ▼
Synapse portal rooms  ──HTTP /messages──▶  digest service (launchd, lime)
                                              │
                                              │  chunk → notes → roll-up
                                              ▼
                                     Apple Foundation Models
                                     (on-device, ~8k)
                                              │
                        ┌─────────────────────┴─────────────────────┐
                        ▼                                           ▼
              Matrix #imessage-digest                     HA notify / Discord DM
              (archive + digests)                         (live event alerts)
```

## How a digest is built

1. Fetch new events since the SQLite cursor; normalise to
   `[2026-10-30 14:02] Alice: …`.
2. Count tokens (`apfel --count-tokens` to calibrate once). Split at message
   boundaries into chunks of ~4,000–4,500 tokens; leave ~1,200 for the answer.
3. Per chunk, ask for a small note: topics, decisions, concrete events, requests
   aimed at me, open questions. Only facts present in the transcript; include
   speaker and time.
4. Reduce notes recursively until they fit ~3,500 tokens, then ask for the final
   digest.
5. Keep a rolling 7-day “state” note per room so the next digest has continuity
   without replaying history.

Prompt rules that matter with a small model:

- “Use only the messages below. Do not infer or add world knowledge.”
- “Ignore greetings, jokes, links, and reactions.”
- “For every item give the speaker and time.”
- “If nothing qualifies, return empty lists.”
- Inject today's date and `America/Toronto`; the model has no clock.

### Event detection

Ask for a schema-constrained object rather than free text:

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["has_event", "events"],
  "properties": {
    "has_event": { "type": "boolean" },
    "events": {
      "type": "array",
      "maxItems": 3,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["kind","summary","when","needs_action","quote","confidence"],
        "properties": {
          "kind": { "type": "string", "enum": ["plan","deadline","money","travel","health","conflict","request","other"] },
          "summary": { "type": "string" },
          "when": { "type": "string" },
          "needs_action": { "type": "boolean" },
          "quote": { "type": "string" },
          "confidence": { "type": "number" }
        }
      }
    }
  }
}
```

Enforce in code:

- **Grounding:** the `quote` must be an actual substring of the transcript
  (normalised whitespace/case). This kills most hallucinations.
- **Confidence:** only alert at ≥ 0.7.
- **Dedupe:** hash `room + normalised(summary) + when`; suppress repeats for
  7 days.
- **Rate limit:** max 3 alerts/room/day; quiet hours 23:00–07:00 except
  high-confidence `needs_action`.
- **Debounce:** wait 60–90 s after the last message so “ok” / “lol” bursts do not
  trigger.

Alert format:

```
⚠️ Cabin trip — Sat 19:00
Dinner at Alice's; bring chairs.
"Can everyone bring a chair Saturday at 7?" — Bob, 14:02
https://matrix.to/#/!room:server/$event
```

The permalink is important: one tap opens the surrounding conversation.

## Triggering: launchd, not cron; no iMessage hooks

iMessage has **no webhook** — no supported “new message” callback. The bridge is
the closest thing to a hook, and it hands us Matrix events.

| Trigger | Mechanism | Latency | Complexity | Use |
| ------- | --------- | ------- | ---------- | --- |
| launchd calendar | `StartCalendarInterval` | exact | low | digests at 08:00 / 18:00 |
| launchd interval | `StartInterval = 300` | ≤ 5 min | low | **v1: all event alerts** |
| launchd daemon | `KeepAlive` + Matrix `/sync?timeout=30000` | seconds | medium | v2 if 5 min is too slow |
| launchd `WatchPaths` | watch `~/Library/Messages/chat.db-wal` | seconds | medium | local hook; needs FDA |
| Synapse module | `on_new_event` → HTTP POST | sub-second | high | true webhook; runs inside Synapse |
| Shortcuts automation | time of day / message received (if available) | varies | low | PCC-friendly, no daemon |

**v1:** one-shot every 5 minutes, with a lock file so runs cannot overlap. It
fetches new events, runs event detection, posts alerts, and exits. Digests run
when the script sees a configured time slot (or via a second launchd job).

```nix
imessage-digest = {
  command = "${pkgs.python3}/bin/python3 ${./digest/main.py} --once";
  serviceConfig = {
    Label = "ca.estrogenuinely.imessage-digest";
    StartInterval = 300;
    RunAtLoad = true;
    LimitLoadToSessionType = "Aqua";
    StandardOutPath = "${logs}/imessage-digest.log";
    StandardErrorPath = "${logs}/imessage-digest.err.log";
  };
};
```

**v2:** switch to a `KeepAlive` daemon that long-polls Matrix `/sync`, or add a
Synapse module if sub-second latency is required. Keep the same batching and
dedupe logic either way.

LaunchAgents only run in an active user session; `StartInterval` jobs do not fire
while the Mac is asleep. lime never sleeps and auto-login is on, so this works —
but it is another reason to keep FileVault off, and why the heartbeat metric
matters.

## Delivery

| Channel | Use | Caveat |
| ------- | --- | ------ |
| Matrix `#imessage-digest` | archive + scheduled digests | There is no Sygnal/ntfy in the docs; verify Element actually pushes from a new room |
| Home Assistant companion | live event alerts | Best push path; needs a long-lived token and `notify.mobile_app_*` service |
| Discord DM | fallback alerts | Bot token and user IDs already exist for Hermes |
| Email | weekly rollup | Reliable, not “live”; reuse the `homelab-svc` path |

Recommended: **digests → Matrix; event alerts → HA push (or Discord DM).**

## Build phases

| Phase | Work | Output |
| ----- | ---- | ------ |
| 0 | macOS 27 upgrade + verify bridge/Jellyfin/nix-darwin | see runbook below |
| 1 | Shortcuts probe, or a one-file Python spike against one room | know whether on-device quality is good enough |
| 2 | Service skeleton: Matrix read, SQLite, chunker, digest, launchd, agenix | scheduled digest |
| 3 | Event schema, grounding, dedupe, quiet hours, HA/Discord | live alerts |
| 4 | Heartbeat metric, Grafana stale alert, log hygiene, retention | observable service |
| 5 | Optional: `chat.db` backfill, image/voice notes, calendar holds | extras |

### Layout

```
lime/digest/
  default.nix          # nix-darwin: launchd agent + agenix secret
  main.py              # scheduler + one-shot loop
  matrix.py            # /messages, /send
  model.py             # apfel subprocess + exit-code handling
  chunk.py             # token-aware chunking + tree reduce
  state.py             # SQLite
  deliver.py           # Matrix / HA / Discord
  prompts/{chunk,digest,event}.md
  schemas/event.json
  config.yaml
lime/secrets/imessage-digest.age
```

No pip dependencies: Python stdlib (`urllib`, `sqlite3`, `json`, `subprocess`)
is enough; `apfel` comes from Homebrew. Add `apfel` to `lime/homebrew.nix`.

Heartbeat: write
`imessage_digest_last_success_timestamp_seconds` to a `.prom` file, point
node_exporter's textfile collector at it, and add a Grafana rule “digest stale
> 2 h”. That catches “silently stopped” — the most likely failure.

## macOS 27 upgrade runbook

State on 2026-10-31:

| Item | Value |
| ---- | ----- |
| Current OS | macOS 15.7.7 (24G720), Darwin 24.6.0 |
| Available | **macOS 27.2 (26B123)**, 12.6 GB, restart required |
| Hardware | Mac mini `Mac16,10`, M4, 16 GB |
| Disk | 228 GB total, 121 GB available |
| SIP | enabled |
| FileVault | **off** (auto-login depends on this) |
| Auto-login | `rhuang` |
| Volume owners | `rhuang`, `temp` (`diskutil apfs listCryptoUsers /`) |
| MDM / bootstrap token | none (`profiles status -type enrollment` → No) |
| Sleep | disabled (`sleep 0`, `disksleep 0`) |
| Running | `fi.mau.mautrix-imessage`, Jellyfin, `sh.brew.node_exporter` |

### Before installing

1. Copy the critical files to satsuma (there is no Time Machine on lime):

   ```sh
   mkdir -p /hdd/backup/lime-pre-macos27-20261031
   rsync -a --info=progress2 -e "ssh -i /root/.ssh/general" \
     rhuang@10.0.10.73:/Users/rhuang/mautrix-imessage/ \
     /hdd/backup/lime-pre-macos27-20261031/mautrix-imessage/
   rsync -a --info=progress2 -e "ssh -i /root/.ssh/general" \
     rhuang@10.0.10.73:/Users/rhuang/nixos-homelab/ \
     /hdd/backup/lime-pre-macos27-20261031/nixos-homelab/
   rsync -a --info=progress2 -e "ssh -i /root/.ssh/general" \
     rhuang@10.0.10.73:/Users/rhuang/Library/Messages/chat.db* \
     /hdd/backup/lime-pre-macos27-20261031/Messages/
   ```

2. Record the inventory (launchctl list, `brew list`, `sw_vers`).
3. Tell the household: Jellyfin and iMessage bridging will be down for roughly
   30–60 minutes, possibly across two reboots.
4. Be at a screen or have Screen Sharing available. A major upgrade can land on
   Setup Assistant, Apple ID, or an Apple Intelligence prompt that SSH cannot
   complete.

### Install

```sh
ssh -i /root/.ssh/general rhuang@10.0.10.73
sudo softwareupdate -d "macOS 27.2-26B123"     # download only
```

**Apple Silicon requires a volume-owner password.** `sudo` alone is not enough:
`softwareupdate -i` fails with `Failed to authenticate` because
`installerauthagent` wants the console user's password (LocalAuthentication),
and an MDM/bootstrap-token path is not available on this Mac
(`profiles status -type enrollment` → not enrolled). `installerauthagent` cannot
be satisfied over a non-interactive SSH session.

Use the full installer with an interactive password prompt instead:

```sh
sudo softwareupdate --fetch-full-installer --full-installer-version 27.2
sudo "/Applications/Install macOS 27 Golden Gate.app/Contents/Resources/startosinstall" \
  --agreetolicense --reboot --user rhuang --passprompt
```

The update is already staged (`/System/Volumes/Update`), so the full installer is
mostly a second copy. Delete the installer app afterwards to reclaim ~17 GB.

Do not interrupt the reboot. The Mac will disappear from SSH during the install.

### After the reboot

```sh
sw_vers
csrutil status
sudo bputil -d | grep -iE 'security mode|sip status'
launchctl list | grep -Ei 'mautrix|jellyfin|node_exporter'
lsof -p $(pgrep -f mautrix-imessage/mautrix-imessage) | grep chat.db
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8096/health
grep "Received incoming message" ~/mautrix-imessage/logs/mautrix-imessage.log | tail -1
```

Then, when the flake has been updated:

```sh
cd ~/nixos-homelab && git pull
sudo darwin-rebuild switch --flake ~/nixos-homelab#lime
```

### Apple Intelligence

1. Sign in with the Apple Account if prompted.
2. System Settings → Siri (macOS 27 calls the pane “Siri”): enable Apple
   Intelligence; set **device language and Siri language to the same supported
   language**.
3. Wait for the model download (`fm available` after `sudo fm license`, or
   `apfel --model-info`).
4. Verify the 8k variant/context on this M4/16 GB.
5. Keep SIP on and FileVault off.

### Result (2026-11-01)

The upgrade succeeded: **macOS 27.2 (26B123)**, SIP enabled, Full security
policy, Homebrew now resolving `packages.arm64_golden_gate`. `sudo
darwin-rebuild switch --flake ~/nixos-homelab#lime` completes and the Homebrew
bundle adopts cleanly.

**Recovery sequence that worked:**

1. Auto-login was wedged after the upgrade: `autoLoginUser` was still set, but
   the login never completed, so `Installer Progress` sat at **55% of the
   “loginwindow Boot” phase** (overall 65%) behind a full-screen shield.
   `softwareupdate -i` was not involved any more; the OS was already 27.2.
2. `sudo sysadminctl -autologin off` removed the wedged auto-login. The next
   boot let `Installer Progress` reach 100% and exit; the login window appeared.
3. The first manual login launched **Setup Assistant** (the “Liquid Glass”
   setup), which hung. `killall "Setup Assistant"` logged the session out.
4. Clearing `AccountInfo.FirstLogins.rhuang` (PlistBuddy) stopped Setup Assistant
   from relaunching. The next login produced a normal desktop: `Finder`, `Dock`,
   all three LaunchAgents, Jellyfin `200`, node_exporter `200`, and `chat.db`
   open.
5. `temp` (uid 501, admin, volume owner) was deleted with
   `sudo sysadminctl -deleteUser temp`; its home is backed up at
   `/hdd/backup/lime-pre-macos27-20261031/temp-home.tar.gz`. Only `rhuang`
   remains a volume owner (`diskutil apfs listCryptoUsers /`).

**Auto-login was re-enabled** at 01:50 with the volume-owner password and
reboot-tested at 01:51. The Mac came back on its own: console user `rhuang`,
`Finder`/`Dock` running, all three LaunchAgents, Jellyfin/node_exporter `200`,
`chat.db` open, no Setup Assistant or Installer Progress, and `temp` gone.
It was **disabled again** for the keychain reset later that night; see
*Keychain reset / Apple Account blocker* below.
Keep the command for future use:

```sh
read -s -p "macOS password: " PW
sudo sysadminctl -autologin set -userName rhuang -password "$PW"
unset PW
sudo sysadminctl -autologin status
```

The wallpaper `SystemWallpaperURL` now points at `Sonoma Horizon.heic` and
persists across reboot; desktop widget visibility keys are
`StandardHideWidgets = 0` / `StageManagerHideWidgets = 0`.

### Post-login cosmetics (2026-11-01)

- **Black desktop:** the wallpaper store pointed at
  `/System/Library/Desktop Pictures/.wallpapers/Sequoia Sunrise/Sequoia Sunrise.mov`,
  which macOS 27 no longer ships. Point
  `com.apple.wallpaper SystemWallpaperURL` at the existing
  `Sonoma Horizon.heic` and restart `WallpaperAgent`, or pick a wallpaper in
  System Settings. macOS 27 ships `.madesktop` bundles under
  `/System/Library/Desktop Pictures`.
- **Desktop widgets:** `chronod`, `NotificationCenter`, and the widget
  extensions are running, and `StandardHideWidgets = 0`. If the layout is empty,
  re-add widgets from the desktop's “Edit Widgets”; the upgrade does not restore
  a custom layout.
- **Stale `temp` login tile:** the account is gone (`id temp` fails,
  `diskutil apfs listCryptoUsers /` has only `rhuang`), but the running
  `loginwindow` cached the old user list. A logout/reboot clears the tile.

The bridge's FDA grant survived the upgrade (`lsof` shows `chat.db`), and
`/run/agenix/imessage-config` is recreated at boot. The node_exporter `thermal`
collector error (`no CPU power status has been recorded`) is pre-existing and
harmless.

### Keychain reset / Apple Account blocker (2026-11-01 01:45)

The login keychain was reset after repeated unlock failures:

- new `login.keychain-db` created at 01:17; `security show-keychain-info`
  (via `launchctl asuser 1000`) reports `no-timeout`.
- old keychains preserved as `login_renamed_1.keychain-db` (Jul 24) and
  `login_renamed_2.keychain-db` (Nov 1 01:05).
- the whole `~/Library/Keychains` directory is backed up at
  `/hdd/backup/lime-pre-macos27-20261031/keychains-20261101`.

It did **not** fix Apple Intelligence. The remaining blocker is the Apple
Account AuthKit state, not the local keychain:

- `akd`: `SecKeyCreateSignature failed ... unable to sign digest`
  (`AKSError=-536870174`).
- `accountsd`: `Silent renewal failed!` (`AKAuthenticationError -7013/-7065`),
  `Credential data is currently unavailable`.
- `FeatureAccessAgent`: `auth tokens are not available`, and
  `Bag did not contain path for key: acseGatewayURL`.
- The Passwords app (iCloud Keychain) does not unlock with the Mac login
  password, and the Apple Account password is not known to work either.
- A stuck “Signing Out…” was cancelled by quitting System Settings; the
  AppleAccount and CloudKit accounts are still present.

The Passwords app also showed a saved “Apple China” account. If the Apple
Account region is China mainland, Apple Intelligence is not available there at
all. Do not change the Mac login password for this; it needs the Apple Account
credential or an account-region change.

Consequences:

- The Apple Intelligence/Siri AI opt-in UI is absent, so `fm`/`apfel` cannot
  use the model. `apfel --model-info` reports context **8192** but
  `available: no`.
- For the digest, fall back to OpenRouter/Hermes until the Apple Account is
  repaired.
- **Auto-login is OFF** (disabled for the keychain reset). Re-enable it with the
  Mac login password, not the Apple Account password:

  ```sh
  read -s -p "Mac login password: " PW
  sudo sysadminctl -autologin set -userName rhuang -password "$PW"
  unset PW
  sudo sysadminctl -autologin status
  ```

- Wallpaper: the store was reset and `desktoppr` hangs on 27.2. Pick one in
  System Settings → Wallpaper. The old store is at
  `/hdd/backup/lime-pre-macos27-20261031/wallpaper-store-20261101`.

### Risks / rollback

- This is a two-major-version jump with no full-system backup. The file-level
  backup above covers the bridge, its DB, the flake checkout, and message
  history; Jellyfin is reinstallable.
- The mautrix binary is built against older Homebrew libraries. If it fails to
  start, check `~/mautrix-imessage/logs/stderr.log` and rebuild/reinstall the
  matching libs. Its FDA grant is cdhash-bound: do **not** move or rebuild it
  unless prepared to re-grant.
- nix-darwin and Homebrew may need a flake update / `brew update` for 27. Test
  `darwin-rebuild` before relying on it.
- There is no clean rollback from 27 to 15. A restore means erase/reinstall.
- If auto-login or SSH does not come back, physical access is required.

## Implementation (2026-11-01)

### What runs

| Piece | Detail |
| ----- | ------ |
| launchd agent | `ca.estrogenuinely.imessage-digest`, `StartInterval = 300`, `RunAtLoad` |
| Entry point | `lime/digest/main.py --once`, Python 3.14 from nixpkgs (stdlib only) |
| Source | Matrix `/rooms/{id}/messages` on `https://matrix.estrogenuinely.ca` |
| Alerts / notes | `/opt/homebrew/bin/apfel` (Apple Foundation Models, 8,192 tokens) |
| Digest synthesis | OpenRouter `anthropic/claude-haiku-5.5` on a ZDR route (one transcript per digest) |
| Digest room | `#imessage-digest:estrogenuinely.ca` (`!m6_R299…`, no server suffix) |
| Alerts | Discord DM to Takeko (`454892601175441418`) via the Hermes bot |
| State | `~/Library/Application Support/imessage-digest/state.sqlite3` |
| Heartbeat | `…/textfile/imessage_digest.prom`, read by node_exporter |
| Secret | `lime/secrets/imessage-digest.age` → `/run/agenix/imessage-digest` (Matrix, Discord, OpenRouter) |
| Running | `[service] paused = false`; five-minute poll, alerts and scheduled digests |

### Flow

1. Every five minutes: poll each portal room backwards from its last stored
   timestamp; normalise `m.text`/`m.emote`, drop edits, notices, bridge-bot
   messages and reply fallbacks; insert into SQLite (`event_id` dedupe).
2. Alert pass: wait 90 s after the last message (debounce), skip messages older
   than 120 min (first run / long sleep), chunk to ~2,200 tokens, ask for the
   event schema, and enforce:
   - `quote` is a normalised substring of a real message body (grounding);
   - confidence ≥ 0.70;
   - `needs_action` is ignored unless `kind` is request/deadline/money;
   - messages authored by Rui are never "requests for Rui";
   - dedupe `room + summary + when` for 7 days;
   - ≤ 3 alerts per room per local day;
   - quiet 23:00–07:00 unless a `needs_action` request is ≥ 0.90.
3. Digest pass at 08:00 and 18:00 local (catch-up up to 6 h): send the raw
   transcript (up to 60k tokens) to OpenRouter Claude Haiku 5.5. Above that,
   take on-device chunk notes and tree-reduce them first. The model returns a
   schema-constrained object; code renders the sections, removes cross-section
   duplicates, and grounds each item back to a source message to restore its
   timestamp and speaker. Only this final call leaves lime.
4. Write the heartbeat metric, prune messages after 14 days and alert dedupe
   after 7 days.

### Files

```
lime/digest/
  default.nix          # launchd agent, agenix secret, state dir
  config.toml          # rooms, schedule, thresholds, paths
  main.py              # poll → events → digest → heartbeat
  matrix.py            # /messages, /joined_members, /send
  model.py             # apfel subprocess, schema output, token counting
  cloud.py             # OpenRouter client for the final digest
  audit_portals.py     # find the live portal among duplicate rooms
  chunk.py             # formatting, token-aware chunks, tree reduce
  state.py             # SQLite
  deliver.py           # Matrix digest render + Discord DM alerts
  prompts/{chunk,digest,event,reduce}.md
  schemas/{event,digest}.json
lime/secrets/imessage-digest.age
```

`lime/agents.nix` now starts node_exporter with
`--collector.textfile.directory=…/imessage-digest/textfile`; `lime/homebrew.nix`
lists `apfel`.

### Operating it

**The service is running.** To pause it, set `[service] paused = true` and
rebuild; the agent will only write the heartbeat. After a bridge migration,
re-audit and resume with:

```sh
cd ~/nixos-homelab/lime/digest
# 1. list every portal with the configured names; the newest is marked "likely live"
nix run nixpkgs#python3 -- audit_portals.py \
  --config config.toml --secrets /run/agenix/imessage-digest
# 2. update the [[rooms]] IDs in config.toml
# 3. set [service] paused = false
# 4. sudo darwin-rebuild switch --flake ~/nixos-homelab#lime
# 5. inspect a dry digest before the next scheduled slot
nix run nixpkgs#python3 -- main.py --once --dry-run --digest \
  --secrets /run/agenix/imessage-digest
```

Normal commands:

```sh
# one dry pass: poll, scan alerts (printed), do not send anything
cd ~/nixos-homelab/lime/digest
nix run nixpkgs#python3 -- main.py --once --dry-run \
  --secrets /run/agenix/imessage-digest

# force a digest now (posts to #imessage-digest)
nix run nixpkgs#python3 -- main.py --once --digest \
  --secrets /run/agenix/imessage-digest

# inspect the agent and logs
launchctl print gui/502/ca.estrogenuinely.imessage-digest
tail -f ~/Library/Logs/imessage-digest.err.log
cat "$HOME/Library/Application Support/imessage-digest/textfile/imessage_digest.prom"
```

The dry-run `--digest` above uses the real OpenRouter key, so it exercises the
cloud path without posting or advancing the digest cursor.

`--events` ignores debounce/quiet/age for alert debugging; `--skip-poll` uses
only stored messages. A dry run does not mark alerts processed or advance the
digest cursor; the poll cursor still advances, but messages stay in SQLite for
the next real run. The service holds `run.lock`, so a manual run cannot overlap
a launchd run.

Re-encrypt the secret after rotating the Matrix device, the Discord token, or
the OpenRouter key:

```sh
cd /etc/nixos/lime/secrets
agenix -e imessage-digest.age -i ~/.ssh/general
```

### Verified

- Dry runs polled 18 messages from BLUNT WRAPS and 108 from the old Blunt Wraps
  2.0 duplicate. After the portal audit, the live `!rDOM…` room has 92 messages
  in the current window.
- The first digest exposed a stale duplicate-portal selection for Blunt Wraps
  2.0; the live portal is now pinned in `config.toml`.
- Grounding rejected an ungrounded event, self-authored Costco/Minecraft offers,
  and stale overnight alerts.
- A cloud smoke test extracted “Alice asked Rui to send the login” without
  reversing Rui's offer of an extra account.
- The first live run after resuming (13:25) polled 3 new Blunt Wraps 2.0
  messages, found 0 events, sent 0 alerts, and wrote `paused 0` /
  `last_run_success 1`.
- The first real digest posted both rooms to `#imessage-digest`; the test DM
  reached the Hermes bot's DM channel with Takeko.

### Known limits

- **macOS Local Network Privacy.** The launchd Aqua agent runs an unsigned
  nixpkgs Python, and macOS refuses its LAN socket with `OSError(65, 'No route
  to host')`. `curl` and an interactive/SSH Python process are allowed, so this
  is a TCC/Local Network restriction, not DNS. The service therefore uses the
  public vhost `https://matrix.estrogenuinely.ca` (hairpin NAT from lime is
  verified, and mautrix uses the same address). If hairpin ever breaks, replace
  the Matrix transport with `/usr/bin/curl` rather than re-enabling the LAN
  hostname.
- **Duplicate portals after a bridge migration.** The 2026-11-01 profile
  rebuild initially left ~1,853 portal rows (down to ~1,357 at 13:25) with
  several rows per chat name. The digest config pins the live portal IDs; a
  name-based lookup is not safe. Re-audit after any bridge rebuild with
  `audit_portals.py`. See *Room discovery*.
- **Bridge wsproxy (fixed 2026-11-01).** The unsigned bridge cannot open the
  LAN socket under macOS Local Network Privacy, while Apple-signed
  `/usr/bin/ssh` can. `lime/agents.nix` now runs
  `ssh -N -L 127.0.0.1:29331:127.0.0.1:29331 rhuang@10.0.10.72` as
  `ca.estrogenuinely.wsproxy-tunnel`, and the bridge's `websocket_proxy` is
  `ws://127.0.0.1:29331`. The wsproxy logs `imessage connected to websocket`;
  traffic stays on the LAN and the wsproxy is not exposed publicly. If the
  tunnel dies, check `~/Library/Logs/wsproxy-tunnel.err.log`.
- **Cloud privacy.** The final digest goes to OpenRouter Claude Haiku 5.5 on a
  zero-data-retention route (`data_collection = "deny"`, `zdr = true`); one
  transcript per scheduled digest leaves lime. Event detection and large-window
  chunk notes remain on-device. At ~4k input + ~1.3k output tokens, a digest
  costs roughly $0.001; two per day is about $0.06/month. If that trade is
  unacceptable, switch `[synthesis] provider` off and accept the weaker
  on-device summary.
- The on-device model is still used for alerts and can misread roles. Grounding,
  confidence, daily caps and quiet hours reduce alert noise.
- “Requests for Rui” is heuristic: self-authored items and asks aimed at another
  named member are dropped, but a group ask can still slip through.
- Matrix posts are plain text (Markdown headings show literally in some
  clients); Discord alerts are plain text.
- Windows larger than ~4,200 tokens use chunk notes + tree reduce; that path is
  implemented but not yet exercised by a full day of heavy traffic.
- The service posts as `@rhuang`, not a bot. Revoking the `iMessage Digest`
  device logs the service out; mint a new token and re-encrypt the secret.
- No historical backfill. The first run looks back 24 h; earlier history stays
  only in `chat.db` and the bridge DB.

### Next

1. Watch for bridge portal churn; re-audit the live rooms if a chat goes quiet.
2. Small Grafana dashboard for the digest metrics (the stale > 2 h rule is
   provisioned as `homelab-imessage-digest-stale`).
3. Send HTML (`org.matrix.custom.html`) so headings render, or drop Markdown.
4. Improve large-window chunk notes and request targeting; consider reply
   relations to identify what was aimed at Rui.
5. Optional: historical export from `chat.db`, image/voice-note summaries,
   calendar holds, and the duplicate portal cleanup.

Phases 0–3 are done; phase 4 is done except log rotation and a dashboard; phase
5 is not started. The service is running with the audited live portal IDs.

## Decisions (resolved 2026-11-01)

| Question | Answer |
| -------- | ------ |
| Group chats | BLUNT WRAPS 🌯 and Blunt Wraps 2.0 |
| What is an “event” | Plans/deadlines, money, travel, health, conflict, and requests aimed at Rui; schema + grounding + confidence gate |
| Alert channel | Discord DM to Takeko |
| Digest cadence | 08:00 and 18:00 America/Toronto, 6 h catch-up |
| Live path | 5-minute one-shot launchd job with a lock (`v1`); `/sync` daemon remains `v2` |
| Historical backfill | None; first run looks back 24 h |
| Inference | On-device `apfel` for alerts and notes; OpenRouter for the final digest |

Remaining open questions are implementation polish, not design choices: request
targeting, HTML rendering, large-window note quality, log rotation, and the
duplicate portal cleanup.

## References

- Apple Foundation Models: <https://developer.apple.com/foundation-models-framework/>
- `fm` CLI / Python SDK (WWDC26): <https://developer.apple.com/videos/play/wwdc2026/334/>
- Context window: <https://developer.apple.com/documentation/Technotes/tn3193-managing-the-on-device-foundation-model-s-context-window>
- `apfel`: <https://github.com/Arthur-Ficial/apfel>
- Apple Intelligence requirements: <https://support.apple.com/en-us/121115>
- OpenRouter free-model limits: <https://openrouter.ai/docs/api_reference/limits>
- mautrix-imessage: <https://docs.mau.fi/bridges/go/imessage/index.html>

## Update: 2026-11-01 profile rebuild

The earlier Apple Account/region notes above are historical and were a false
lead: the account was valid all along. The problem was the old `rhuang` local
profile (keychain/Secure Enclave credential could not be unlocked with the Mac
login password). The repair-in-place attempt was abandoned.

A fresh `rhuang` profile was created and verified:

- UID **502** (the old profile was UID 1000), home `/Users/rhuang`, Secure
  Token enabled, volume owner, admin groups, passwordless sudo and SSH.
- Apple Account signed in; iCloud Drive is syncing; iMessage has a 19 MB
  `chat.db` with 8,619 messages.
- `apfel --model-info` reports `available: yes`; on-device inference works.
- FileVault is **Off**; auto-login is set to `rhuang`
  (`Automatic login user: rhuang`). This is the tradeoff for unattended reboot.
- Nix config now uses `users.users.rhuang.uid = 502` (commit `8da7ddc`).
  `/opt/homebrew` was re-owned to `rhuang:admin`; `darwin-rebuild switch`
  completes cleanly.
- Jellyfin and node_exporter are running under UID 502 and return `200`.
- mautrix-imessage was migrated (binary, DB, 107 portals) and has Full Disk
  Access. Double puppeting is enabled: Synapse 1.163 loads the small legacy
  provider in `satsuma/shared_secret_auth_legacy.py` using the iMessage
  appservice token; the bridge logs "Successfully automatically enabled custom
  puppet", its `@rhuang` login returns 200, and own messages bridge. The bridge
  `login_shared_secret` is persisted in the agenix `imessage-config.age`.
  `rc_message` and `rc_joins` were raised (1/s burst 100; 0.5/s burst 50) to
  stop backfill 429s. Commit `ac2c6fa`.
- Some old group-chat backfill still logs `403: ghost user not in room` for
  portal rooms where a ghost was never joined. Live messages and the selected
  digest rooms must be checked separately before relying on those rooms.
  Restart the bridge with:

  ```sh
  launchctl bootstrap gui/502 \
    /Users/rhuang/Library/LaunchAgents/fi.mau.mautrix-imessage.plist
  ```

- The old home and `appletest` profile were deleted after the reboot test:
  `/Users/rhuang.old-20261101` and `/Users/appletest` are gone, stale group
  memberships were cleaned, and `rhuang` is the only local user and APFS
  volume owner. Satsuma still holds the pre-cleanup backups at
  `/hdd/backup/lime-rhuang-home-20261101` and
  `/hdd/backup/lime-repair-backup-20261101.tar.gz`; remove those separately if
  the old message history must be purged everywhere.
- Old iMessage history was not copied into the new profile. If iCloud Messages
  is enabled, Apple may restore history from the cloud; disable it or clear the
  history if a clean start is required.

Next: verify ghost membership for the selected portal rooms, then implement
the digest service. Double puppeting and own-message bridging are verified.
The OpenRouter/Hermes fallback is no longer needed.

# iMessage Group Chat Digest

Status: **plan only** — nothing built yet. Written 2026-10-31.
Goal: summarise a couple of iMessage group chats, deliver scheduled digests, and
push live alerts for concrete events, using Apple's on-device model where
possible.

See [[SMS Matrix Bridge]] for the bridge, [[lime (macOS)]] for the host, and
[[Monitoring]] / [[System Mail (Alerts)]] for the existing notification paths.

## At a glance

| Area | Decision | Why |
| ---- | -------- | --- |
| Source of messages | Matrix portal rooms (mautrix-imessage) | No new Full Disk Access grant, no `chat.db` parser, bridge already normalises iMessage |
| Inference (v1) | Apple on-device via `apfel` | Free, private, no request cap, no Xcode needed |
| Inference (optional) | Private Cloud Compute via a Shortcut, or a paid OpenRouter model | 32k / 1M context and better reasoning for the daily synthesis |
| Trigger | launchd `StartInterval` + `StartCalendarInterval` | macOS-native scheduler; no iMessage webhook exists |
| Delivery | Matrix room `#imessage-digest` + HA companion push or Discord DM | Digest is archived; alerts need a channel that actually pushes |
| Host | lime (service), satsuma (Synapse) | Model must run on the Mac; Matrix is already there |
| State | SQLite on lime | Cursors, dedupe, chunk notes, digest history |
| Secrets | agenix (`lime/secrets/`) | Same pattern as the bridge config |

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

Use a dedicated bot, `@digestbot:estrogenuinely.ca`, and join it to the two
portal rooms. Then:

```sh
curl -s -H "Authorization: Bearer $TOKEN" \
  https://matrix.local.estrogenuinely.ca/_matrix/client/v3/joined_rooms \
  | jq -r '.joined_rooms[]'

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://matrix.local.estrogenuinely.ca/_matrix/client/v3/rooms/$ROOM/state/m.room.name" \
  | jq -r .name
```

`matrix.local.estrogenuinely.ca` is the LAN vhost for Synapse (see
[[SMS Matrix Bridge]]); it avoids hairpin NAT.

**Bot caveat:** send one test message from the bot inside a portal and confirm it
does *not* appear in iMessage. mautrix relays Matrix users into the chat
depending on `bridge.permissions`. If it relays, remove the bot and read with a
read-only `@rhuang` device token instead.

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

## Open decisions

1. Which two group chats (names → portal room IDs)?
2. What counts as an “event” — plans/dates only, or money, health, direct
   requests?
3. Alert channel: HA companion, Discord DM, Matrix, or email?
4. Digest cadence: 08:00 only, 08:00 + 18:00, or live burst updates?
5. Live path: 5-minute launchd interval (v1) or `/sync` daemon (v2)?
6. Any historical backfill, or start from the upgrade date?
7. On-device only, or on-device watcher + cloud daily synthesis?

## References

- Apple Foundation Models: <https://developer.apple.com/foundation-models-framework/>
- `fm` CLI / Python SDK (WWDC26): <https://developer.apple.com/videos/play/wwdc2026/334/>
- Context window: <https://developer.apple.com/documentation/Technotes/tn3193-managing-the-on-device-foundation-model-s-context-window>
- `apfel`: <https://github.com/Arthur-Ficial/apfel>
- Apple Intelligence requirements: <https://support.apple.com/en-us/121115>
- OpenRouter free-model limits: <https://openrouter.ai/docs/api_reference/limits>
- mautrix-imessage: <https://docs.mau.fi/bridges/go/imessage/index.html>

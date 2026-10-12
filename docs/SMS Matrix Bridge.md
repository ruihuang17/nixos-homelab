# SMS → Matrix Bridge (Pixel 4XL)

`kiro-cli --resume-id 82817f97-ec47-45c2-af49-67ad38fd1e9`

An old **Pixel 4XL** (coral, Android 13) repurposed as a dedicated **SMS → Matrix** bridge.
Incoming SMS to the Pixel's SIM appear as Matrix rooms (portals) on **estrogenuinely.ca**
(Synapse on **satsuma**). Uses the **mautrix-imessage** bridge in its **android-sms** mode,
driving the existing **mautrix-wsproxy** already running on satsuma for iMessage.

The phone is **air-gapped** (no internet): quarantined on the IoT VLAN, allowed to reach only
satsuma over the LAN. No Tailscale on the phone (deliberately declined). Inbound-only in
practice — outbound SMS was not tested (not needed).

> Direction of use: SMS arrives on the Pixel's cellular radio → bridge → Matrix. The phone
> never needs internet; it only needs LAN reachability to satsuma + internal DNS.

## Status (2026-10-11)

| Area                                                            | State                                         |
| --------------------------------------------------------------- | --------------------------------------------- |
| APK built (android-sms, patched) & sideloaded                   | done                                          |
| Phone air-gapped on IoT VLAN, LAN-only to satsuma               | done                                          |
| Internal DNS: matrix.local + mautrix-wsproxy.local → 10.0.10.72 | done                                          |
| SMS appservice registered in Synapse + wsproxy                  | done, committed `d43bbc0`                     |
| Inbound SMS → Matrix portal                                     | done, verified end-to-end (logs + Synapse DB) |
| Double-puppeting / auto-join of @rhuang                         | done, verified                                |
| Reboot durability (auto-start bridge on boot)                   | done, reboot-tested                           |
| Outbound SMS (reply in Matrix → SMS)                            | NOT tested (opted out)                        |
| Encryption                                                      | disabled in config (initial bringup)          |
| syncproxy (battery optimization)                                | skipped — foreground websocket works          |

## Topology (LAN-only, air-gapped)

```
Pixel 4XL (SMS)                         satsuma (NixOS, on-prem)
  Unify_IoT SSID                          10.0.10.72/24
  VLAN 10.0.20.0/24  ──LAN only──▶  nginx :443 (wildcard cert)
  IP 10.0.20.32                            │  matrix.local.estrogenuinely.ca → 127.0.0.1:8008 (Synapse)
  static DNS → 10.0.10.23                  │  mautrix-wsproxy.local.estrogenuinely.ca → wsproxy
  (WAN egress blocked at router)           ▼
                                        Synapse 26.11  ◀──appservice──  mautrix-wsproxy
                                        estrogenuinely.ca                 (id: sms)
```

- Phone resolves `matrix.local.estrogenuinely.ca` and `mautrix-wsproxy.local.estrogenuinely.ca`
  → `10.0.10.72` via internal DNS at `10.0.10.23` (user opened IoT→DNS firewall rule).
- The bridge app holds a **foreground websocket** to wsproxy (`wss://mautrix-wsproxy.local...`).

## How it works

App.onCreate → `Bridge.init` registers an SMS **ContentObserver** on `content://sms` + `mms`,
and `Bridge.start` launches the native Go binary `./libmautrix.so -c config`. A new SMS fires
the observer → `DatabaseSyncWork` → `SendMessage` work → IPC `command=message` to the Go
bridge → it creates a Matrix portal room via `createRoom`.

Inbound does **not** require the default-SMS-app role (it reads via ContentObserver). The role
is only needed for **outbound**.

## Server side (satsuma, committed `d43bbc0` in /etc/nixos)

- `/var/lib/matrix-synapse/sms-registration.yaml` (owner matrix-synapse, 644): appservice
  `id: sms`, namespaces `^@smsbot:` and `^@sms_.*:`. Added to `app_service_config_files` in
  `satsuma/matrix.nix`.
- `satsuma/nginx.nix`: LAN vhost `matrix.local.estrogenuinely.ca` → `http://127.0.0.1:8008`
  (proxyWebsockets, estrogenuinely.ca wildcard ACME cert).
- `/var/lib/mautrix-wsproxy/config.yaml`: `- id: sms` block with matching tokens (runtime
  state, not in the nixos repo). wsproxy logs "Found 2 appservices".

Tokens live in `sms-registration.yaml` / wsproxy config / the baked-in app `config.yaml`.
**Keep them secret** (not reproduced in this note).

## The 4 source patches (vs android-sms 0.1.89 + mautrix-imessage submodule)

Needed for **Android 13 + modern Synapse 26.11**:

1. **`sms/.../work/WorkManager.kt`** — `SendMessage` work constraint `NetworkType.CONNECTED` →
   `NOT_REQUIRED`. On the air-gapped WiFi, Android never marks the link "internet-validated",
   so jobs stayed `ENQUEUED` forever.
2. **`mautrix-imessage/portal.go` `GetBasePowerLevels()`** — the initial `power_levels.users`
   map is now empty `{}` (was `{creator: 100}`). Modern Synapse rejects the creator appearing
   in `content.users`.
3. **`mautrix-imessage/portal.go` `GetMatrixUsers()`** — `JoinedMembers()` → `Members()`,
   counting both `join` AND `invite`. Previously fresh portals were torn down as "empty"
   before @rhuang had joined.
4. **`sms/.../receivers/StartupReceiver.kt`** — fixed an always-true `||` guard (was a no-op)
   so the bridge actually auto-starts on `BOOT_COMPLETED` / `MY_PACKAGE_REPLACED`.

Also **`mautrix.sh`**: commented out `git submodule foreach git reset --hard` + `submodule
update` (lines ~58–59), which were reverting the portal.go patches on every build.

## Build

Containerized build replicating `.gitlab-ci.yml`, via **podman**:

```bash
cd /home/rhuang/android-sms
bash build-in-container.sh    # eclipse-temurin:11-jdk, builds :app:assembleDebug
```

- Toolchain: Go 1.17.8, cmdline-tools 7302050, NDK 21.3.6528147, platform android-31,
  build-tools 31.0.0.
- **Gotcha:** mount the tool cache at **`/bt`**, NOT `/opt` (the temurin JDK lives at
  `/opt/java/openjdk` and would be shadowed).
- Output: `app/build/outputs/apk/debug/app-debug.apk`.
- **Each rebuild = a new debug keystore** → must `adb uninstall` then `adb install` (plain
  `-r` fails `INSTALL_FAILED_UPDATE_INCOMPATIBLE`).

## Runtime hardening on the phone (re-apply after every REINSTALL)

```bash
PKG=com.beeper.sms.app
adb shell pm grant $PKG android.permission.READ_SMS
adb shell pm grant $PKG android.permission.SEND_SMS
adb shell pm grant $PKG android.permission.READ_CONTACTS
adb shell pm grant $PKG android.permission.READ_PHONE_STATE
adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS
adb shell dumpsys deviceidle whitelist +$PKG
adb shell device_config put activity_manager max_phantom_processes 2147483647
adb shell device_config set_sync_disabled_for_tests persistent
adb shell settings put global settings_enable_monitor_phantom_procs false
# default SMS app (outbound only; interactive, needs a phone tap):
adb shell am start -a android.provider.Telephony.ACTION_CHANGE_DEFAULT --es package $PKG
```

The **phantom-process killer** (Android 12+) otherwise reaps `libmautrix.so`. These settings
survive reboots but are cleared by a reinstall.

## Double-puppeting / auto-join

So that @rhuang auto-joins new portals (no manual invite-accept), the bridge logs in as a
dedicated double-puppet. We have OIDC/Kanidm (no password auth), so a **raw access token** was
minted directly in Synapse: device **`SMSDOUBLEPUPPET`** for `@rhuang` (`access_tokens` id=3,
long-lived, no expiry).

Enable it from Element, in the **@smsbot** management room:

```
!sms login-matrix <double-puppet-token>
```

Bot replies "Successfully enabled double puppeting". The token is then stored in the bridge's
**own sqlite** on the phone: `mautrix-imessage.db`, `user` table.

### ⚠️ Known failure: "auto-join doesn't work" after a reinstall

A reinstall wipes the app's data, including `mautrix-imessage.db` → the stored
`user.access_token` becomes **empty** → double-puppeting silently stops → new portals only
**invite** @rhuang instead of auto-joining. (A plain **reboot** is fine; sqlite survives.)

Diagnose:

```bash
adb exec-out "run-as com.beeper.sms.app cat /data/user/0/com.beeper.sms.app/files/mautrix-imessage.db" > /tmp/b.db
sqlite3 /tmp/b.db "select mxid, length(access_token) from user;"   # 0 = broken, 49 = ok
```

Fix: re-run the `!sms login-matrix <token>` command in the @smsbot room. (Confirmed fix on
2026-10-11.) Already-left portal rooms are **not** retroactively re-joined — re-join those
manually once. If the Synapse DB is ever rebuilt, re-mint the token.

## Durability

- `StartupReceiver` auto-starts the bridge on boot (fixed; reboot-tested: bridge process +
  native lib came back, websocket reconnected, @rhuang still joined, hardening persisted).
- Default-SMS-app role is sticky across **reboots** once set, but reset by **reinstalls**.

## Backup & source

- Local backup: **`/home/rhuang/sms-bridge-backup/`** — APK, git bundles of repo + submodule,
  `config.yaml` (has tokens — keep secret), `build-in-container.sh`, `README.md` with full
  recovery + re-hardening steps.
- Local git: main repo branch `homelab-sms-bridge` (commit `92ccf2b`), submodule branch
  `homelab-sms-bridge` (commit `475a635`), both off upstream tag 0.1.89.
- GitHub mirror: `github.com/ruihuang17/android-sms` (+ patched submodule
  `github.com/ruihuang17/mautrix-imessage`), branch `homelab-sms-bridge`.

## Key facts

- Pixel 4XL: serial `99161FFBA00921`, coral, arm64-v8a, Android 13 / SDK 33.
- Package: `com.beeper.sms.app`.
- App config (`app/src/main/assets/config.yaml`, baked into APK): homeserver
  `https://matrix.local.estrogenuinely.ca`, websocket `wss://mautrix-wsproxy.local.estrogenuinely.ca`,
  domain `estrogenuinely.ca`, bridge user `@rhuang:estrogenuinely.ca`, username template
  `sms_{{.}}`, encryption disabled.
- Management room bot: `@smsbot:estrogenuinely.ca`. Puppets: `@sms_<number>:estrogenuinely.ca`.

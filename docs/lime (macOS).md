# lime (macOS)

Mac mini, `10.0.10.73`, Apple M4 / 16 GB / macOS 15.7.7. See [[Setup Overview]]
for the host table, [[NFS]] for the media mount and [[Media Stack]] for Jellyfin.

## What runs

| Thing | Managed by | Notes |
| ----- | ---------- | ----- |
| mautrix-imessage | launchd user agent `fi.mau.mautrix-imessage` | `platform: mac`; binary `~/mautrix-imessage/mautrix-imessage` |
| iMessage digest | launchd user agent `ca.estrogenuinely.imessage-digest` | polls two portal rooms, `apfel` alerts + OpenRouter Claude Haiku digest; see [[iMessage Digest]] |
| wsproxy tunnel | launchd user agent `ca.estrogenuinely.wsproxy-tunnel` | `ssh -L 127.0.0.1:29331` to satsuma; works around Local Network Privacy for the bridge |
| Jellyfin | launchd user agent `com.jellyfin.server` (`open -a Jellyfin`) | Homebrew cask, `*:8096` |
| node_exporter | launchd user agent `sh.brew.node_exporter` | `:9100`, scraped by satsuma as `instance="lime"`; also serves the digest heartbeat |
| autofs | `/etc/auto_master` + `/etc/auto_nas` | NFSv3 to satsuma, see [[NFS]] |

The [[iMessage Digest]] service runs on the same five-minute launchd cadence as
node_exporter. It reads the mautrix portal rooms through the Matrix API (no new
TCC grant), uses Apple's on-device model via Homebrew `apfel` for event alerts
and OpenRouter Claude Haiku 5.5 on a ZDR route for the final digest, and writes a
textfile metric for the stale-run alert.

The bridge reaches `mautrix-wsproxy` through the
`ca.estrogenuinely.wsproxy-tunnel` agent: macOS Local Network Privacy blocks
the unsigned mautrix binary from LAN sockets, while Apple-signed `/usr/bin/ssh`
is allowed. The tunnel forwards lime's `127.0.0.1:29331` to satsuma, and the
bridge config uses `ws://127.0.0.1:29331`. The satsuma wsproxy is not exposed
publicly.

Auto-login is enabled so all the launchd agents come back after a reboot
without anyone at the machine. That only works because **FileVault is off** —
turning FileVault on would stop the box coming back unattended, taking Jellyfin,
the iMessage bridge and the wsproxy tunnel with it.

## nix-darwin

Since 2026-10-31 lime is built from `darwinConfigurations.lime` in this flake
(`lime/configuration.nix`, `lime/agents.nix`, `lime/homebrew.nix`). It is the
first non-NixOS host here; the three NixOS configs are unaffected.

```sh
cd ~/nixos-homelab && git pull
sudo darwin-rebuild switch --flake ~/nixos-homelab#lime
```

- **Activation must run as root.** Newer nix-darwin removed the internal
  `sudo`, so `nix run nix-darwin -- switch` fails with "system activation must
  now be run as root". `sudo darwin-rebuild …` is the supported path.
- **The login shell is nix's fish** (`/run/current-system/sw/bin/fish`), not
  Homebrew's. Homebrew's fish reads `/opt/homebrew/etc/fish` and never saw
  nix-darwin's `/etc/fish/config.fish`, so `/run/current-system/sw/bin` (and
  with it `darwin-rebuild`) was not on `PATH`. `~/.config/fish/config.fish`
  still loads as usual.
- **Everything in `/etc` that nix-darwin owns is generated**: `auto_master`,
  `auto_nas`, `shells`, `nix/nix.conf`. Hand-edited copies are preserved as
  `*.before-nix-darwin`; deleting one and rerunning activation regenerates it.
  nix-darwin refuses to start if it finds an unrecognised `/etc` file, so rename
  rather than edit.
- **Homebrew is adopt-only**: `onActivation.cleanup = "none"`, no auto-update, no
  upgrade. `brew bundle` only installs what is missing. The Brewfile is an
  inventory, not a lockfile — Homebrew cannot pin versions.
- **`users.knownUsers = [ "rhuang" ]`** makes nix-darwin own the account. Do not
  remove `users.users.rhuang` without also removing it from `knownUsers`, or the
  next activation deletes the user.
- node_exporter comes from nixpkgs (`prometheus-node-exporter`, same 1.12.1 the
  brew formula had); the `sh.brew.node_exporter` label was kept so Prometheus
  and the dashboards did not have to change.

## Security posture (2026-10-31)

SIP, the sealed system volume and TCC enforcement are all **on**:

```text
$ csrutil status                      -> enabled
$ csrutil authenticated-root status   -> enabled
Security Mode:               Full       (smb0): absent
SIP Status:                  Enabled    (sip0): absent
Signed System Volume Status: Enabled    (sip1): absent
```

**History.** BlueBubbles' Private API required both SIP off *and* the Apple
Silicon boot policy at **Permissive**. Those are two separate knobs, and
together they also switched off TCC enforcement entirely: any unprivileged
process could read `~/Library/Messages/chat.db`, `~/Library/Safari/History.db`
and even the system `TCC.db`. BlueBubbles was replaced by mautrix-imessage,
which needs neither.

**Restoring it** (Apple Silicon, so from Recovery): shut down, hold power until
*Loading startup options*, Options → Utilities → Terminal → `csrutil enable`; then
**Startup Security Utility → Macintosh HD → Full Security → Apply**. Enabling SIP
alone leaves the boot policy at Permissive, which still allows unsigned kexts.

### TCC grants that matter

| Service | Client | Needed by | Identity |
| ------- | ------ | --------- | -------- |
| `kTCCServiceSystemPolicyAllFiles` | `/Users/rhuang/mautrix-imessage/mautrix-imessage` | reading `chat.db` and `Attachments/` | cdhash `f6fd36c0…` |
| `kTCCServiceSystemPolicyNetworkVolumes` | `Jellyfin.Server` | reading the NFS autofs mount `~/NAS/mediaSrv` | code signature |
| `kTCCServiceAppleEvents`, `kTCCServiceAddressBook` | the mautrix binary | driving Messages.app, contacts | path (user db) |

Both key grants are container- or path-bound. **Do not move or rebuild the
mautrix binary** — a new build is a new cdhash and the Full Disk Access grant is
lost. Keep Jellyfin at `/Applications/Jellyfin.app`. Anything whose path changes,
including a relocated `/nix/store` copy, needs a fresh grant from System
Settings; editing `TCC.db` with `sqlite3` only works while SIP is off.

## Verifying after a change

```sh
csrutil status
sudo bputil -d | grep -iE "security mode|sip status"
lsof -p $(pgrep -f mautrix-imessage/mautrix-imessage) | grep chat.db
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8096/health
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9100/metrics
grep "Received incoming message" ~/mautrix-imessage/logs/mautrix-imessage.log | tail -1
launchctl list | grep -E 'imessage-digest|fi.mau' 
cat "$HOME/Library/Application Support/imessage-digest/textfile/imessage_digest.prom"
```

Negative control: a launchd **user agent** that has no FDA should be denied
`chat.db` and `TCC.db`. If it can read them, TCC enforcement is off again.

## Gotchas

- The bridge reads `chat.db` directly (`lsof` shows `chat.db`, `-wal`, `-shm`);
  it is not going through Messages.app for history.
- `~/mautrix-imessage/config.yaml` is **not** used by the running bridge. The
  config (including the Matrix appservice `as_token`/`hs_token`) is an agenix
  secret (`lime/secrets/imessage-config.age`) decrypted at boot to
  `/run/agenix/imessage-config` (RAM disk, `rhuang:staff 0400`). The launchd
  agent runs `mautrix-imessage -c /run/agenix/imessage-config -n`. To edit the
  config: decrypt with `age -d -i ~/.ssh/general`, edit, re-encrypt to
  `lime/secrets/imessage-config.age`, then `darwin-rebuild switch`.
- BlueBubbles' TCC rows (Full Disk Access, Accessibility) were removed
  2026-10-31; the app is uninstalled.
- Sunshine is installed via Homebrew but not in use. Its Accessibility/PostEvent
  grants still point at the `2025.924` Cellar path after a formula bump, so
  input injection is likely broken — irrelevant while it is unused.
- The mautrix binary and Jellyfin stay out of `/nix/store` for the TCC reasons
  above, even though the rest of the machine is now nix-darwin managed.
- The source checkout `~/mautrix-imessage/imessage` has **one local commit**
  (`f9271c9`) bumping `libheif` to 1.23.1 to match Homebrew's library. That is
  the tree the current binary was built from; reverting it means the next build
  will not link.

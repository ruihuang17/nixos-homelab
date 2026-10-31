# lime (macOS)

Mac mini, `10.0.10.73`, Apple M4 / 16 GB / macOS 15.7.7. See [[Setup Overview]]
for the host table, [[NFS]] for the media mount and [[Media Stack]] for Jellyfin.

## What runs

| Thing | Managed by | Notes |
| ----- | ---------- | ----- |
| mautrix-imessage | launchd user agent `fi.mau.mautrix-imessage` | `platform: mac`; binary `~/mautrix-imessage/mautrix-imessage` |
| Jellyfin | launchd user agent `com.jellyfin.server` (`open -a Jellyfin`) | Homebrew cask, `*:8096` |
| node_exporter | launchd user agent `sh.brew.node_exporter` | `:9100`, scraped by satsuma as `instance="lime"` |
| autofs | `/etc/auto_master` + `/etc/auto_nas` | NFSv3 to satsuma, see [[NFS]] |

Auto-login is enabled so all three come back after a reboot without anyone at
the machine. That only works because **FileVault is off** — turning FileVault on
would stop the box coming back unattended, taking Jellyfin and the iMessage
bridge with it.

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
```

Negative control: a launchd **user agent** that has no FDA should be denied
`chat.db` and `TCC.db`. If it can read them, TCC enforcement is off again.

## Gotchas

- The bridge reads `chat.db` directly (`lsof` shows `chat.db`, `-wal`, `-shm`);
  it is not going through Messages.app for history.
- `~/mautrix-imessage/config.yaml` holds the Matrix appservice tokens in plaintext
  (mode 0600). It is not in this repo.
- BlueBubbles' TCC rows (Full Disk Access, Accessibility) were removed
  2026-10-31; the app is uninstalled.
- Sunshine is installed via Homebrew but not in use. Its Accessibility/PostEvent
  grants still point at the `2025.924` Cellar path after a formula bump, so
  input injection is likely broken — irrelevant while it is unused.
- Nothing on lime is managed by Nix yet. If that changes, the mautrix binary and
  Jellyfin stay out of `/nix/store` for the TCC reasons above.

# Media stack (satsuma + lime)

Documented 2026-10-30. Everything except Jellyfin runs on `satsuma`; Jellyfin
runs on `lime` (the Mac mini, `10.0.10.73`) because that is where the hardware
decoder is. See [[Setup Overview]] for the hosts, [[NFS]] for how lime reaches
the media, [[Monitoring]] for the probes and [[Backup]] for what is (and is not)
backed up.

```text
   public torrent indexers
            │
        Prowlarr ──── fullSync ────► Sonarr / Radarr
            │                          │  grab release
            │                          ▼
            │                   qBittorrent          (inside netns torrent-vpn)
            │                          │  saves to /hdd/mediaSrv/torrent/<category>
            │                          ▼
            │                   import (hardlink) ──► /hdd/mediaSrv/media/...
            │                                              │
            │                                    NFS export hdd/mediaSrv (LAN)
            │                                              ▼
            └──────────────────────────────────────► Jellyfin on lime
```

## At a glance

| Thing | Value |
| ----- | ----- |
| Hosts | `satsuma` `10.0.10.72` (all but Jellyfin), `lime` `10.0.10.73` (Jellyfin) |
| Modules | `satsuma/arr-stack/{default,arr-stack,qbittorrent,jellyfin}.nix` |
| Data | ZFS dataset `hdd/mediaSrv` → `/hdd/mediaSrv` (~3.8 TB used, ~13.8 TB free) |
| Shared group | `media`, GID **3000** — the numeric GID is what crosses NFS (neither pomelo nor lime defines a `media` group) |
| Databases | PostgreSQL: `sonarr-main`/`-log`, `radarr-main`/`-log`, `prowlarr-main`/`-log` |
| Secrets | agenix: `pia-username`, `pia-password`, `qbittorrent-password`, `qui-session-secret` |
| Versions (2026-10-30) | Sonarr 4.0.20.3014 · Radarr 6.4.4.10685 · Prowlarr 2.6.5.5623 · qBittorrent 5.3.0 · Jellyfin 10.11.11 |

## Components

| Service | Port | URL | Unit | State |
| ------- | ---- | --- | ---- | ----- |
| Prowlarr | 9696 | <https://prowlarr.local.estrogenuinely.ca> | `prowlarr` | `/var/lib/private/prowlarr` (dynamic user) |
| Sonarr | 8989 | <https://sonarr.local.estrogenuinely.ca> | `sonarr` | `/var/lib/sonarr` |
| Radarr | 7878 | <https://radarr.local.estrogenuinely.ca> | `radarr` | `/var/lib/radarr` |
| FlareSolverr | 8191 | — | `flaresolverr` | — |
| qBittorrent | 8080 | <https://qbittorrent.local.estrogenuinely.ca> (via qui) | `qbittorrent` | `/var/lib/qbittorrent`, inside the VPN netns |
| qui | 7476 | same vhost as qBittorrent | `qui` | `/var/lib/qui` |
| Jellyfin | 8096 | <https://jellyfin.local.estrogenuinely.ca> | launchd `com.jellyfin.server` on lime | `~/Library/Application Support/jellyfin` |

All the `.local.estrogenuinely.ca` names resolve to satsuma (Technitium, see
[[DNS]]) and are served by satsuma's nginx with the `*.estrogenuinely.ca`
wildcard certificate; `jellyfin.local…` proxies to `10.0.10.73:8096`.

### Prowlarr

Indexer manager. It holds the indexers and pushes them to the apps with
**fullSync** (`Radarr` and `Sonarr` are registered applications), so indexers
are only ever added in Prowlarr. The current set is torrent-only and
anime-heavy (Nyaa.si, sukebei, Mikan, SubsPlease, dmhy, Bangumi Moe, Shana
Project, Tokyo Toshokan, LimeTorrents, Knaben, showRSS, …); `52BT` and
`ACG.RIP` are added but disabled.

`FlareSolverr` (port 8191) is the Cloudflare-bypass proxy Prowlarr uses for the
indexers that sit behind a challenge.

### Sonarr and Radarr

Both store their libraries in PostgreSQL and run as group `media`, so they can
write into the media tree.

| App | Root folders | Download clients (qBittorrent category) |
| --- | ------------ | --------------------------------------- |
| Sonarr | `/hdd/mediaSrv/media/tv`, `/hdd/mediaSrv/media/anime/tv` | `tv`, `anime-tv` |
| Radarr | `/hdd/mediaSrv/media/movies`, `/hdd/mediaSrv/media/anime/movies` | `movies`, `anime-movies` |

Both use **hardlinks** on import (`copyUsingHardlinks = true`) — the torrent
stays in `/hdd/mediaSrv/torrent` for seeding while the library gets a second
name on the same dataset, so nothing is copied and no extra space is used.
Sonarr also imports extra files (subtitles); Radarr removes empty folders.

The qBittorrent host is **`10.200.200.2:8080`**, the VPN-side veth address, not
`localhost` — see below.

### qBittorrent and the PIA VPN

qBittorrent runs in the network namespace `torrent-vpn`, which has no route
except through a PIA WireGuard tunnel, so a VPN failure cannot leak traffic.

```text
host ── veth-host 10.200.200.1 ══ veth-vpn 10.200.200.2 ── netns torrent-vpn
                                                             ├── wg0 → PIA (ca / Montreal)
                                                             └── qBittorrent :8080
```

| Piece | Detail |
| ----- | ------ |
| `pia-wg-config` | oneshot: logs in to PIA, registers a key, writes `/etc/wireguard/pia.conf` plus `pia_gateway.txt`, `pia_hostname.txt`, `pia_token.txt` |
| `pia-vpn` | creates the netns, veth pair and `wg0`, adds the default route inside the netns |
| `qbittorrent` | `NetworkNamespacePath=/var/run/netns/torrent-vpn`, user/group `qbittorrent` (member of `media`) |
| `pia-port-forwarder` | gets the forwarded port from PIA and pushes it into qBittorrent's `listen_port` |
| `pia-stack-watchdog.timer` | 3 min after boot, then every 5 min: starts any of the above that is not active |

Because the WebUI lives inside the netns, it is only reachable from the host at
`10.200.200.2:8080`. LAN users get **qui** instead (a nicer alternative WebUI on
`127.0.0.1:7476`), which satsuma's nginx proxies at
`qbittorrent.local.estrogenuinely.ca`. qui's session secret is
`qui-session-secret.age`.

qBittorrent saves to `/hdd/mediaSrv/torrent` and uses one category per app:

| Category | Save path | Used by |
| -------- | --------- | ------- |
| `tv` | `/hdd/mediaSrv/torrent/tv` | Sonarr |
| `anime-tv` | `/hdd/mediaSrv/torrent/anime/tv` | Sonarr (anime) |
| `movies` | `/hdd/mediaSrv/torrent/movies` | Radarr |
| `anime-movies` | `/hdd/mediaSrv/torrent/anime/movies` | Radarr (anime) |

Seeding stops at **ratio 2.0**; the temp directory is disabled (writes land
directly in the category folder, which keeps hardlinking simple).

#### Port forwarding

PIA assigns a **dynamic** port (5 digits, changes on every reconnect). The
forwarder:

1. calls `https://<server-cn>:19999/getSignature` through the tunnel (the TLS
   certificate is issued for the server name, so the name must be the URL host
   with `--connect-to` pointing at the gateway IP),
2. keeps the returned `payload`/`signature` — they are valid for about two
   months — and re-sends `bindPort` every **15 minutes**, which is what keeps
   the forward alive,
3. logs in to qBittorrent's Web API (it refuses unauthenticated calls with 403,
   even on loopback) and sets `listen_port`.

The current port is the `listen_port` in
`/var/lib/qbittorrent/qBittorrent/config/qBittorrent.conf`; the forwarder logs
`PIA assigned forwarded port <n>` on every (re)start.

Region is `ca` (Montreal). `ca_toronto` was in use until 2026-10-29, when its
gateway stopped answering port 19999 (connection reset), which makes port
forwarding impossible there.

### Jellyfin (lime)

Native macOS app (`/Applications/Jellyfin.app`, 10.11.11), started at login by
`~/Library/LaunchAgents/com.jellyfin.server.plist`, listening on `*:8096`.
macOS auto-login is enabled so it comes back after a reboot.

| Library | Path (on lime) |
| ------- | -------------- |
| Shows | `~/NAS/mediaSrv/media/tv` |
| Movies | `~/NAS/mediaSrv/media/movies` |
| Anime | `~/NAS/mediaSrv/media/anime/tv` |
| Anime-Movies | `~/NAS/mediaSrv/media/anime/movies` |

`~/NAS/mediaSrv` is an **autofs** mount of satsuma's `hdd/mediaSrv` export,
NFSv3 with `nolocks` (see [[NFS]] for the map and the automountd caveat).

Transcoding uses **VideoToolbox** (hardware decode/encode) with tonemapping on.

The satsuma Jellyfin module is **disabled** (`services.jellyfin.enable = false`)
but kept for rollback: it carries the UID (986), the `render`/`video` groups,
the VAAPI settings and a fontconfig snippet for `/var/lib/jellyfin/fonts`
(the old 28 GB font collection). Its old state in `/var/lib/jellyfin` is
excluded from the offsite backup.

## Storage layout

```text
/hdd/mediaSrv                 hdd/mediaSrv (ZFS), root:media 2770
├── media                     3.6 TB — the library; Jellyfin only reads here
│   ├── movies
│   ├── tv
│   └── anime/{movies,tv}
├── torrent                   260 GB — qBittorrent save path (qbittorrent:media)
│   ├── movies, tv, anime/{movies,tv}      (qBittorrent categories)
└── Fonts                     19 MB — a few `.woff2` subtitle fonts
```

`media` and `torrent` are the same dataset on purpose: that is what makes
hardlink imports instant. Moving the library to another dataset (or pool) turns
imports into copies.

`hdd/mediaSrv` is exported read-write to the whole LAN ([[NFS]]) and mounted by
pomelo (`~/NAS/media`) and lime. Hermes gets a read-only POSIX ACL on the tree
(see [[Hermes]]).

## Networking

| What | Where |
| ---- | ----- |
| veth pair | `veth-host 10.200.200.1/24` (host) ↔ `veth-vpn 10.200.200.2/24` (netns) |
| Tunnel | `wg0` inside the netns (`10.25.x.x/32` from PIA), `AllowedIPs 0.0.0.0/0`, keepalive 25 s |
| PIA files | `/etc/wireguard/pia.conf`, `pia_gateway.txt`, `pia_hostname.txt`, `pia_token.txt` (all 0600) |
| nginx vhosts | `sonarr`, `radarr`, `prowlarr` → `127.0.0.1`; `qbittorrent` → `127.0.0.1:7476` (qui); `jellyfin` → `10.0.10.73:8096` |
| DNS | `*.local.estrogenuinely.ca` wildcard, `jellyfin` CNAME → satsuma ([[DNS]]) |
| NFS | `hdd/mediaSrv` → LAN `10.0.10.0/24` ([[NFS]]) |

## Monitoring

The "Media" group on the Homelab Overview dashboard ([[Monitoring]]) probes:

| Tile | Check |
| ---- | ----- |
| Jellyfin | HTTP `http://10.0.10.73:8096/health` (probed from satsuma) |
| Sonarr / Radarr / Prowlarr | HTTP `/ping` on loopback |
| FlareSolverr | HTTP `/health` |
| qBittorrent / PIA VPN / PIA forward | `systemd` unit state (the WebUI is inside the netns, so there is no port to probe) |

`grove-exporter` also scrapes exportarr sidecars for Sonarr (9708), Radarr
(9709), Prowlarr (9710) and qBittorrent (9711), plus ZFS/SMART, which feeds the
Grove dashboard. The *arr API keys are extracted from each app's `config.xml`
by `grove-arr-keys.service` into `/run/grove-exporter/`.

## Backups

- `/var/lib/{sonarr,radarr,qbittorrent,qui,prowlarr}` are inside `/var`, so they
  are in the nightly offsite restic backup ([[Backup]] §4).
- **`/hdd/mediaSrv` is not backed up.** The library and the torrents are
  re-downloadable; only the metadata in `/var/lib` is preserved.
- PostgreSQL dumps (including the *arr databases) run nightly at 03:00.

## Operations

```sh
# Apply config changes (from satsuma)
sudo nixos-rebuild switch --flake /etc/nixos#satsuma

# Restart just the media apps after changing their settings
sudo systemctl restart sonarr radarr prowlarr flaresolverr

# qBittorrent chain (order matters: config → netns → app → forwarder)
sudo systemctl restart pia-vpn          # re-runs pia-wg-config, restarts qbittorrent via Requires
sudo systemctl start qbittorrent pia-port-forwarder   # (the watchdog would also do this)

# Is the forwarded port healthy?
journalctl -u pia-port-forwarder -n 20 --no-pager
grep -i 'Session\Port' /var/lib/qbittorrent/qBittorrent/config/qBittorrent.conf
ip netns exec torrent-vpn ss -lnt | grep "$(grep -oP '(?<=Session\\Port=).*' /var/lib/qbittorrent/qBittorrent/config/qBittorrent.conf)"
```

To check the forward from outside the LAN, connect to the PIA exit IP (not the
home WAN IP):

```sh
ip netns exec torrent-vpn curl -s https://1.1.1.1/cdn-cgi/trace | grep ^ip=
# then, from any other host:
nc -vz <exit-ip> <forwarded-port>
```

### Changing the PIA region

Set `piaRegion` in `satsuma/arr-stack/qbittorrent.nix`, rebuild, then
`systemctl restart pia-vpn` (and start qBittorrent/forwarder if the watchdog
has not already). Pick a region whose `port_forward` is `true` in
<https://serverlist.piaservers.net/vpninfo/servers/v6> **and** whose gateway
answers on port 19999 — the second part is not advertised and has to be tested.

## Troubleshooting

| Symptom | Cause / fix |
| ------- | ----------- |
| All of qBittorrent, PIA VPN and PIA forward are down after a boot | `pia-wg-config` failed (typically DNS not up yet). It now waits for the network and retries; the watchdog starts the rest within 5 min. Check `journalctl -u pia-wg-config`. |
| "PIA forward" is green but peers cannot connect | The unit only means the loop is running. Check the journal for `getSignature`/`bindPort` failures and that qBittorrent's `listen_port` matches the PIA port. |
| `getSignature` returns nothing / TLS error | The request must use the server **name** (`pia_hostname.txt`) as the URL host; using the bare IP fails certificate verification. |
| qBittorrent WebUI refuses connections from the LAN | It listens inside the netns. Use `qbittorrent.local.estrogenuinely.ca` (qui) or `10.200.200.2:8080` from satsuma. |
| Arr app cannot reach qBittorrent | The download client host must be `10.200.200.2`, not `localhost` (localhost inside the *arr service is the host). |
| Imports copy instead of hardlink | `/hdd/mediaSrv/torrent` and `/hdd/mediaSrv/media` are on different filesystems. |
| Jellyfin opens a file then hangs | NFSv3 mount on lime is missing `nolocks`, or `com.apple.automountd` is not running ([[NFS]]). |
| Nothing plays after a satsuma reboot | Check the NFS export is up: `exportfs -v` on satsuma, `findmnt -T ~/NAS/mediaSrv` on lime. |
| qBittorrent password rotated | `systemctl restart qbittorrent pia-port-forwarder hermes-media-keys hermes-agent` (the forwarder re-reads `/run/agenix/qbittorrent-password` on start). |

## History

- **2026-10-30 — port forwarding repaired.** The stack had been down since the
  2026-10-29 19:01 boot: `pia-wg-config` raced the network, `curl` exited 6, and
  because the other three units `Require=` it they never started. Even when it
  ran, the forwarder used the gateway IP as the TLS hostname (certificate
  error, hidden by `-s`), never authenticated to qBittorrent (403), and re-asked
  PIA for a new port every 15 min. Fixed in `cf98391`: network wait + retries,
  server name as TLS host, qBittorrent login, cached payload/signature,
  watchdog timer, and the move from `ca_toronto` to `ca` (Montreal).

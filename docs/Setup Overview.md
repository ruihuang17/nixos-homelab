# Homelab Setup Overview

Documented 2026-10-11 by SSHing into each machine. Desktops and laptops are excluded. See [[IP Address]] for the address table.

| Host | IP | Role | OS |
| ---- | -- | ---- | -- |
| `orange` | 10.0.10.23 | DNS server | Armbian (Debian 13 trixie), aarch64 |
| `satsuma` | 10.0.10.72 | Main server (services, storage) | NixOS (unstable, flake) |
| `mac-mini` | 10.0.10.73 | iMessage bridge, Sunshine, Jellyfin app | macOS 15.7 on Apple M4 |
| `homeassistant` | 10.0.10.74 | Home automation | Home Assistant OS 18.3 |
| `gaggimate` | 10.0.10.75 | Coffee Machine | Gaggimate |
| `marigold` | 10.0.10.76 | Zero Tier Node (AI) | Rasbian |
| `prusa-core-one` | 10.0.10.77 | 3D Printer | Prusa |

SSH aliases for all of these are in `~/.ssh/config`. Note that `homeassistant` uses port 22222.

---

## orange (DNS)

- Board: 8-core aarch64 SBC, 5.7 GB RAM, 15 GB eMMC (15% used).
- Runs **Technitium DNS Server** (systemd unit `dns`, .NET runtime in `/opt/dotnet`, app in `/opt/technitium`, config in `/etc/dns`).
- DNS on port 53 (TCP and UDP). Web UI on port 5380, which satsuma's nginx proxies as `dns.local.estrogenuinely.ca`.
- Nothing else runs on it. No Docker.
- Uptime was about 10 weeks.
- Time zone is `America/Toronto` (it was UTC until 2026-10-11).

Updates (set up 2026-10-11):
- **Debian packages:** apt uses the CSC mirror, `https://mirror.csclub.uwaterloo.ca/debian` and `/debian-security`, configured in `/etc/apt/sources.list.d/debian.sources`. The Armbian repos still use Armbian's own servers because the CSC mirror doesn't carry them. The original file is backed up at `/root/debian.sources.bak-20261011`.
- **Automatic apt upgrades:** the `unattended-upgrades` package runs daily and accepts packages from every origin (Debian, security, Armbian). Config is in `/etc/apt/apt.conf.d/52unattended-upgrades-local`, which overrides Armbian's `02-armbian-periodic` that had apt's periodic jobs disabled. It never reboots automatically, so kernel updates take effect after a manual reboot. Logs are in `/var/log/unattended-upgrades/`.
- **Technitium and .NET:** these are not apt packages. A `technitium-update.timer` runs `technitium-update.service` weekly (Sunday 04:30 local time, with up to 15 minutes of random delay). The service runs Technitium's official `install.sh`, which updates the .NET runtime in `/opt/dotnet` and the app in `/opt/technitium/dns`, then restarts `dns.service`. DNS drops for a few seconds on each run. Before each run it saves `/etc/dns` and `/opt/technitium/dns` to `/var/backups/technitium-pre-update.tgz`, overwriting the previous backup (about 43 MB).
  - Run it manually with `systemctl start technitium-update.service`.
  - Check the schedule with `systemctl list-timers technitium-update.timer`.
  - The installer's output is in `/opt/technitium/dns/install.log`.
  - It always installs the newest release, so there's no rollback other than restoring the backup tarball.

## satsuma (main server)

Config is a flake in `/etc/nixos` (a git repo that is pushed to GitHub). The flake also defines two other hosts: `tangerine` (laptop) and `mail` (VPS).

Layout:
- `flake.nix`: inputs are nixpkgs-unstable and agenix.
- `common.nix`: shared by all hosts. Contains the users, SSH (root login by key only), Tailscale, and fish.
- `lena.nix`: user for Lena.
- `satsuma/`: one `.nix` file per service. Secrets are agenix `.age` files in `satsuma/secrets/`.

Hardware:
- 32 threads, 29 GB RAM.
- ZFS pool `zpool`: mirror of 2x 3.5 TB NVMe. It holds `/`, `/nix`, `/var` and `/home`. Each NVMe has its own EFI partition, and a service syncs the primary `/boot` to the backup one.
- ZFS pool `hdd`: raidz1 of 4x 7.3 TB HDD (29 TB raw, about 10 TB used). Datasets are `data`, `mediaSrv` and `backup`. Drives spin down after 30 minutes idle.
- Tuned for low power (TLP, powersave governor, `zfs_txg_timeout=30`).
- Kernel is the newest ZFS-compatible one. The system auto-upgrades at 04:00 with `allowReboot = false`, commits `flake.lock`, and pushes it to GitHub.

Services (all native NixOS modules, no containers):

| Service                                | Notes                                                                                                                               |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| nginx                                  | Reverse proxy for everything. Wildcard ACME certs for `ruihuang.io` and `estrogenuinely.ca` (incl. `*.local.*`) via Cloudflare DNS. |
| Kanidm                                 | SSO/IdM at `idm.estrogenuinely.ca`. LDAPS (3636) is reachable over Tailscale only.                                                  |
| Nextcloud (v35) + Collabora            | Files and office documents. Logs in through Kanidm OIDC.                                                                            |
| Immich                                 | Photos.                                                                                                                             |
| Paperless-ngx                          | Documents. Internal URL only.                                                                                                       |
| Vaultwarden                            | Password manager.                                                                                                                   |
| Matrix Synapse                         | `matrix.estrogenuinely.ca`, with mautrix-wsproxy for the SMS/iMessage bridges. Logs in through Kanidm OIDC.                         |
| Jellyfin                               | Hardware transcoding enabled.                                                                                                       |
| Sonarr, Radarr, Prowlarr, FlareSolverr | The arr stack.                                                                                                                      |
| qBittorrent                            | Runs inside a network namespace with a PIA WireGuard VPN (Toronto, port forwarding).                                                |
| PostgreSQL                             | Shared by Nextcloud, Immich, Paperless, Vaultwarden, Synapse and the arr apps.                                                      |
| Postfix                                | Internal mail relay through Proton SMTP. It accepts mail from the LAN and tailnet.                                                  |
| NFS                                    | Port 2049, ZFS `sharenfs`: `mediaSrv` to the LAN (Mac mini), `data`/`backup` to pomelo. See [[NFS]].                                |
| Tailscale                              | Acts as a subnet router/exit node ("server" routing features).                                                                      |

Reverse-proxied hosts on other machines: `home.estrogenuinely.ca` goes to Home Assistant (10.0.10.74:8123), and `dns.local.estrogenuinely.ca` goes to orange (:5380).

Firewall allows TCP 25, 80, 443, 1313 and 2049, plus the Tailscale interface.

Backups:
- **Snapshots:** sanoid takes hourly, daily, weekly and monthly snapshots of `zpool/var`.
- **Replication:** syncoid copies them to `hdd/backup/var` once a day.
- **Databases:** a nightly `pg_dump` (03:00) of every database. Restic then pushes the dumps over SFTP/Tailscale to the mail VPS at 03:20, keeping 14 daily, 8 weekly and 12 monthly.
- **Boot:** the primary EFI partition is mirrored to the backup one (see Hardware).
- Details are in [[Backup]].

## mac-mini

- Apple M4, 16 GB RAM, 228 GB disk (15% used), macOS 15.7. Set to restart automatically after a power failure, and never sleeps.
- User `rhuang`. The default shell is fish.
- **mautrix-imessage** (`~/mautrix-imessage`): Matrix to iMessage bridge. It connects to Synapse on satsuma. See [[SMS Matrix Bridge]].
- **Sunshine** (Homebrew formula): game-streaming host.
- **Jellyfin.app** and **BlueBubbles** (Homebrew casks) are installed.
- 1Password and Parsec are also installed.
- `~/NAS/mediaSrv` is an autofs mount of satsuma's `mediaSrv` over NFS.
- Homebrew packages are mostly ffmpeg, Go, cmake and other media libs.

## homeassistant

- Home Assistant OS 18.3 on generic x86-64 (nvme disk, 15 GB RAM, 213 GB free). Core 2026.10.1, Supervisor 2026.09.3.
- Two network interfaces: `eno1` on the main LAN (10.0.10.74, DHCP, DNS from orange) and `eno1.20`, a static VLAN 20 interface (10.0.20.10/24, probably for IoT devices).
- USB radios: Sonoff Zigbee 3.0 dongle and a Zooz 800 Z-Wave stick.
- Apps running: Matter Server, Z-Wave JS, Advanced SSH & Web Terminal, Studio Code Server. The "HassOS SSH port 22222 Configurator" app is stopped (it has already enabled the port 22222 host SSH).
- Automatic daily partial backups.
- Exposed through satsuma's nginx at `home.estrogenuinely.ca`.

---

## How it fits together

- **DNS:** orange serves the LAN. The `*.local.*` names resolve to satsuma.
- **Remote access:** Tailscale on satsuma, the mail VPS and tangerine. Not installed on orange, the Mac mini or Home Assistant.
- **Identity:** Kanidm on satsuma is the single sign-on for Nextcloud and Matrix.
- **Desktop storage:** pomelo mounts `backup`, `data` and `mediaSrv` at `~/NAS` over NFS. See [[NFS]].
- **Not in the IP table:** the `mail` VPS (Tailscale 100.91.236.114) runs Stalwart mail and is also the offsite backup target. It is defined in the same flake. See [[Stalwart]].

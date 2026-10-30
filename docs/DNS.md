# DNS (orange)

Internal DNS for the homelab. **orange** (`10.0.10.23`) runs
[Technitium DNS Server](https://technitium.com/dns/) and is both the recursive
resolver for the LAN and the authoritative server for the internal
`local.estrogenuinely.ca` zone.

See [[Setup Overview]] for the host and [[Monitoring]] for the health probes.
The 2026-10-30 clock/DNSSEC outage is written up at the bottom of this note
([[#Incident: 2026-10-30 — clock skew, DNSSEC SERVFAIL, full /var/log]]).

## At a glance

| Thing | Value |
| ----- | ----- |
| Host | `orange`, `10.0.10.23` (Armbian 26.11 / Debian 13 trixie, aarch64) |
| Software | Technitium DNS Server v15.6.2 |
| Unit | `dns.service` (runs as user `dns-server`) |
| Ports | `53/udp` + `53/tcp` (DNS), `5380/tcp` (web console) |
| Web console | <http://10.0.10.23:5380> and <https://dns.local.estrogenuinely.ca> |
| Config | `/etc/dns` (binary `.config`/`.zone` files — edit via the UI) |
| App / runtime | `/opt/technitium/dns`, .NET in `/opt/dotnet` |
| Upstreams | `8.8.8.8`, `8.8.4.4` (Google), recursion + DNSSEC validation on |
| Authoritative zone | `local.estrogenuinely.ca` (SOA/NS `orange.`, serial 23) |
| Blocklists | StevenBlack hosts + Hagezi light (wildcard), ~74k domains |
| Logs | `/var/log/technitium/dns/YYYY-MM-DD.log` |
| Updates | `technitium-update.timer`, Sundays 04:30 ±15 min |

## Architecture

```
LAN clients ──:53──► orange (Technitium)
                        │
                        ├── authoritative: local.estrogenuinely.ca
                        ├── cache (persisted to /etc/dns/cache.bin)
                        ├── blocklists (StevenBlack + Hagezi light)
                        └── recursion ──► 8.8.8.8 / 8.8.4.4
                                             (DNSSEC validated)

browser ──https──► satsuma nginx ──► http://10.0.10.23:5380
                     (dns.local.estrogenuinely.ca,
                      ACME cert incl. *.local.estrogenuinely.ca)
```

`orange`'s own `/etc/resolv.conf` is `nameserver 127.0.0.1`, so the host uses
Technitium for everything too.

## Zones and records

Only `local.estrogenuinely.ca` is live. A `local.ruihuang.io` zone file exists
in `/etc/dns/zones` (dated 2026-10-10) but queries currently return
`NXDOMAIN`; treat `estrogenuinely.ca` as the active internal domain.

Verified records (2026-10-30):

| Name | Type | Answer | What |
| ---- | ---- | ------ | ---- |
| `satsuma` | A | `10.0.10.72` | main server |
| `celosia` | A | `10.0.10.42` | Lena's desktop |
| `hibiscus` | A | `10.0.10.43` | Lena's laptop |
| `hermes` | CNAME | `satsuma` | service alias |
| `grafana` | CNAME | `satsuma` | service alias |
| `grove` | CNAME | `satsuma` | service alias |
| `immich` | CNAME | `satsuma` | service alias |
| `jellyfin` | CNAME | `satsuma` | service alias |
| `mautrix-wsproxy` | CNAME | `satsuma` | service alias |
| `paperless` | CNAME | `satsuma` | service alias |
| `dns` | CNAME | `satsuma` | web UI alias (nginx) |

Characteristics:

- The zone is **unsigned** (no RRSIGs). Local names are LAN-only; DNSSEC
  problems upstream do not affect them — which is exactly why an external
  failure can look like "the LAN is fine".
- The tags `*.local.estrogenuinely.ca` are covered by the satsuma ACME
  certificate, so `https://<service>.local.estrogenuinely.ca` works without a
  per-host cert.
- Full record management is through the web console. Do not hand-edit the
  binary `.zone` files.
- `orange` itself has no A record in the zone; clients use `10.0.10.23`.

## Resolution and filtering

- Recursion is enabled for the LAN; upstream forwarders are Google
  `8.8.8.8`/`8.8.4.4`.
- **DNSSEC validation is on.** To confirm it is actually validating, query
  `dnssec-failed.org`: it must return `SERVFAIL`. If that name resolves, the
  validator is off, not "working".
- Blocklists:
  - `https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts`
  - `https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/light-onlydomains.txt`
  - About 74k domains, refreshed daily; the active set is in
    `/etc/dns/blocklists`.
- Cache is written to `/etc/dns/cache.bin` on shutdown and restored on start.

## Web console

- Direct: <http://10.0.10.23:5380> (port 5380 is open on the LAN).
- Nice URL: <https://dns.local.estrogenuinely.ca>, proxied by satsuma nginx to
  `http://10.0.10.23:5380`.
- Authentication is Technitium's own user database (`auth.config`), not
  Kanidm. Users/groups: administrators, DNS administrators, DHCP
  administrators, everyone.

## Service layout and management

```bash
systemctl status dns                # state, PID, memory
journalctl -u dns -n 100 --no-pager
systemctl restart dns               # a few seconds of DNS downtime
ss -lntup | grep -E ':53 |:5380 '
```

- Unit: `/etc/systemd/system/dns.service`
- Binary: `/usr/bin/dotnet /opt/technitium/dns/DnsServerApp.dll /etc/dns`
- Sandboxing: `ProtectSystem=strict`, `PrivateDevices=true`,
  `ProtectClock=true`, `NoNewPrivileges=true`, `CAP_NET_BIND_SERVICE` only.
- Writable paths for the service: `/etc/dns` and
  `/var/log/technitium/dns`.

## Updates

`technitium-update.timer` runs `technitium-update.service` weekly
(Sunday 04:30, `RandomizedDelaySec=15min`, `Persistent=true`).

The service:

1. tars `/etc/dns` + `/opt/technitium/dns` to
   `/var/backups/technitium-pre-update.tgz` (overwrites the previous backup,
   ~43 MB);
2. runs Technitium's official `install.sh`, which updates .NET and the app;
3. restarts `dns.service` (a few seconds of downtime).

```bash
systemctl list-timers technitium-update.timer
systemctl start technitium-update.service
tail -f /opt/technitium/dns/install.log
```

There is only one rollback point (the tarball):

```bash
systemctl stop dns
tar xzf /var/backups/technitium-pre-update.tgz -C /
systemctl start dns
```

Debian packages are handled separately by `unattended-upgrades` (daily, never
reboots automatically).

## Time and DNSSEC (important)

DNSSEC validates RRSIG inception/expiry against the **local clock**. If the
clock is hours off, every recent signature looks "not yet valid" and all
external answers become `SERVFAIL` — while local zones keep working.

orange's RTC has no working backup, so after a long power-off the clock starts
at the last shutdown time. To keep that from breaking DNS:

- `systemd-timesyncd` uses **IP-literal** NTP servers
  (`/etc/systemd/timesyncd.conf.d/10-ip-ntp.conf`: Cloudflare
  `162.159.200.1`/`.123`, Google `216.239.35.0`/`.4`), so time sync never
  depends on the DNS it is needed to fix.
- `dns-clock-wait.service` runs `Before=dns.service`. It delays DNS startup
  only when the RTC is invalid or disagrees with the system clock; a normal
  reboot is not delayed. It is bounded (20 s) and starts DNS anyway if NTP is
  unreachable.
- `clock-watchdog.timer` restarts `systemd-timesyncd` if the clock stays
  unsynced (>3 min after boot, at most every 15 min).

Quick check:

```bash
timedatectl show -p NTPSynchronized -p TimeUSec -p RTCTimeUSec
systemctl status dns-clock-wait clock-watchdog.timer
```

Replacing the RTC coin cell would remove the root cause entirely.

## Logging and disk

- One file per day: `/var/log/technitium/dns/YYYY-MM-DD.log`.
- `/var/log` is a **128 MB zram ext4** (Armbian log2ram,
  `/etc/default/armbian-ramlog`), mirrored to `/var/log.hdd`. Journald is on
  the disk mirror, not in zram.
- `/etc/logrotate.d/technitium-dns` caps the logs at 8 MB (`maxsize`, 2
  compressed rotations, `copytruncate`). Technitium dumps a full stack trace
  per failed query, so without a cap an error storm can fill zram.
- If `/var/log` ever fills, clear **both** `/var/log/technitium/dns/*.log` and
  `/var/log.hdd/technitium/dns/*.log`; otherwise log2ram restores the big file
  into zram at the next boot.

```bash
df -h /var/log
du -sh /var/log/technitium/dns /var/log.hdd/technitium/dns
logrotate -d /etc/logrotate.d/technitium-dns
```

## Monitoring

On satsuma, blackbox probes cover:

- DNS: queries `jellyfin.local.estrogenuinely.ca` through `10.0.10.23:53` and
  requires `10.0.10.72`.
- Web UI: `GET http://10.0.10.23:5380/`.

**Known gap:** the DNS probe uses a *local, unsigned* name. During the
2026-10-30 outage it stayed green while every external lookup was `SERVFAIL`.
A second probe for a DNSSEC-signed public name (e.g. `cloudflare.com` or
`dns.google` through orange) would catch clock/DNSSEC failures. See
[[Monitoring]].

## Runbook

Checks:

```bash
ssh orange
systemctl status dns
journalctl -u dns -n 50 | grep -iE "dnssec|attack|space|error"
timedatectl
df -h /var/log

# from anywhere on the LAN:
dig @10.0.10.23 satsuma.local.estrogenuinely.ca A     # local zone
dig @10.0.10.23 cloudflare.com A                      # recursion
dig @10.0.10.23 dnssec-failed.org A                   # must be SERVFAIL
```

Symptom → cause:

| Symptom | Likely cause | Check |
| ------- | ------------ | ----- |
| LAN names work, external names `SERVFAIL` | clock skew breaking DNSSEC | `timedatectl` |
| All names fail, port 53 open | upstream/recursion broken | forwarders, `dig @8.8.8.8` |
| `NXDOMAIN` for a known LAN name | record/zones changed | web console |
| Web UI up, DNS down (or vice versa) | service/port bind issue | `journalctl -u dns`, `ss` |
| Log errors `No space left on device` | `/var/log` zram full | `df -h /var/log` |

Manual clock fix (if it is clearly wrong and NTP is not correcting it):

```bash
timedatectl show -p NTPSynchronized -p TimeUSec
systemctl restart systemd-timesyncd
# last resort: step it, NTP will hold it afterwards
date -u -s @$(date -u +%s)
systemctl restart dns
```

Restart / flush:

```bash
systemctl restart dns          # also reloads config
# cache flush: web console → Cache → Flush, or restart
```

---

## Incident: 2026-10-30 — clock skew, DNSSEC SERVFAIL, full /var/log

Post-mortem of the outage that led to the time/clock hardening above.

| Thing | Value |
| ----- | ----- |
| Symptom | Every external lookup `SERVFAIL`; local zones still worked |
| Immediate cause | System clock **4 h 2 min slow** → `SignatureNotYetValid` |
| Underlying cause | RTC has no working backup; clock restored from last shutdown |
| Why it stayed broken | `systemd-timesyncd` resolved NTP names through the broken DNS |
| Second failure | DNSSEC error storm wrote a 359 MB log into the 50 MB zram `/var/log` |
| Detected / fixed | 2026-10-30 ~04:17 UTC / ~04:20 UTC |

### Timeline (UTC)

| Time | Event |
| ---- | ----- |
| 2026-10-29 00:08:39 | Last clean shutdown; time saved by `systemd-timesyncd` |
| 2026-10-30 00:08:39 | Board powered off for **4 h 01 min** (RTC loses time) |
| 2026-10-30 04:10:07 | Boot; clock restored to 00:08:39, i.e. 4 h behind |
| 04:17–04:19 | Diagnosed: `SERVFAIL`, `EDE 8 Signature Not Yet Valid`, unsynced clock |
| 04:20:01 | Clock stepped to correct time; NTP syncs immediately |
| 04:20:19 | NTP switched to IP-literal servers; DNS healthy |
| 04:24–04:28 | Boot gate, watchdog, logrotate, 128 MB ramlog; giant logs removed |
| 04:25 | Fault injection: clock set 4 h back → DNS self-healed in 4 s |
| 04:30 / 04:33 | Reboot tests; normal boot no longer waits, DNS starts immediately |

### Root cause

The RTC (`rtc-hym8563`) had lost its values on the cold boot:

```
rtc-hym8563 15-0051: no valid clock/calendar values available
rtc-hym8563 15-0051: hctosys: unable to read the hardware clock
```

`fake-hwclock.service` is masked, so the clock came from
`systemd-timesyncd`'s recorded timestamp — the **last shutdown time**, not the
current time:

```
System clock time advanced to recorded timestamp: Thu 2026-10-29 20:08:40 EDT
```

Four hours off is enough for Technitium's DNSSEC validator to reject every
freshly signed RRSIG:

```
status: SERVFAIL
EDE: 8 (Signature Not Yet Valid): (Attack detected! com SOA IN)
```

### Why NTP did not fix it (the deadlock)

`/etc/resolv.conf` points at `127.0.0.1` (Technitium). `systemd-timesyncd`
therefore had to resolve its pool names through the resolver that the bad clock
had broken:

```
RTC lost ──► clock 4 h slow ──► DNSSEC rejects signatures ──► SERVFAIL
                    ▲                                            │
                    │                                            ▼
                    └──── no NTP ◄──── cannot resolve pool.ntp.org
```

The journal showed only repeated `Network configuration changed, trying to
establish connection.` and attempts like
`1.nixos.pool.ntp.org.local.ruihuang.io` (search domain appended), which
Technitium answered with `SERVFAIL`. Stepping the clock by hand broke the loop
instantly; `timesyncd` then contacted `0.debian.pool.ntp.org` and synced.

### Why the log was 359 MB

Technitium writes a full multi-line .NET exception (stack trace, ~2–4 KB) for
**every** failed query. During the bad-clock window this happened thousands of
times (3,493 `DNSSEC validation failed` lines in the portion examined):

- `/var/log/technitium/dns/2026-10-29.log` — 359 MB on the disk mirror
- `/var/log/technitium/dns/2026-10-30.log` — 14 MB and growing

`/var/log` is a 50 MB zram ext4 (log2ram, `/dev/zram1`, mirrored to
`/var/log.hdd`). It hit 100 %, and Technitium started throwing:

```
System.IO.IOException: No space left on device : '/var/log/technitium/dns/2026-10-30.log'
```

The 359 MB copy on `/var/log.hdd` would have been rsynced back into zram on the
next boot, refilling it every time. Both copies had to be deleted.

### Fixes applied

| Change | Purpose |
| ------ | ------- |
| `/etc/systemd/timesyncd.conf.d/10-ip-ntp.conf` | NTP by IP (Cloudflare/Google); no DNS dependency |
| `/etc/systemd/timesyncd.conf.d/20-tuning.conf` | `ConnectionRetrySec=10`, poll 16–1024 s |
| `dns-clock-wait.service` + `/usr/local/sbin/wait-for-clock` | bounded boot gate; skips when RTC agrees |
| `dns.service.d/clock-wait.conf` | `Wants`/`After` the gate |
| `clock-watchdog.service` + timer | restart `timesyncd` if clock stays unsynced |
| `/etc/logrotate.d/technitium-dns` | 8 MB cap, 2 compressed rotations, `copytruncate` |
| `/etc/default/armbian-ramlog` | `SIZE=50M` → `128M` (applies on boot) |
| log cleanup | removed incident logs from zram **and** `/var/log.hdd` |

Details of the gate:

1. If a valid RTC exists and agrees with the system clock (≤ 5 min), exit
   immediately — normal reboots are not delayed.
2. Otherwise wait up to 20 s for sync.
3. Once a default route exists, restart `systemd-timesyncd` once so it polls
   immediately instead of waiting for its retry timer.
4. On timeout, log and start DNS anyway (NTP unreachable must not take DNS
   down with it).

### Verification

Fault injection (clock 4 h back, `timesyncd` stopped, sync flag removed):

```
system=1793320389 rtc=1793334790        # 4 h disagreement detected
dns restart took 4s (includes waiting for sync)
now: Fri Oct 30 04:33:13 AM UTC 2026    # correct
```

Reboot tests:

- Normal reboot: `dns-clock-wait` finishes in the same second; DNS starts
  immediately.
- `/var/log` comes up at 120 MB usable, ~3 MB used.
- `google.com`, `github.com`, `amazon.com` resolve; `jellyfin.local...` still
  returns `10.0.10.72`; `dnssec-failed.org` still `SERVFAIL` (validation is
  active, not disabled).

### Remaining risk

- The RTC still has no working backup. A long unplug boots with a stale clock,
  but NTP over IP plus the boot gate now correct it in seconds. **Replacing
  the RTC coin cell removes the root cause.**
- The watchdog restarts `timesyncd`; it does not fix a blocked UDP 123 path
  (outbound NTP is currently allowed).
- The existing blackbox DNS probe uses a local name and did not alert; a
  DNSSEC-signed probe is still to be added (see [[Monitoring]]).

## Files on orange

| Path | Purpose |
| ---- | ------- |
| `/etc/systemd/timesyncd.conf.d/10-ip-ntp.conf` | NTP by IP |
| `/etc/systemd/timesyncd.conf.d/20-tuning.conf` | retry/poll tuning |
| `/etc/systemd/system/dns-clock-wait.service` | boot gate |
| `/etc/systemd/system/dns.service.d/clock-wait.conf` | ordering for the gate |
| `/etc/systemd/system/clock-watchdog.service` | watchdog oneshot |
| `/etc/systemd/system/clock-watchdog.timer` | watchdog schedule |
| `/usr/local/sbin/wait-for-clock` | gate logic |
| `/usr/local/sbin/clock-watchdog` | watchdog logic |
| `/etc/logrotate.d/technitium-dns` | log cap |
| `/etc/default/armbian-ramlog` | `SIZE=128M` |

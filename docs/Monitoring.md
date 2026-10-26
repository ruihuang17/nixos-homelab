# Monitoring (Prometheus + Grafana)

`kiro-cli --resume-id 3810a146-7c1d-4671-863b-30f1854a2bc2`

Set up 2026-10-11. Metrics for every server/host are collected by **Prometheus**
on satsuma and visualised in **Grafana**. Each host runs a **node_exporter** that
Prometheus scrapes on port **9100**. See [[Setup Overview]] for the host table and
[[IP Address]] for addresses.

## At a glance

| Component     | Where         | Address               | Exposed as                                   |
| ------------- | ------------- | --------------------- | -------------------------------------------- |
| Prometheus    | satsuma       | `127.0.0.1:9090`      | `prometheus.local.estrogenuinely.ca` (nginx) |
| Grafana       | satsuma       | `127.0.0.1:3000`      | `grafana.local.estrogenuinely.ca` (nginx)    |
| node_exporter | satsuma       | `127.0.0.1:9100`      | local only                                   |
| node_exporter | orange        | `10.0.10.23:9100`     | LAN                                          |
| node_exporter | lime          | `10.0.10.73:9100`     | LAN                                          |
| node_exporter | homeassistant | `10.0.10.74:9100`     | LAN                                          |
| node_exporter | mail (VPS)    | `100.91.236.114:9100` | **tailnet only**                             |

Prometheus scrapes every 30 s and keeps 90 days of history. All six targets
(the five hosts plus Prometheus scraping itself) report `up`.

## Access

- Grafana: <https://grafana.local.estrogenuinely.ca> — these `*.local.*` names
  resolve to satsuma via orange's DNS, and use the `estrogenuinely.ca` wildcard
  ACME cert. Internal only (not reachable from the public internet).
- Prometheus UI: <https://prometheus.local.estrogenuinely.ca> 
- Grafana login: click **Sign in with Kanidm** (OIDC, see below). The local
  `admin` user remains as a break-glass login; its password is stored encrypted
  with agenix at `satsuma/secrets/grafana_admin_pass.age` 
- The pre-provisioned dashboard is **Node Exporter Full** (Grafana dashboard
  1860). Pick a host from the `instance` dropdown (satsuma / orange / lime /
  homeassistant / mail).

## How it's configured

Everything on satsuma is declared in the NixOS flake at `/etc/nixos` (see
[[Setup Overview]] → satsuma).

### satsuma — `satsuma/monitoring.nix`

- `services.prometheus` on `127.0.0.1:9090`, 90 day retention, 30 s scrape
  interval. One `node` job with a static target per host (each tagged with an
  `instance` label), plus a `prometheus` self-scrape job.
- `services.grafana` on `127.0.0.1:3000`:
  - `admin_password` and `secret_key` are both read at runtime from agenix
    secrets via Grafana's `$__file{...}` provider, so neither lands in the Nix
    store. (`secret_key` is mandatory on current nixpkgs — Grafana no longer
    ships a default.)
  - The Prometheus datasource is provisioned with a fixed `uid = "prometheus"`.
  - The dashboard is provisioned from `satsuma/grafana-dashboards/`. The JSON was
    downloaded from grafana.com (1860), its `${DS_PROMETHEUS}` placeholders were
    rewritten to the `prometheus` datasource uid, and the `__inputs`/`__requires`
    blocks were stripped so it imports without prompting.
- node_exporter for satsuma itself comes from the shared module below.

### Single sign-on (Kanidm OIDC)

Same pattern as Nextcloud and Matrix (see [[Setup Overview]] → Identity).

- Kanidm OAuth2 client `grafana` (landing page and redirect URL
  `https://grafana.local.estrogenuinely.ca/login/generic_oauth`, strict redirect
  matching). Scope map: `homelab_user` → `openid profile email groups`. Created
  with `kanidm system oauth2 create grafana ...`; the Kanidm side is not in the
  flake, only in Kanidm's database.
- Grafana side is `auth.generic_oauth` in `satsuma/monitoring.nix`. PKCE is on
  (Kanidm requires it). The client secret is the agenix file
  `satsuma/secrets/grafana_oidc_secret.age`, read through `$__file{}`.
- Roles come from the `groups` claim: members of `homelab_admin` get Grafana
  **Admin**, any other `homelab_user` gets **Viewer**
  (`role_attribute_strict = true`, so a login with no matching role is refused).
  New Grafana users are created on first login.
- To rotate the secret: `kanidm system oauth2 reset-secrets grafana`, re-encrypt
  `grafana_oidc_secret.age`, rebuild.
- Verified: Grafana redirects to Kanidm with the right client, redirect URI,
  scopes and PKCE; Kanidm accepts the request; the stored secret authenticates at
  the token endpoint (a wrong secret gets 401). A full browser login has **not**
  been tested yet, so check that `rhuang` lands as Admin and a non-admin
  `homelab_user` as Viewer.

### Homelab Overview dashboard — `satsuma/monitoring-overview.nix`

One page with the status of every machine and service
(`https://grafana.local.estrogenuinely.ca/d/homelab-overview`). It is
**generated from a service catalog** at the top of `monitoring-overview.nix`, and
that same catalog also produces the probes and recording rules, so adding a
service means adding one line to `services` and rebuilding.

How a service is checked (`type` in the catalog):

| type | Check | Used for |
| ---- | ----- | -------- |
| `http` | blackbox GET, any 2xx after redirects | web apps, via their health endpoints |
| `tcp` | blackbox TCP connect | nginx, PostgreSQL, NFS, Postfix, Stalwart SMTP/IMAP |
| `dns` | blackbox asks orange for `jellyfin.local.estrogenuinely.ca` and requires `10.0.10.72` | Technitium (a real answer, not just an open port) |
| `systemd` | node_exporter says the unit is `active` | things with no reachable port: qBittorrent (inside the VPN netns), PIA VPN, Tailscale, Immich ML, wsproxy (mautrix-wsproxy) |

Every check ends up as one series, `homelab:service_up{service,host,group,check}`
(1 = up, 0 = down), recorded every 30 s. A missing probe, unit or host counts as
**down**, not as "no data". The blackbox exporter runs on satsuma at
`127.0.0.1:9115`.

Panels: machines/services/failed-units/ZFS/cert summary tiles, a machines table
(status, uptime, CPU, memory, disk; click a name for Node Exporter Full), one tile
group per service category, a 24 h status history, slowest checks, TLS
certificate lifetime left (`*.estrogenuinely.ca`, `*.ruihuang.io`, mail), and a
failed-units list.

Things to know:
- Service names are kept short so each tile's name fits on one line (Grafana
  left-aligns wrapped text). The tile text sizes are in `groupPanel`; the name is
  deliberately larger than the UP/DOWN text.
- **Temporary shim:** on 2026-10-11 "Matrix Synapse", "mautrix-wsproxy" and "PIA
  port forward" were renamed to "Synapse", "wsproxy" and "PIA forward". The history
  query (`renamed` / `historyExpr` in `monitoring-overview.nix`) folds the old names
  into the new ones so each keeps one row. Delete that shim after 2026-10-13, once
  the old names have aged out of the 24 h view.
- **29 services** are covered. **lime** runs node_exporter and Jellyfin; satsuma
  probes Jellyfin directly at `http://10.0.10.73:8096/health`. The iMessage bridge
  and Sunshine are not probed.
- The Kanidm, Nextcloud and Collabora checks go through nginx (they resolve to
  localhost via `/etc/hosts`), so they also catch certificate and proxy problems.
  The rest check the backend directly, so an orange DNS outage doesn't turn
  everything red.
- The service history starts when the rules were created (2026-10-11 ~22:45), so
  the 24 h view fills in gradually.
- **orange's node_exporter now runs with `--collector.systemd`** (edited in its unit
  file) so failed units on orange are counted too.
- `prometheus.local.estrogenuinely.ca` has **no DNS record on orange** (unlike
  `grafana.local`), so that URL doesn't resolve from the LAN yet; add the record in
  Technitium if you want it.

### nginx — `satsuma/nginx.nix`

Two internal vhosts were added, both using the `estrogenuinely.ca` wildcard
cert:

- `grafana.local.estrogenuinely.ca` → `http://127.0.0.1:3000` (websockets on,
  Grafana Live needs them).
- `prometheus.local.estrogenuinely.ca` → `http://127.0.0.1:9090`.

### Shared server module — `server-common.nix` (flake root)

A new module, imported by **satsuma** and **mail** (not the tangerine laptop),
that provisions node_exporter consistently. It defines the option group
`homelab.nodeExporter`:

| Option | Default | Purpose |
| ------ | ------- | ------- |
| `enable` | `true` | Turn the exporter on. |
| `listenAddress` | `127.0.0.1` | Bind address. |
| `port` | `9100` | Listen port. |
| `openFirewallTailscale` | `false` | If true, open the port **only** on `tailscale0`. |

The exporter runs the `systemd` and `processes` collectors in addition to the
defaults. satsuma uses the loopback default (Prometheus scrapes it locally).

### mail / VPS — `vps/configuration.nix`

mail is public-facing, so its exporter is tailnet-only:

```nix
homelab.nodeExporter = {
  listenAddress = "0.0.0.0";
  openFirewallTailscale = true;
};
```

Binding `0.0.0.0` is safe because the NixOS firewall default-denies and only
accepts `9100` on `tailscale0`. Prometheus on satsuma reaches it at the
tailnet address `100.91.236.114:9100`. Verified with
`nft`/`iptables`: the only rule is `-i tailscale0 ... --dport 9100 accept`.

## node_exporter per host

The three non-NixOS hosts don't use the flake, so they were set up by hand.

### orange (Debian / aarch64) — systemd

- Binary `node_exporter` v1.12.1 at `/usr/local/bin/node_exporter`
  (official linux-arm64 release, not an apt package — consistent with how
  Technitium is handled there, see [[Setup Overview]] → orange).
- Runs as a dedicated `node_exporter` system user via
  `/etc/systemd/system/node_exporter.service` (hardened: `NoNewPrivileges`,
  `ProtectSystem=strict`, `ProtectHome`, etc.), enabled and listening on `:9100`.
- Update later by replacing the binary and `systemctl restart node_exporter`.

### lime (macOS / arm64) — Homebrew

- Installed with `brew install node_exporter` and started with
  `brew services start node_exporter` (LaunchAgent
  `~/Library/LaunchAgents/sh.brew.node_exporter.plist`, restarts at login).
- Listens on `*:9100`. Homebrew lives at `/opt/homebrew/bin/brew`.

### homeassistant (HAOS / x86-64) — Docker

- HAOS's host OS is immutable, so the exporter runs as a Docker container on the
  host:
  ```
  docker run -d --name node_exporter --restart unless-stopped \
    --net host --pid host -v /:/host:ro,rslave \
    quay.io/prometheus/node-exporter:v1.12.1 \
    --path.rootfs=/host --web.listen-address=:9100
  ```
- `--net host --pid host` plus the read-only root mount make it report the real
  host's metrics. `--restart unless-stopped` survives reboots.
- Note: the Supervisor may list this unmanaged container as "unsupported"; it
  won't remove it. If HAOS ever does, re-run the command above (host SSH is on
  port 22222).

## Common operations

- Check scrape health:
  `curl -s http://127.0.0.1:9090/api/v1/query?query=up` on satsuma, or the
  Prometheus UI → *Status → Targets*.
- Add a new host: install node_exporter on it (systemd/brew/docker as above, or
  for a NixOS server just import `server-common.nix`), then add a target entry to
  the `node` job in `satsuma/monitoring.nix` and `nixos-rebuild switch`.
- Rotate the Grafana admin password: re-encrypt
  `satsuma/secrets/grafana_admin_pass.age` with agenix and rebuild.

## Alerting

Set up 2026-10-15. Grafana's built-in **unified alerting** evaluates rules
against Prometheus and notifies on two channels — **email** and **Matrix** —
plus a separate **VPS dead-man's-switch** that catches satsuma itself going down.
All of it is provisioned from the flake. Mail goes out through our own server
(see [[System Mail (Alerts)]]).

### Channels

| Channel | How | Reaches you when… |
| ------- | --- | ----------------- |
| Email → `rui@estrogenuinely.ca` | Grafana SMTP as `homelab-svc` via `mail.estrogenuinely.ca:587` → SES | anything except satsuma fully down |
| Matrix → `homelab-alerts` room | Grafana webhook → `matrix-alertmanager-receiver` → Synapse | anything except satsuma down (Synapse runs on satsuma) |
| Email (VPS watcher) | the `mail` VPS pings satsuma; emails via its local Stalwart → SES | **satsuma itself is down** |

The Matrix room is `#homelab-alerts` (`!k9Y9GnXSOfor4J0h6PqDJWBfSyCw889EYbcbbXyUAVs`),
posted to by the bot `@homelab-alertbot:estrogenuinely.ca`. rhuang is invited.

### satsuma — `satsuma/monitoring.nix`

- `services.grafana.settings.smtp`: host `mail.estrogenuinely.ca:587`, user
  `homelab-svc`, from `alerts@estrogenuinely.ca`, `MandatoryStartTLS`. Password
  from the agenix secret `grafana_mail_pass` (= `mail_pass.age`, the homelab-svc
  password), read via `$__file{}` so it never lands in the store.
- `services.grafana.provision.alerting` (there is **no** `.enable` option —
  defining `.contactPoints/.policies/.rules.settings` is what turns it on):
  - **Contact point `homelab`** with two integrations: `email` (rui@) and
    `webhook` → `http://127.0.0.1:9686/alerts/homelab` (the Matrix receiver).
  - **Policy**: root route → `homelab`, grouped by `alertname`+`instance`.
  - **Rules** (folder *Homelab*, group `homelab-core`, 1 m interval), built by the
    `mkRule`/`mkFiringData` helpers (query A → reduce last B → threshold C `> 0`):
    - **Host down** — `up{job="node"} == 0` (orange / lime / homeassistant /
      mail; 3 m).
    - **Service down** — `homelab:service_up == 0` (the recording rule from
      `monitoring-overview.nix`; 5 m).
    - **Filesystem almost full** — `/` on every host **plus satsuma's HDD pool
      `/hdd`** <10% free (15 m). Selector `mountpoint=~"/|/hdd"` so it ignores
      external/removable mounts (e.g. lime's `/Volumes/*`), APFS system
      volumes, bind-mounts, and per-dataset ZFS noise. On satsuma `/` is the SSD
      (ZFS root) and `/hdd` is the separate bulk-storage pool.

### satsuma — `satsuma/alerting.nix`

Runs `matrix-alertmanager-receiver` (metio, in nixpkgs) on `127.0.0.1:9686`. It
takes Grafana's webhook (Alertmanager-format) payloads and posts to the Matrix
room using the bot's access token (agenix `matrix_alertbot_token`, injected via
`EnvironmentFile`). `room-mapping` exposes the pretty name `homelab` →
the room ID. Firing/resolved message templates give the 🔥/✅ one-liners.

The bot was registered with `register_new_matrix_user` using a temporary
`registration_shared_secret`, which is now kept (declaratively, via
`services.matrix-synapse.extraConfigFiles` + agenix
`synapse_registration_secret`) so future service bots can be provisioned the
same way. See [[SMS Matrix Bridge]] for the Synapse setup.

### mail / VPS — `vps/satsuma-watcher.nix`

The one thing Grafana can't do: tell you satsuma is down (Grafana, Synapse and
Postfix all run on satsuma). A systemd timer on the **mail** VPS runs every 2
minutes and `tailscale ping`s satsuma (`100.72.25.50`) — ping, not
node_exporter, because satsuma's exporter is loopback-only and unreachable from
the VPS. After `failThreshold = 3` consecutive misses it emails `rui@` via the
VPS's **local** Stalwart (auth `homelab-svc`, from `alerts@`), and emails again
on recovery. State lives in `/var/lib/satsuma-watcher`. This is **email-only**:
Matrix would be down too in this scenario, and the VPS→Stalwart→SES path is
independent of satsuma. Secret: `vps/secrets/homelab_svc_smtp.age`
(`SMTP_USER`/`SMTP_PASS`).

### Verified (2026-10-15)

- Grafana provisioned the contact point (email + webhook) and 3 rules; a
  transient always-firing rule delivered 🔥 to the `homelab-alerts` room **and**
  queued email through Stalwart → SES (*Delivery completed*).
- Matrix receiver: direct webhook POST → room message, no join errors (after
  fixing the room ID — this Synapse returns IDs without the `:server` suffix).
- VPS watcher: live run against an up satsuma is a clean no-op; a forced-failure
  run emailed FIRING on the 3rd miss and RESOLVED on recovery; the mailer must
  connect to `mail.estrogenuinely.ca` (not `127.0.0.1`) so the TLS cert matches.

### Gotchas

- `provision.alerting` has no `enable` — just define the `.settings`.
- The Matrix room ID here has **no `:server` suffix**; use the exact value from
  `/_matrix/client/v3/joined_rooms`.
- Grafana 13 removed the old contact-point test endpoints; test via
  `/apis/notifications.alerting.grafana.app/v1beta1/.../receivers/<uid>/test` or
  just let a rule fire.
- `pkgs.writers.writePython3` runs flake8 — keep one import per line, etc.
- The VPS watcher sends from `alerts@`; that is already allowed by Stalwart's
  `must-match-sender` exception for `homelab-svc` (see [[System Mail (Alerts)]]).

## Not done yet / ideas

- Alerting is live (email + Matrix + VPS satsuma-watcher). Still **dashboard-only
  for ZFS/cert specifics** — could add ZFS-pool and cert-expiry alert rules
  (the data already exists in the Homelab Overview).
- Only host-level metrics (node_exporter). Service-level exporters
  (PostgreSQL, nginx, ZFS, smartctl, etc.) could be added later.

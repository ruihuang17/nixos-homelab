# OpenCode Centralization (satsuma)

**Status:** operational since 2026-10-31 16:05 EDT. Rollout on `satsuma` with
the built-in web UI, reachable over the LAN/Tailnet at
`https://opencode.local.estrogenuinely.ca`.

## Goal

Run OpenCode once, on `satsuma`, so that every client (laptop TUI, browser web
UI, phone app) shares the same sessions, configuration, provider credentials,
and project workspaces. The server starts at boot, survives reboots, and is
upgraded with the rest of the NixOS configuration.

Non-goals:

- Multi-user accounts or per-user isolation.
- Running untrusted code for guests.
- Exposing an agent with shell access directly to the public internet.

OpenCode's server is **single-user**. Every client that knows the server
password sees every session and can run commands as the service user. Treat the
password like an SSH key.

## Architecture

```
laptop TUI  ─┐
browser     ─┼── HTTPS ──► nginx (satsuma:443, *.local.estrogenuinely.ca cert)
phone app   ─┘               │  allow 10.0.10.0/24, 100.64.0.0/10, loopback
                             ▼
                    127.0.0.1:4096   opencode serve  (user: opencode)
                             │
                             ├── /var/lib/opencode          sessions, auth, DB
                             ├── /srv/opencode/workspace    git checkouts
                             └── /run/agenix/opencode-password
```

No new firewall ports: nginx already owns 443, and the OpenCode listener stays
on loopback. The wildcard ACME certificate already covers
`*.local.estrogenuinely.ca`, so no certificate work is needed.

## Decisions

| Area | Choice | Rationale |
| ---- | ------ | --------- |
| Process | `opencode serve` under systemd | Foreground server, fixed port/password, standard supervision. Unlike the per-user background service, it is not tied to an interactive login. |
| User | `root` (changed 2026-10-31 23:20, at the owner's request) | The agent administers the box: `nixos-rebuild`, `systemctl`, `/etc/nixos`, other services' data. Accepts that the web password is effectively root on satsuma. |
| Bind | `127.0.0.1:4096` | Only nginx can reach it. |
| Ingress | nginx vhost on `opencode.local.estrogenuinely.ca` | CNAME to `satsuma` in Technitium; wildcard cert covers it. |
| TLS | existing `estrogenuinely.ca` wildcard | DNS-01 via Cloudflare; covers `*.local.estrogenuinely.ca`. |
| Auth | OpenCode password (basic auth for API, cookie for web UI) | Built in. Username is always `opencode`; password from agenix. |
| Network ACL | nginx allow LAN + Tailnet, deny everything else | Defence in depth even if 443 is reachable from the WAN. |
| Data | `/var/lib/opencode`, seeded from root's existing store | Preserves the 72 MB session DB and the OpenRouter credential. `/var` is already in the restic offsite set. |
| Workspace | `/srv/opencode/workspace` (`root:opencode-workspace`, setgid) | Optional tidy place for checkouts; `rhuang` can add them. Root can write anywhere, so this is convention, not a boundary. |
| Secrets | agenix `opencode-password.age` | No plaintext password in the Nix store or the repo. |
| Sandbox | none | Removed with the switch to `User=root`: any filesystem restriction would block the agent from doing what it was made root for. `PrivateTmp` and `NoNewPrivileges` are off too, so shells behave like a normal root login. |

Why not the shared background service (`opencode service`)? It is designed for a
desktop session: it auto-starts on demand, stores its config in
`~/.config/opencode/service.json`, and is not a system unit. `opencode serve` is
the documented option for "shared, always-on, or remote host" and for
supervisors such as systemd.

Why not public (`opencode.estrogenuinely.ca`)? An agent with shell access is
only as safe as its password. LAN/Tailnet plus nginx ACL is the default. Public
access would require Cloudflare Access (or mTLS) in front; do not simply open
the vhost.

## Rollout plan

> **Historical.** This is the plan as written before the rollout. Two things
> changed afterwards: the service was switched from a dedicated `opencode`
> user with a sandbox to `root` with no sandbox, and the unit was made
> restart-invariant. Both are recorded, with verification results, in
> [Implementation record](#implementation-record). Read that first if you are
> re-deploying; follow this only for the parts the revisions do not override.

### 0. Preflight (done)

- `opencode` 2.1.1 is already in `common.nix`; no new package.
- Port 4096 is free; nginx owns 80/443.
- `/var/lib/opencode` does not exist yet; root's old store is at
  `/root/.local/share/opencode` (72 MB, includes `auth.json` with the
  OpenRouter key).
- `opencode.local.estrogenuinely.ca` resolves to `10.0.10.72` (CNAME to
  `satsuma` in Technitium, added 2026-10-31).

### 1. Secret

Generate a 48-hex-character password, encrypt it to the `satsuma` and `rhuang`
age recipients, and register it in `satsuma/secrets/secrets.nix`:

```bash
cd /etc/nixos/satsuma/secrets
printf 'OPENCODE_PASSWORD=%s\n' "$(openssl rand -hex 24)" > /tmp/oc-pw
nix shell nixpkgs#age -c age \
  -r 'ssh-ed25519 AAAA…satsuma' \
  -r 'ssh-ed25519 AAAA…rhuang' \
  -o opencode-password.age /tmp/oc-pw
shred -u /tmp/oc-pw
```

The file is an `EnvironmentFile`, so the service reads `OPENCODE_PASSWORD`
directly.

### 2. NixOS module

Add `satsuma/opencode.nix`:

- `age.secrets.opencode-password`, mode `0400`, owner `opencode`.
- `users.users.opencode`: system user, home `/var/lib/opencode`, group `users`,
  no login shell.
- `systemd.tmpfiles.rules`: `/srv/opencode` and `/srv/opencode/workspace`,
  `2775 opencode:users`.
- `systemd.services.opencode`: `ExecStart = opencode serve --hostname
  127.0.0.1 --port 4096`, `Restart=always`, `StateDirectory=opencode`,
  `EnvironmentFile` = agenix path, sandbox as above, PATH with
  `git/nix/ripgrep/nixd`.
- nginx vhost for `opencode.local.estrogenuinely.ca`: proxy to
  `127.0.0.1:4096`, WebSockets on (PTY/SSE), `proxy_buffering off`, 1 h
  timeouts, 100 MB body limit, IP allowlist.
- `opencode-pair` helper: reads the secret as root, calls `POST /api/pair`,
  prints a one-time link with the external hostname.

Import it from `satsuma/configuration.nix` and `git add` the new files (the
flake ignores untracked files).

### 3. Deploy

```bash
nixos-rebuild switch --flake /etc/nixos#satsuma
```

The first start creates an empty database. Seed it from the old one before
declaring success:

```bash
systemctl stop opencode
install -d -o opencode -g opencode /var/lib/opencode/.local/share /var/lib/opencode/.config
rsync -a --chown=opencode:opencode /root/.local/share/opencode/ \
  /var/lib/opencode/.local/share/opencode/
rsync -a --chown=opencode:opencode /root/.config/opencode/ \
  /var/lib/opencode/.config/opencode/
rm -f /var/lib/opencode/.config/opencode/service.json   # old per-user service
systemctl start opencode
```

Root's original tree is left untouched as a fallback.

### 4. Verify

```bash
systemctl status opencode
journalctl -u opencode -n 50 --no-pager
curl -fsS -u "opencode:$(sed 's/^OPENCODE_PASSWORD=//' /run/agenix/opencode-password)" \
  http://127.0.0.1:4096/api/info
curl -fsS -o /dev/null -w '%{http_code}\n' --resolve \
  opencode.local.estrogenuinely.ca:443:127.0.0.1 \
  https://opencode.local.estrogenuinely.ca/
curl -s -o /dev/null -w '%{http_code}\n' --resolve \
  opencode.local.estrogenuinely.ca:443:127.0.0.1 \
  https://opencode.local.estrogenuinely.ca/api/info    # expect 401
```

Then open the web UI in a browser, sign in with the server password, and start
a session. Confirm a reboot brings the service back
(`systemctl is-enabled opencode`).

### 5. Client onboarding

Web UI:

```
https://opencode.local.estrogenuinely.ca
```

One-time pairing link (browser or app), run as root:

```bash
sudo opencode-pair
```

TUI from a laptop (password from the secret, or a local env var):

```bash
export OPENCODE_PASSWORD="$(ssh root@satsuma \
  "sed 's/^OPENCODE_PASSWORD=//' /run/agenix/opencode-password")"
opencode --server https://opencode.local.estrogenuinely.ca
```

The TUI can then open `/srv/opencode/workspace` or any directory the
`opencode` user can read. Repositories under `/var/lib/code` are readable but
not writable until an ACL/group is added.

### 6. Operations

| Task | Command |
| ---- | ------- |
| Status / health | `systemctl status opencode`, `journalctl -u opencode -f` |
| Restart | `sudo systemctl restart opencode` |
| Change password | re-encrypt the agenix file, `nixos-rebuild switch`, restart |
| Upgrade | normal `nixos-rebuild switch` / auto-upgrade at 04:00 — the unit is restart-invariant, see below |
| Rebuild from inside a session | `sudo oc-rebuild` (detached in its own cgroup) |
| Apply changes to this unit | `sudo systemctl restart opencode` (deliberately kills the session) |
| Pair a new client | `sudo opencode-pair` |
| Backups | automatic: `/var/lib/opencode` is under restic's `/var` path |
| Logs | journal, plus `/var/lib/opencode/.local/share/opencode/log/` |

### 6a. Rebuilding without killing the session

`nixos-rebuild switch` used to restart `opencode.service` whenever the unit
text changed (which is most rebuilds, since `ExecStart` and the old `path`
embedded per-generation store paths). Because agent shells live in the
service's cgroup, a restart killed the switch mid-activation and took the
session with it.

Two changes remove that hazard for normal rebuilds:

1. **Restart-invariant unit.** `unitConfig.X-StopIfChanged = false` and
   `X-RestartIfChanged = false` tell `switch-to-configuration` to leave the
   running process alone even when the unit file changes, and the unit's
   `PATH` now points at `/run/current-system/sw/bin` instead of store paths,
   so agent shells follow the new generation without a restart.
   Verified: a rebuild that changed both `Description` and the unit `.drv`
   kept the same `MainPID`.

   Trade-off: edits to `satsuma/opencode.nix` no longer take effect on their
   own. Apply them with `sudo systemctl restart opencode`, knowing that this
   does end the session.

2. **`oc-rebuild`** for anything that must restart the service, or for
   rebuilds started from inside a session:

   ```sh
   sudo oc-rebuild          # queues nixos-rebuild switch in its own unit
   journalctl -u oc-rebuild-<timestamp> -f
   ```

   It uses `systemd-run`, so the rebuild lives in
   `system.slice/oc-rebuild-*.service` rather than the agent's cgroup and
   cannot be killed by an opencode restart. Transient units inherit systemd's
   minimal `PATH`, so the helper passes `PATH` and `HOME` explicitly.

What does **not** work: `nohup`, `setsid`, `&`, or `disown`. systemd kills the
whole cgroup, not just the shell process, so the rebuild still dies with the
unit.

Sessions are not lost either way — they live in the database and survive
restarts and reboots. Only an in-flight turn is aborted.

### 7. Rollback

- Stop/disable: `systemctl disable --now opencode`.
- Remove the nginx vhost and module import, rebuild.
- Data stays at `/var/lib/opencode`; the original root store is untouched.
- The secret can be deleted from `secrets.nix` and the repo.

## Risks and follow-ups

1. **The password is root on satsuma.** Since 2026-10-31 the service runs as
   `root` with a full capability set and no sandbox. Anyone with the server
   password — or a browser session cookie, or a pairing link — can read every
   secret on the box, modify `/etc/nixos`, restart or break any service, and
   reach the tailnet. Treat it exactly like the root SSH key: never paste it
   into a chat, rotate it if exposed, and keep the nginx ACL in place.
2. **Prompt injection now means host compromise.** Web content, file contents,
   or an MCP server can steer the agent toward destructive commands, and
   nothing at the OS layer stops it any more. NixOS generations are the real
   safety net: the previous system is always one
   `nixos-rebuild --rollback switch` (or a boot-menu entry) away. Keep
   `/etc/nixos` committed so the config is recoverable.
3. **Self-rebuild interrupts the session — mitigated.** Resolved for normal
   rebuilds by the restart-invariant unit, and by `oc-rebuild` for the rest.
   See [6a](#6a-rebuilding-without-killing-the-session). Remaining edge cases:
   a reboot (obviously), and deliberately restarting the unit to apply its own
   config changes.
4. **DNS name.** Resolved: the CNAME to `satsuma` exists in Technitium.
   Keep it when editing the `local.estrogenuinely.ca` zone; the wildcard cert
   covers the name.
5. **Backups.** Restic currently backs up `/var` nightly. A live SQLite DB is
   copied while running; OpenCode's WAL should make this safe, but a
   `sqlite3 .backup` pre-hook would be stricter if the DB grows.
6. **Resource use.** A session can run arbitrary commands; there is no CPU/mem
   quota. Add `CPUQuota=`/`MemoryMax=` to the unit if the box gets starved.
7. **Public access (optional).** Prefer Tailscale-only or Cloudflare Access in
   front of nginx. If exposed, add rate limiting and nginx basic auth as a
   second factor.
8. **Multi-user future.** If Lena or others need access, run one server per
   user (different port + data dir + vhost) rather than sharing this one.

## Implementation record

Rolled out 2026-10-31 16:05 EDT.

Changed files (staged, not committed):

- `satsuma/opencode.nix` (new)
- `satsuma/configuration.nix` (import)
- `satsuma/secrets/opencode-password.age` (new)
- `satsuma/secrets/secrets.nix` (recipients)
- `docs/OpenCode.md` (this file)

State:

- `opencode.service`: active and enabled, `User=root` (see the 23:20 revision),
  `ExecStart=opencode serve --hostname 127.0.0.1 --port 4096`, password from
  `/run/agenix/opencode-password` via `serviceConfig.EnvironmentFile`.
- Data: seeded from root's old store (`72 MB` apparent, `21 MB` allocated) and
  config. The old `service.json` was dropped. `/root/.local/share/opencode` is
  untouched as a fallback.
- `/srv/opencode/workspace` exists, `root:opencode-workspace`, setgid.
  `rhuang` was added to `opencode-workspace`.

Verified:

- `curl -u opencode:$PW http://127.0.0.1:4096/api/info` → `200`;
  unauthenticated → `401`.
- Web UI through nginx → `200 text/html`; API through nginx with auth → `200`.
- Existing sessions are visible through `/api/session` (history preserved).
- From the laptop: `https://opencode.local.estrogenuinely.ca/` → `200`,
  `opencode api --server … get /api/info` → `200`.
- ACL: a request sourced from `10.200.200.1` (not in the allowlist) → `403`.
- `sudo opencode-pair` prints a one-time
  `https://opencode.local.estrogenuinely.ca/auth/connect/…` link. Opening it in a
  browser sets an `opencode_session` cookie (30 days) and redirects to the app;
  reusing the link returns `401`.
- `systemctl restart opencode` keeps data and credentials.
- Sandbox (original rollout): the service ran as `opencode` with
  `ProtectSystem=strict` and `ProtectHome`; only `/srv/opencode` and its state
  dir were writable. Superseded by the 23:20 revision below.

Deviations from the plan:

- NixOS 26.11 has no `systemd.services.<name>.environmentFile` option; the unit
  uses `serviceConfig.EnvironmentFile` instead.
- The first start (before that fix) ran without the secret and logged a
  generated password. That password is no longer valid; the secret value is in
  use.
- `opencode.local.estrogenuinely.ca` resolves to `10.0.10.72` since the
  CNAME was added at 16:15; the vhost answers `200 text/html` and the API
  `401` unauthenticated.

Incident at 16:11 (reverted deployment):

Two `nixos-rebuild switch` runs at 16:11 and 16:12 activated a configuration
built from a source tree **without** the OpenCode commit, which removed
`opencode.service` and the nginx vhosts. The commit was still only local on
`satsuma`, so any checkout without it reproduces this. The config was rebuilt
from `/etc/nixos` and the commit was pushed. Lesson: push config commits before
deploying from another machine, and check `systemctl status opencode` after any
switch that is not yours.

The same activation window also surfaced `mautrix-wsproxy` failing on a missing
`config.yaml`. The file was restored from the 04:38 restic snapshot; the
service is healthy again. Unrelated to OpenCode, but it made
`switch-to-configuration` exit 4 until it was fixed.

Revision 2026-10-31 23:20 — run as root:

Requested by the owner so the agent can administer the host directly.

- `User=root`, `Group=root`; the `opencode` system user and group were removed.
- All sandbox options dropped (`ProtectSystem`, `ProtectHome`,
  `PrivateTmp`, `NoNewPrivileges`, `CapabilityBoundingSet`, the `Protect*` and
  `Restrict*` set). Verified `Uid: 0`, `CapEff: 000001ffffffffff`,
  `NoNewPrivs: 0`.
- `path` replaced with `config.system.path` + `config.security.wrapperDir`, so
  agent shells get the full system profile (`nixos-rebuild`, `systemctl`,
  `nix`, `git`, `nixd`, …) instead of the previous hand-picked list.
- State stays at `/var/lib/opencode` (still inside restic's `/var` coverage),
  now `root:root` mode `0700`; `HOME` points there. The surviving
  `/root/.local/share/opencode` copy was left alone.
- Secret owner changed to `root:root`.
- `/srv/opencode` and its `workspace` are now `root:opencode-workspace`;
  `rhuang` keeps group write access for adding checkouts.

Verified after the switch: `Uid: 0`, full caps, `PATH` contains the system
profile, `/api/info` → `200`, 16 sessions intact, web UI → `200`,
`opencode-pair` still prints a working link, `readlink /run/current-system`
is the root-enabled generation.

Known consequences, accepted: the password is now root on the host; prompt
injection equals host compromise; and `nixos-rebuild switch` run from inside a
session restarts the service and kills that session.

Revision 2026-10-31 23:27 — no self-restart:

- `unitConfig.X-StopIfChanged = false`, `X-RestartIfChanged = false`.
- Unit `PATH` is now a literal `/run/current-system/sw/bin:/run/wrappers/bin:…`
  (`lib.mkForce`, since NixOS sets a default `PATH` for services) instead of
  per-generation store paths, so the unit text is stable and agent shells
  still track the current generation.
- New `oc-rebuild` helper: `systemd-run`-wrapped `nixos-rebuild switch`, in
  its own cgroup, with explicit `PATH`/`HOME` for the transient unit.

Verified: a rebuild that changed the unit's `Description` (new
`unit-opencode.service.drv`) left `MainPID` unchanged; an actual generation
switch (`2j4pvl5l…`) also left it unchanged; `oc-rebuild` completed with
exit 0, switched the system, and kept the same PID. A transient unit was
separately confirmed to survive `systemctl restart opencode`
(`/system.slice/detach-test.service` stayed active).

Access:

- Web: <https://opencode.local.estrogenuinely.ca>
- Pair: `sudo opencode-pair`
- TUI: `OPENCODE_PASSWORD=… opencode --server https://opencode.local.estrogenuinely.ca`
- Workspace: `/srv/opencode/workspace`

## Matrix MCP (2026-11-01)

[matrix-mcp](https://github.com/mindroom-ai/matrix-mcp) is a stdio MCP server
that gives the agent a Matrix seat as `@rhuang:estrogenuinely.ca`.

### Packages

- `pkgs/mindroom-nio` packages the MindRoom fork of matrix-nio (the `nio`
  import) with its `e2e` extra: `vodozemac`, `peewee`, and `cachetools`.
- `pkgs/matrix-mcp` pins the `matrix-mcp` 0.9.1 wheel. Upstream requires
  `fastmcp==3.2.4`; nixpkgs has moved to fastmcp 3.4.x and `mcp` 2.x, so the
  module builds fastmcp 3.2.4 against `mcp_1` instead of accepting nixpkgs'
  `broken` marker.
- Both are exposed as flake packages (`.#matrix-mcp`, `.#mindroom-nio`) and
  `matrix-mcp` is installed in `environment.systemPackages` on satsuma.

### OpenCode wiring

The system-wide config at `/etc/opencode/opencode.json` (rendered from
`satsuma/opencode.nix`) adds:

```json
{
  "mcp": {
    "servers": {
      "matrix": {
        "type": "local",
        "command": ["/nix/store/…-matrix-mcp-0.9.1/bin/matrix-mcp", "serve"]
      }
    }
  }
}
```

The server inherits the OpenCode service environment, so its `HOME` is
`/var/lib/opencode` and it finds credentials at
`/var/lib/opencode/.config/matrix-mcp/config.json`. OpenCode's Code Mode
exposes the tools as `tools.matrix.*` (for example `matrix_whoami`,
`matrix_list_rooms`, `matrix_read_room_recent`, `matrix_send_message`).
The running OpenCode service picked up the new server without a restart;
if a future version does not, restart it with `systemctl restart opencode`
(which kills in-flight sessions).

### Authentication and E2EE

The login uses Synapse's legacy shared-secret password provider, so root can
create a dedicated device without an interactive password or SSO callback:

```bash
sudo matrix-mcp-login          # refuses if credentials already exist
sudo matrix-mcp-login --force  # creates another device
```

The current device is `CPSHGXKVEW`, named `matrix-mcp (OpenCode)`, with
ed25519 fingerprint `XK67Q7I9jxl9Zf5CCu87LJe+DyiiMN+66lClNh6AO+s`. Login also
publishes the device's encryption keys, so encrypted rooms work immediately;
the Olm/Megolm store is
`/var/lib/opencode/.config/matrix-mcp/e2ee-af8dfebb2db8a7ce/`. Older room keys
can be imported with `matrix-mcp e2ee import-keys <element-export>`.

The access token is a Matrix credential for `@rhuang`, not a host credential,
but it can read and write every room the user can. `config.json` is mode
`0600`, the directory and E2EE store are `0700`, and all of it sits under the
already-restricted `/var/lib/opencode` (inside restic's `/var` coverage).
Revoke the device from Element/Synapse if the token leaks.

`matrix-mcp-login` is the recovery path if `/var/lib/opencode` is lost or
`matrix-mcp auth logout` is run. To revoke the credentials locally, run
`sudo HOME=/var/lib/opencode matrix-mcp auth logout` (this also deletes the
device's E2EE store). The E2EE store is device-specific: a new login creates a
new device and cannot decrypt messages sent before it unless keys are imported.

### Verification

Over MCP stdio, and through OpenCode after the config switch:

- `matrix_whoami` → `@rhuang:estrogenuinely.ca`, device `CPSHGXKVEW`.
- `matrix_list_rooms` → 124 joined rooms.
- `matrix_get_unread` → responds normally (no unread rooms at setup time).
- `matrix-mcp config-path` with `HOME=/var/lib/opencode` prints
  `/var/lib/opencode/.config/matrix-mcp/config.json`.


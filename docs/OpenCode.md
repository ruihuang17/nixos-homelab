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
| User | dedicated system user `opencode` | The agent gets shell access; it must not be root or `rhuang` (wheel = passwordless sudo). |
| Bind | `127.0.0.1:4096` | Only nginx can reach it. |
| Ingress | nginx vhost on `opencode.local.estrogenuinely.ca` | CNAME to `satsuma` in Technitium; wildcard cert covers it. |
| TLS | existing `estrogenuinely.ca` wildcard | DNS-01 via Cloudflare; covers `*.local.estrogenuinely.ca`. |
| Auth | OpenCode password (basic auth for API, cookie for web UI) | Built in. Username is always `opencode`; password from agenix. |
| Network ACL | nginx allow LAN + Tailnet, deny everything else | Defence in depth even if 443 is reachable from the WAN. |
| Data | `/var/lib/opencode`, seeded from root's existing store | Preserves the 72 MB session DB and the OpenRouter credential. `/var` is already in the restic offsite set. |
| Workspace | `/srv/opencode/workspace` (group `users`, setgid) | Isolated from `/root`; `rhuang` can add checkouts, the service owns writes. |
| Secrets | agenix `opencode-password.age` | No plaintext password in the Nix store or the repo. |
| Sandbox | `ProtectSystem=strict`, `ProtectHome=yes`, `ReadWritePaths=/srv/opencode` | Agent can only write its state dir and workspace. |

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
| Upgrade | normal `nixos-rebuild switch` / auto-upgrade at 04:00 |
| Pair a new client | `sudo opencode-pair` |
| Backups | automatic: `/var/lib/opencode` is under restic's `/var` path |
| Logs | journal, plus `/var/lib/opencode/.local/share/opencode/log/` |

### 7. Rollback

- Stop/disable: `systemctl disable --now opencode`.
- Remove the nginx vhost and module import, rebuild.
- Data stays at `/var/lib/opencode`; the original root store is untouched.
- The secret can be deleted from `secrets.nix` and the repo.

## Risks and follow-ups

1. **Single shared identity.** The password grants full access to all sessions
   and to the `opencode` user's shell. Do not share it; rotate it if leaked.
2. **Workspace access.** The service can read most of the filesystem
   (`ProtectSystem` makes it read-only, not invisible). `ProtectHome` hides
   `/home` and `/root`; `/etc` and `/var` are readable. Do not put secrets in
   world-readable files the agent should not see.
3. **DNS name.** Resolved: the CNAME to `satsuma` exists in Technitium.
   Keep it when editing the `local.estrogenuinely.ca` zone; the wildcard cert
   covers the name.
4. **Backups.** Restic currently backs up `/var` nightly. A live SQLite DB is
   copied while running; OpenCode's WAL should make this safe, but a
   `sqlite3 .backup` pre-hook would be stricter if the DB grows.
5. **Resource use.** A session can run arbitrary commands; there is no CPU/mem
   quota. Add `CPUQuota=`/`MemoryMax=` to the unit if the box gets starved.
6. **Public access (optional).** Prefer Tailscale-only or Cloudflare Access in
   front of nginx. If exposed, add rate limiting and nginx basic auth as a
   second factor.
7. **Multi-user future.** If Lena or others need access, run one server per
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

- `opencode.service`: active and enabled, `User=opencode`,
  `ExecStart=opencode serve --hostname 127.0.0.1 --port 4096`, password from
  `/run/agenix/opencode-password` via `serviceConfig.EnvironmentFile`.
- Data: seeded from root's old store (`72 MB` apparent, `21 MB` allocated) and
  config. The old `service.json` was dropped. `/root/.local/share/opencode` is
  untouched as a fallback.
- `/srv/opencode/workspace` exists, `opencode:opencode-workspace`, setgid.
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
- Sandbox: the service runs as `opencode` with `ProtectSystem=strict` and
  `ProtectHome`; only `/srv/opencode` and its state dir are writable. The
  workspace is `2770 opencode:opencode-workspace`; `opencode` and `rhuang` can
  both write, other users cannot read it.

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

Access:

- Web: <https://opencode.local.estrogenuinely.ca>
- Pair: `sudo opencode-pair`
- TUI: `OPENCODE_PASSWORD=… opencode --server https://opencode.local.estrogenuinely.ca`
- Workspace: `/srv/opencode/workspace`


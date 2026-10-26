# Hermes Agent

Set up 2026-10-23. Hermes is a self-hosted AI agent. It runs as a **messaging
gateway** plus a **web dashboard** on satsuma, and the dashboard logs in through
Kanidm OIDC. See [[Setup Overview]] for the host table and [[IP Address]] for
addresses.

## At a glance

| Component         | Where   | Address                       | Exposed as                                   |
| ----------------- | ------- | ----------------------------- | -------------------------------------------- |
| Messaging gateway | satsuma | random loopback port, `gateway.sock` | local only                            |
| Dashboard backend | satsuma | `127.0.0.1:9119`              | `hermes.local.estrogenuinely.ca` (nginx)     |
| State             | satsuma | `/var/lib/hermes/.hermes`     | `hermes` user, mode `2770` (setgid)          |
| Logs              | satsuma | `/var/lib/hermes/.hermes/logs` | `gui.log`, `gateway.log`, `errors.log`, ... |
| Discord bot       | Discord | guild `1350420778801168425`   | `#hermes` (ID `1563363787090821222`), DMs     |

The two systemd units are `hermes-agent.service` (the gateway) and
`hermes-backend.service` (the dashboard). Both run as the `hermes` user with
`HERMES_HOME=/var/lib/hermes/.hermes`.

## Access

- Web UI: <https://hermes.local.estrogenuinely.ca> — these `*.local.*` names
  resolve to satsuma via orange's DNS and use the `estrogenuinely.ca` wildcard
  ACME cert. Internal only (not reachable from the public internet).
- Login: **Sign in with Kanidm** via the `self-hosted` OIDC provider. Any member
  of the Kanidm group `homelab_user` can log in.
- Discord: mention the bot in `#hermes` (guild `1350420778801168425`) or DM it.
  Only the allowlisted Discord user IDs `454892601175441418` and
  `606668600451006485` are accepted; guild messages are further limited to
  `#hermes` and must mention the bot. DMs are allowed for those users and do not
  need a mention.
- No Matrix or email adapter is configured.
- Media/downloader tools: Hermes can query Sonarr, Radarr, Prowlarr, qBittorrent,
  Prometheus, and the journal, and read the media/torrent trees. It cannot write
  media, restart services, or change Nix. See **Media and downloader access**.
- **All browser sessions share the same agent workspace.** The `hermes` user is
  the only OS-level identity; Kanidm gates *who* can open the dashboard, not
  which files or shell the agent sees. Treat `homelab_user` as equivalent to
  shell access on the agent's workspace.

## How it's configured

Everything on satsuma is declared in the NixOS flake at `/etc/nixos` (see
[[Setup Overview]] → satsuma). Hermes comes from the `hermes-agent` flake input;
the NixOS module is `inputs.hermes-agent.nixosModules.default`.

### satsuma — `satsuma/hermes.nix`

- `services.hermes-agent.enable = true`.
- `backend = { mode = "dashboard"; host = "127.0.0.1"; port = 9119; }` starts
  `hermes dashboard --host 127.0.0.1 --port 9119 --no-open` as
  `hermes-backend.service`. `dashboard` mode includes `serve` (the `/api/ws` and
  `/api/pty` sockets used by the dashboard's embedded chat).
- `settings` is rendered into `/var/lib/hermes/.hermes/config.yaml` by the
  module. Current settings: default model
  `deepseek/deepseek-v4.1-flash-1017`, `toolsets = [ "all" ]`, local terminal
  with a 180 s timeout, memory/profile enabled, and Discord enabled
  (`platforms.discord.enabled = true`).
- `settings.discord = { require_mention = true; auto_thread = true;
  allowed_channels = "1563363787090821222"; }`. `allowed_channels` is a
  **guild-channel whitelist**; it does not restrict DMs. `auto_thread` puts each
  conversation in a thread so concurrent channels do not share one session.
- `settings.dashboard.public_url = "https://hermes.local.estrogenuinely.ca"` —
  without this the OAuth redirect and cookies target the loopback origin.
- `settings.dashboard.oauth.self_hosted` points at the Kanidm client:
  `issuer = "https://idm.estrogenuinely.ca/oauth2/openid/hermes"`,
  `client_id = "hermes"`, `scopes = "openid profile email"`.
- `environmentFiles = [ config.age.secrets.hermes-env.path
  config.age.secrets.hermes-discord.path ]` builds
  `/var/lib/hermes/.hermes/.env` (owner `hermes:hermes`, mode `0640`,
  regenerated on activation) from the OpenRouter key
  (`satsuma/secrets/hermes-env.age`) and the Discord bot token
  (`satsuma/secrets/hermes-discord.age`, which contains only
  `DISCORD_BOT_TOKEN`).
- `environment = { DISCORD_ALLOWED_USERS =
  "454892601175441418,606668600451006485"; DISCORD_HOME_CHANNEL =
  "1563363787090821222"; }` are non-secret and also go into `.env`. The
  allowed-users list is **fail-closed**: if it is empty, Discord rejects
  everyone. `DISCORD_HOME_CHANNEL` is the default delivery
  target for cron/CLI sends.
- `addToSystemPackages = true` puts `hermes` on the system PATH;
  `extraPackages = [ pkgs.nix ]` lets the agent use `nix` from its shell.

### Discord bot

The bot is a normal Discord application owned by rhuang. In the
[Developer Portal](https://discord.com/developers/applications):

- **Bot** → enable **Message Content Intent** (required to read messages).
  **Server Members Intent** is only needed for username/role allowlists; this
  setup uses numeric user IDs, so it is off.
- **OAuth2** → invite with
  `https://discord.com/oauth2/authorize?client_id=<CLIENT_ID>&permissions=328565124160&scope=bot%20applications.commands`
  (view/send/history/embeds/files/reactions/pin/threads).
- The bot's display name is still the default
  `bot1563363270058967070`; rename it in the portal if desired (no rebuild
  needed for a rename).

The token is the only secret. Encrypt it (run from `/etc/nixos`, or from
`satsuma/secrets` — agenix discovers `secrets.nix` in the current directory):

```sh
printf 'DISCORD_BOT_TOKEN=%s\n' '<token>' \
  | agenix -e satsuma/secrets/hermes-discord.age
git -C /etc/nixos add satsuma/secrets/hermes-discord.age   # flakes only see tracked files
```

To rotate: **Reset Token** in the portal, re-run the command above, then
`nixos-rebuild switch` and `systemctl restart hermes-agent`. The raw token is
not kept on disk after encryption (this setup used `/root/discord-bot-token`
mode `0600` and shredded it). Voice playback is disabled because the Opus codec
is not installed; text chat is unaffected.

### satsuma — `satsuma/nginx.nix`

A vhost for `hermes.local.estrogenuinely.ca` proxies to
`http://127.0.0.1:9119` with `proxyWebsockets = true` (the chat and event
streams are WebSockets). The dashboard itself binds loopback only; nginx is the
only listener on 443.

### Single sign-on (Kanidm OIDC)

Kanidm holds the client, not the flake. It is a **public PKCE client** — there is
no client secret in the repo or in agenix. Created with (as `idm_admin`):

```sh
kanidm system oauth2 create-public hermes "Hermes Agent" http://127.0.0.1:9119 -D idm_admin
kanidm system oauth2 enable-localhost-redirects hermes -D idm_admin
kanidm system oauth2 add-redirect-url hermes https://hermes.local.estrogenuinely.ca/auth/callback -D idm_admin
kanidm system oauth2 set-landing-url hermes https://hermes.local.estrogenuinely.ca -D idm_admin
kanidm system oauth2 update-scope-map hermes homelab_user openid profile email -D idm_admin
```

Resulting client state (`kanidm system oauth2 get hermes`):

- callback `https://hermes.local.estrogenuinely.ca/auth/callback`, strict
  redirect matching on;
- landing page `https://hermes.local.estrogenuinely.ca/`;
- scope map `homelab_user` → `openid profile email`;
- localhost redirects enabled (so a plain `http://127.0.0.1:9119` session still
  works for debugging).

Hermes builds the authorize request from `dashboard.oauth.self_hosted` and
`dashboard.public_url`; the redirect URI is always
`<public_url>/auth/callback`. To add a user, add them to the Kanidm group
`homelab_user` — no Hermes change is needed.

### How the pieces talk

`hermes gateway` (the messaging gateway) is the process that actually runs agent
sessions. The dashboard backend does **not** contain that gateway; the embedded
chat terminal in the web UI bootstraps through
`/var/lib/hermes/.hermes/gateway.sock` and attaches to the gateway's own
WebSocket on its random loopback port (`ws://127.0.0.1:<port>/api/ws`). It also
opens a sidecar to the backend (`ws://127.0.0.1:9119/api/pub`) so the React
sidebar receives tool events. The random gateway port changes on every gateway
restart; only `9119` is proxied, so there is nothing to update when it moves.

## Media and downloader access

The agent has **app-level** access without root. It gets API credentials and
read-only files, not service control or Nix write access.

Environment variables visible to the agent (and passed through Hermes' child-env
scrubber for the four secrets):

| Variable | Value |
| --- | --- |
| `SONARR_URL`, `RADARR_URL`, `PROWLARR_URL` | `http://127.0.0.1:8989/7878/9696` |
| `SONARR_API_KEY`, `RADARR_API_KEY`, `PROWLARR_API_KEY` | from the apps' `config.xml` |
| `QBITTORRENT_URL` | `http://10.200.200.2:8080` (VPN veth; **not** localhost) |
| `QBITTORRENT_USERNAME`, `QBITTORRENT_PASSWORD` | qBittorrent admin |
| `JELLYFIN_URL` | `http://10.0.10.73:8096` (lime; API key not set yet) |
| `PROMETHEUS_URL` | `http://127.0.0.1:9090` |

Examples:

```sh
curl -fsS -H "X-Api-Key: $SONARR_API_KEY" "$SONARR_URL/api/v3/queue" | jq
curl -fsS -H "X-Api-Key: $RADARR_API_KEY" "$RADARR_URL/api/v3/health" | jq

curl -fsS -c /tmp/qbt.cookie \
  --data-urlencode "username=$QBITTORRENT_USERNAME" \
  --data-urlencode "password=$QBITTORRENT_PASSWORD" \
  "$QBITTORRENT_URL/api/v2/auth/login"
curl -fsS -b /tmp/qbt.cookie "$QBITTORRENT_URL/api/v2/torrents/info" | jq

curl -fsSG --data-urlencode 'query=up' "$PROMETHEUS_URL/api/v1/query" | jq
journalctl -u sonarr -u radarr -u qbittorrent -n 100 --no-pager
ls /hdd/mediaSrv/media /hdd/mediaSrv/torrent
```

### How the access is provisioned

- `hermes-media-keys.service` (oneshot) reads the *arr keys from
  `/run/grove-exporter` and the qBittorrent password from
  `/run/agenix/qbittorrent-password`, then writes `/run/hermes-media/env`
  (root `0400`). `hermes-agent.service` gets it via
  `EnvironmentFile=-/run/hermes-media/env`.
- `settings.terminal.env_passthrough` lists the four secret names so Hermes'
  terminal scrubber forwards them to child commands; the OpenRouter key stays
  stripped.
- `hermes-media-acl.service` sets `acltype=posixacl` on the `hdd/mediaSrv`
  dataset and adds `user:hermes:r-x` ACLs on `/hdd/mediaSrv`, its `media` and
  `torrent` children. It is idempotent and re-applied at boot. The group mask
  stays `rwx`, so `media`/qBittorrent keep write access; Hermes gets read/traverse
  only. Do **not** add `hermes` to the `media` group: that also grants write to
  `/hdd/data` (personal files) and to the media tree.
- `users.users.hermes.extraGroups = [ "systemd-journal" ]` gives read-only
  journal access. Prometheus on loopback needs no credential and is already
  scraped by exportarr for the *arr apps, qBittorrent, ZFS/SMART, and Grove.

Now, after rotating an *arr API key or the qBittorrent password:

```sh
# *arr key rotated:
systemctl restart grove-arr-keys hermes-media-keys hermes-agent
# qBittorrent password rotated:
systemctl restart qbittorrent hermes-media-keys hermes-agent
```

`grove-arr-keys` re-reads the apps' `config.xml`; `hermes-media-keys`
regenerates `/run/hermes-media/env`; restarting the gateway reloads it.

If the ACLs disappear (for example after a manual `chmod`), restart
`hermes-media-acl`. Check with `getfacl -p /hdd/mediaSrv` and
`systemctl status hermes-media-keys hermes-media-acl`.

## Operations

- Apply config changes: `nixos-rebuild switch --flake /etc/nixos#satsuma`.
  Config changes land in `config.yaml`; restart the units to pick them up:
  `systemctl restart hermes-agent hermes-backend`.
- Run the CLI as the agent user, not root:

  ```sh
  sudo -u hermes -H hermes chat
  ```

  As root it fails with `unsafe_control_path` (the state dir is owned by the
  `hermes` uid).
- Logs: `/var/lib/hermes/.hermes/logs/` (`gui.log` for the dashboard and PTY,
  `gateway.log` for the gateway, `dashboard-auth.log` for OIDC/WS tickets,
  `errors.log`). Unit logs via `journalctl -u hermes-backend -u hermes-agent`.
- Verify the dashboard without a browser:

  ```sh
  systemctl is-active hermes-agent hermes-backend
  ss -tlnp | grep 9119
  curl -sS --resolve hermes.local.estrogenuinely.ca:443:127.0.0.1 \
    https://hermes.local.estrogenuinely.ca/login | grep -o 'Self-Hosted OIDC'
  curl -si --resolve hermes.local.estrogenuinely.ca:443:127.0.0.1 \
    'https://hermes.local.estrogenuinely.ca/auth/login?provider=self-hosted' \
    | grep -i '^location:'
  ```

  The `/auth/login` location should carry
  `redirect_uri=https%3A%2F%2Fhermes.local.estrogenuinely.ca%2Fauth%2Fcallback`
  and `code_challenge_method=S256`. Sensitive API routes (`/api/config`,
  `/api/sessions`) return `401` when logged out; `/api/status` is a public
  readiness probe.
- If the Kanidm admin session for the CLI expired, run
  `kanidm login --name idm_admin` again (sessions are short-lived).

## Gotchas

- **Do not add `rhuang` (or any admin) to the `hermes` group.** The module makes
  `/var/lib/hermes/.hermes` mode `2770`; the gateway refuses to use a control
  socket in a group-shared home and the embedded chat then retries forever with
  UI text like `retrying in 30s (attempt N)`. The log line is
  `gateway inaccessible: unsafe_control_permissions ... writable by another
  user`. Keep the `hermes` group private (no members) and manage the state as
  root/`sudo -u hermes`. For the same reason, don't `chmod g-w` the directory
  by hand — the module's tmpfiles/activation reset it to `2770` on every switch.
- The gateway also serves an **embedded dashboard** on its random loopback port
  (that is the WS endpoint the chat attaches to). It is gated too, but do not
  use it in a browser; the supported URL is the nginx one on `9119`.
- The client is public/PKCE, so there is no secret to rotate. To revoke access,
  delete or disable the `hermes` OAuth2 client in Kanidm (or remove users from
  `homelab_user`).
- `dashboard.public_url` is required for the HTTPS redirect to be used. Without
  it the provider falls back to the loopback origin, and over plain HTTP the
  PKCE cookie's `SameSite=Lax` behaviour can break the callback.
- Rebuilding **merges** `settings` into `config.yaml`: keys set in Nix are
  replaced, but other keys are preserved. Still prefer `satsuma/hermes.nix`;
  ad-hoc edits to a key that Nix also sets are lost on the next switch.
- Discord authorization uses **numeric IDs**, not usernames or `name#discrim`.
  `DISCORD_ALLOWED_USERS` is a comma-separated allowlist and is fail-closed when
  empty. `discord.allowed_channels` limits guild messages only; DMs from an
  allowed user still work. Messages in `#hermes` must mention the bot; to let it
  answer every message there without a mention, add
  `discord.free_response_channels = "1563363787090821222"` and rebuild.
- `.env` and `config.yaml` are regenerated/merged at activation, but the running
  gateway only rereads them on restart. `nixos-rebuild switch` does not restart
  `hermes-agent` when only the contents of `.env`/`config.yaml` change, so run
  `systemctl restart hermes-agent` after enabling or rotating a platform.
- The Discord token is a flake input file; a newly encrypted `.age` file must be
  `git add`ed or the build fails with `Path ... is not tracked by Git`.
- The media ACL is **not recursive**: it grants traverse on `/hdd/mediaSrv` and
  access to the `media`/`torrent` directories. Files created there are normally
  `2775/664` (world-readable); a `0600` file remains unreadable and Hermes should
  report it rather than chmod it.
- `hdd/mediaSrv` uses `acltype=posixacl` because POSIX `setfacl` fails on
  `nfsv4` datasets. If the property is ever reset, `hermes-media-acl` sets it
  again. This is scoped to that dataset.
- The four media secrets are ordinary env vars, so any command Hermes runs can
  read them. The *arr keys and qBittorrent admin login can delete media; there is
  no delete guardrail beyond the agent's instructions and the Discord allowlist.
  Don't echo the keys, and treat the Discord/API allowlist as shell-equivalent
  for the media stack.
- `EnvironmentFile` is attached to `hermes-agent.service`, so the
  Discord/dashboard gateway has the media vars. A hand-run
  `sudo -u hermes -H hermes chat` does **not** source them; export them or use the
  gateway.
- If `hermes-media-keys` fails, `/run/hermes-media/env` is missing and the
  gateway still starts (the leading `-` makes the file optional). Check
  `systemctl status hermes-media-keys` and that `/run/grove-exporter/*.key`
  exist.

### Verified (2026-10-23)

- Kanidm login completed end to end: `/login` shows **Self-Hosted OIDC**,
  `/auth/login` redirects to `idm.estrogenuinely.ca` with the HTTPS redirect and
  PKCE S256, and Kanidm returns the login page (redirect accepted).
- After the group fix, the dashboard's embedded chat attached successfully:
  `[lifecycle] attached shared gateway ... url=ws://127.0.0.1:<port>/api/ws`,
  with stable sockets to both the gateway and the `9119` sidecar.
- `https://hermes.local.estrogenuinely.ca` serves the UI over TLS; `/api/config`
  and `/api/sessions` return `401` unauthenticated.
- Media access verified: Sonarr/Radarr/Prowlarr `system/status` return `200`,
  qBittorrent login returns `204` and reports `v5.2.3`, Prometheus `/-/ready`
  returns `200`, and Jellyfin's public info endpoint returns `200`.
- `id hermes` includes `systemd-journal`; `journalctl -u radarr` works as
  `hermes`. `getfacl` shows `user:hermes:r-x` on the three paths, reading
  `media` and `torrent` succeeds, and `touch` is denied.
- The Hermes child-env scrubber test kept `SONARR_API_KEY`, `RADARR_API_KEY`,
  `PROWLARR_API_KEY`, `QBITTORRENT_PASSWORD`, and the URL vars, and still
  stripped `OPENROUTER_API_KEY`.
- Discord connected after restart:
  `[Discord] Connected as bot1563363270058967070#9744`, then
  `✓ discord connected`; `gateway_state.json` shows
  `"platforms":{"discord":{"state":"connected"}}`. A REST send/delete test in
  `#hermes` succeeded (`204`), confirming the invite permissions. The
  `Opus codec not found` warning only disables voice playback.

## Not done yet / ideas

- Discord is the only messaging adapter; no Matrix, email, or Signal.
- The bot still has its default username and no avatar; both are cosmetic and
  changed in the Developer Portal.
- No Jellyfin API key yet. Create one on lime (Administration → API Keys) and
  add it to the media env (plus `env_passthrough`) to cover library scans and
  metadata.
- No restart/file-repair/Nix write privilege. Service restarts need polkit or a
  root helper; ownership fixes need a scoped helper or a human. The agent can
  currently only propose Nix changes from a clone and run `nixos-rebuild build`.
- qBittorrent uses the admin account. A restricted WebUI user with no delete
  permission would reduce blast radius if qBittorrent supports it in the UI.
- Single shared workspace and shell for every dashboard user. Per-user profiles
  are possible in Hermes, but the module currently runs one `hermes` identity.
- The auxiliary model lane uses the same paid model; set
  `auxiliary.free_only = true` or an `auxiliary.openrouter_model` ending in
  `:free` if spend matters.

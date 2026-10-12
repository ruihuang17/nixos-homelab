# Stalwart Mail Server (estrogenuinely.ca)

`kiro-cli --resume-id fdd23ec0-f520-42c7-bf89-dcdedab24e39`

Full mail server (SMTP/IMAP/JMAP) on the **vps** host (`mail.estrogenuinely.ca`, hostname
`mail`, OVH, Canada). Users authenticate against **kanidm** on `satsuma` over **LDAP**,
reached privately via **Tailscale**. TLS via ACME (Cloudflare DNS-01). Inbound mail arrives
directly on port 25; **outbound is relayed through AWS SES** (OVH blocks outbound 25).

> Not the same as `Mail.md` — that is the separate Postfix→Proton relay for system alerts.

Branch: **`main`** (merged from `stalwart-mail` by fast-forward, pushed). Head when written: `533afab`.
Both hosts' `/etc/nixos` checkouts now track `main`. The old `stalwart-mail` branch still exists
on origin and can be deleted.

## Status (2026-10-11)

| Area                                                 | State                                                                                                                                                                                                                                   |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Stalwart 0.15.5 on vps, listeners up                 | done                                                                                                                                                                                                                                    |
| kanidm LDAP over Tailscale (service-account lookups) | done, verified in kanidm logs                                                                                                                                                                                                           |
| User password bind (Thunderbird login)               | done, verified in kanidm logs (`LDAP Bind success`)                                                                                                                                                                                     |
| TLS cert (Let's Encrypt, all 4 names)                | done, verified from off-tailnet with strict verification                                                                                                                                                                                |
| Autodiscovery off-tailnet, admin tailnet-only        | done, verified (see Network exposure)                                                                                                                                                                                                   |
| IPv6, PTR v4+v6, MX/SPF/DKIM/DMARC DNS               | done, verified with `dig`                                                                                                                                                                                                               |
| SES outbound relay config                            | done and verified: Thunderbird → Stalwart → SES → Proton, inbox. Proton headers: `dmarc=pass`, `spf=pass smtp.mailfrom=bounce.estrogenuinely.ca`, `dkim=pass header.d=estrogenuinely.ca` (plus amazonses.com), only the SES hop visible |
| Domain registered in Stalwart webadmin               | done (by hand)                                                                                                                                                                                                                          |
| Inbound mail end-to-end test                         | done: Gmail → rui@ delivered, SPF/DKIM/DMARC all pass                                                                                                                                                                                   |
| Cloudflare API token rotation                        | done 2026-10-11 (both hosts, commits `c3013b5` satsuma, `533afab` vps); new tokens read the zone and its DNS records                                                                                                                    |

## Why LDAP (not OIDC)

Thunderbird/Apple Mail/Outlook must work. Stalwart's OIDC backend only validates
`OAUTHBEARER` tokens, which those clients don't support with a third-party IdP, and it has
no offline directory lookup (inbound mail to a user who never logged in is rejected). LDAP
gives normal password login and real directory lookups.

## Architecture

```
Thunderbird ──IMAP/SMTP──▶ Stalwart (vps)  ──LDAPS over Tailscale──▶ kanidm (satsuma)
                              │                                      ldaps://satsuma.tailf59fe4.ts.net:3636
          other MTAs ──:25──▶ │ (inbound, direct)
                              └──:587 STARTTLS + SASL──▶ AWS SES (us-east-2) ──▶ internet (outbound)
```

- kanidm LDAPS (3636) listens on `0.0.0.0` but the firewall only allows it on `tailscale0`.
- Stalwart does two LDAP things: a service-account bind (`dn=token` + read-only API token)
  for lookups, and a **bind as the user** with the typed password to verify it.

## Git / NixOS / deploying

- Repo `git@github.com:ruihuang17/nixos-homelab.git`, checked out at `/etc/nixos` on both
  hosts. Flake outputs: `nixosConfigurations.satsuma` and `nixosConfigurations.mail`
  (renamed from `"mail.estrogenuinely.ca"`). Rebuild: `nixos-rebuild switch --flake /etc/nixos#mail`.
- Both hosts use **fish** as login shell. Wrap remote commands in `bash -lc '...'`, or better,
  `scp` a small script and run `bash script.sh` (nested quoting over 3 shells is a trap).
- **vps public SSH (22) rate-limits/drops** after bursts of connections. Reliable path:
  `ssh satsuma`, then from satsuma `ssh -i ~/.ssh/general root@100.91.236.114` (over the tailnet).
- Deploy = commit on satsuma → `git push origin main` → on vps
  `git fetch && git reset --hard origin/main && nixos-rebuild switch --flake .#mail`.
  **Check `git log -1` on the vps afterwards.** Several "deploys" earlier silently ran
  the old commit and I debugged the wrong config for a while.
- `nixos-rebuild switch` on the vps may print `failed (status 4)` because of the ACME unit;
  that used to hide a real problem (see ACME below). It should be clean now.

### Files changed

| File | Change |
|------|--------|
| `vps/stalwart.nix` | **new** — Stalwart, LDAP directory, ACME, fallback admin, SES relay, firewall |
| `vps/configuration.nix` | imports `./stalwart.nix`; static OVH IPv6 |
| `vps/secrets/*.age` | `cloudflare_api`, `kanidm_ldap_token`, `stalwart_admin`, `ses_smtp_user`, `ses_smtp_pass` |
| `vps/secrets/secrets.nix` | recipients: `[ vps-host rhuang ]` |
| `common.nix` | Tailscale moved here (shared by all hosts) |
| `satsuma/kanidm.nix` | LDAPS bind `0.0.0.0:3636`, firewalled to `tailscale0` |
| `satsuma/tailscale.nix` | now a no-op (config moved to `common.nix`) |
| `flake.nix` | vps output renamed to `mail` |

## kanidm setup (on satsuma)

```bash
kanidm service-account create stalwart "Stalwart Mail Server" idm_service_account_admins -D idm_admin
kanidm group add-members idm_mail_servers      stalwart -D idm_admin
kanidm group add-members idm_account_mail_read stalwart -D idm_admin
kanidm service-account api-token generate stalwart stalwart-ldap-ro -D idm_admin   # shown once
kanidm system domain set-ldap-allow-unix-password-bind true -D admin               # needs `admin`, not idm_admin
```

- basedn: `dc=idm,dc=estrogenuinely,dc=ca`. LDAPS only (no StartTLS), reuses kanidm's web cert.
- Bind DNs are `name=<user>,<basedn>` or `spn=<user>@idm.estrogenuinely.ca,<basedn>`; both work.
- A user binding over LDAP only gets *anonymous* read rights, which is why lookups use the
  `dn=token` service account.
- Per user: `mail` attribute + a POSIX account + a **Unix password**
  (`kanidm person posix set-password <user> -D idm_admin`; the Unix password is separate from
  the main kanidm credential).
- Mail attrs set: `rhuang` → `rui@estrogenuinely.ca`, `rui.huang17@protonmail.com`;
  `lena` → `lena@estrogenuinely.ca`, `lenazhu2007@gmail.com`.
- kanidm CLI sessions expire (~1h). Non-interactive use needs a fresh `kanidm login` first.

## Stalwart config (`vps/stalwart.nix`)

- `services.stalwart` (nixpkgs module), package 0.15.5, `stateVersion = "26.05"` (RocksDB).
- Secrets: agenix → systemd `LoadCredential` → referenced as
  `%{file:/run/credentials/stalwart.service/<name>}%`. Nothing secret lands in the Nix store.
- `openFirewall = false`; ports are opened explicitly (next section).
- **Fallback admin** (`authentication.fallback-admin`, user `admin`, random password in
  `stalwart_admin.age`; password lives in the password manager). Needed because auth is
  delegated to kanidm and kanidm users aren't Stalwart admins.
- **webadmin** uses the upstream prebuilt zip (nixpkgs build is broken, see below).

Directory block as it ends up in the TOML:

```toml
[storage]
directory = "kanidm"

[directory.kanidm]
type = "ldap"
url = "ldaps://satsuma.tailf59fe4.ts.net:3636"
base-dn = "dc=idm,dc=estrogenuinely,dc=ca"

[directory.kanidm.bind]                 # service account, used for lookups
dn = "dn=token"
secret = "%{file:/run/credentials/stalwart.service/ldap_token}%"

[directory.kanidm.bind.auth]            # bind AS the user to check their password
method = "template"
template = "name=?,dc=idm,dc=estrogenuinely,dc=ca"

[directory.kanidm]
lookup.domains = ["estrogenuinely.ca"]   # makes is_local_domain() match; see Gotchas

[directory.kanidm.attributes]
class = "class"
name = "name"
email = "emailprimary"                   # NOT `mail`, see Gotchas
groups = "memberof"
description = "displayname"

[directory.kanidm.filter]
name  = "(&(class=account)(name=?))"
email = "(&(class=account)(emailprimary=?))"

[directory.kanidm.tls]
enable = false                          # ldaps:// is already TLS
allow-invalid-certs = true              # kanidm's cert is for idm.estrogenuinely.ca but we
                                        # connect via the tailnet name; Tailscale (WireGuard)
                                        # already authenticates/encrypts the link
```

Login name in Thunderbird is the kanidm name (`rhuang`), **not** the email address, because
the bind DN is built as `name=<typed login>,...`.

### Finding the real config keys for 0.15.5 (important)

The Stalwart website documents 0.16 (JSON objects, different keys). Wrong keys are
**silently ignored** or only produce a "Configuration parse error" journal line with the
useful text hidden in the structured `DETAILS=` field. What worked:

```bash
# list keys the binary actually knows
grep -aoE 'bind\.[a-z.]+|queue\.[a-z.-]+|http\.[a-z.-]+' /nix/store/*-stalwart-0.15.5/bin/stalwart | sort -u
# see parse errors with their detail
journalctl -u stalwart -o export | grep '^DETAILS='
```

Things that bit me: `bind.auth.enable/dn` → real keys are `bind.auth.method = "template"` and
`bind.auth.template` (with the old keys Stalwart never sent a bind, every login failed);
HTTP access control key is top-level `http.allowed-endpoint` (not `server.http...`) and the
variable is `url_path`; `queue.strategy.route` is an *expression* so a literal route name
needs quotes (`"'ses'"`); a list of `{if, then}/{else}` tables must be real TOML
array-of-tables (Nix keywords `if/then/else` must be quoted as attr names). The "Database
key defined in local configuration" warnings in the journal are expected and harmless.

## Network exposure

| Port                   | Where             | Purpose                                             |
| ---------------------- | ----------------- | --------------------------------------------------- |
| 25, 465, 587, 143, 993 | public            | SMTP in, submission(s), IMAP(S)                     |
| 443                    | public            | JMAP, autoconfig/autodiscover, `.well-known`, OAuth |
| 8443                   | `tailscale0` only | web admin + management API                          |
| 3636 (satsuma)         | `tailscale0` only | kanidm LDAPS                                        |

Admin separation is done with `http.allowed-endpoint`: the expression allows `/admin` and
`/api` only when `listener == 'https-admin'`; everything else is allowed on both. Verified:
from off-tailnet `/api/*` → 403 on 443, autoconfig → 200; over the tailnet 8443 → admin API 200.
Note the admin SPA is served for *any* path, so `/admin` itself isn't the real boundary;
`/api` is.

Admin UI: `https://100.91.236.114:8443` (cert warning on an IP is expected), user `admin`.

## TLS / ACME

- `security.acme.certs."mail.estrogenuinely.ca"` (+ autoconfig, autodiscover, mta-sts SANs),
  Cloudflare DNS-01. Cert expires 2027-01-09; renewal is a systemd timer.
- **The secret must be an env file**: `CLOUDFLARE_DNS_API_TOKEN=<token>`, same as satsuma's.
  I first encrypted the bare token, so lego failed with "credentials information are missing",
  NixOS silently fell back to a **self-signed cert**, and Thunderbird showed "Add Security
  Exception". I had also wrongly called the failing unit harmless.
- A failed first run also left an *unregistered* lego account
  (`accountDoesNotExist`). Fix: move `/var/lib/acme/.lego/accounts` aside and re-run
  `systemctl restart acme-order-renew-mail.estrogenuinely.ca.service`.
- Stalwart reads the cert at startup, so `systemctl restart stalwart` after issuance.
- Always check what is actually served (not just that the unit "ran"):

```bash
echo | openssl s_client -connect mail.estrogenuinely.ca:993 -servername mail.estrogenuinely.ca \
  -verify_hostname mail.estrogenuinely.ca -verify_return_error 2>&1 | grep -E 'Verif|issuer'
```

## Outbound via AWS SES

- OVH blocks outbound 25 and a fresh VPS IP has no reputation, so all outbound goes through
  SES (region **us-east-2 / Ohio**), domain identity `estrogenuinely.ca` (any `*@estrogenuinely.ca`
  can send). Inbound is untouched (direct on 25; user confirmed inbound 25 is fine).
- Endpoint: **`email-smtp.us-east-2.amazonaws.com:587`** (STARTTLS). NOT `...amazonses.com`
  (that name does not exist; it cost a long detour). Reachable from the vps.
- Credentials: SES console → SMTP settings → Create SMTP credentials (IAM user `ovh`). Stored
  as `ses_smtp_user.age` / `ses_smtp_pass.age`. Don't use Mail Manager credentials; that is a
  different product with different endpoints.
- Stalwart 0.15 config:

```toml
[queue.route.ses]
type = "relay"
address = "email-smtp.us-east-2.amazonaws.com"
port = 587
protocol = "smtp"
tls.implicit = false
auth.username = "%{file:/run/credentials/stalwart.service/ses_user}%"
auth.secret   = "%{file:/run/credentials/stalwart.service/ses_pass}%"

[queue.strategy]
route = "'ses'"        # expression: quoted literal = send everything via SES
```

- **Sandbox**: SES only delivers to *verified* recipients (and caps volume) until production
  access is granted. Nothing in the config changes afterwards. To test now: verify a
  recipient identity in SES, send from a mail client logged in as `rhuang`, then check the
  received headers for `spf=pass dkim=pass dmarc=pass` and no "via amazonses.com".
- Custom MAIL FROM `bounce.estrogenuinely.ca` gives SPF alignment as well as DKIM alignment.

## DNS (Cloudflare, all DNS-only / grey cloud) — verified with dig

| Name                                                        | Type  | Value                                                           |
| ----------------------------------------------------------- | ----- | --------------------------------------------------------------- |
| `mail`                                                      | A     | `15.235.101.89`                                                 |
| `mail`                                                      | AAAA  | `2607:5300:205:200::d27c`                                       |
| `@`                                                         | MX    | `10 mail.estrogenuinely.ca.`                                    |
| `@`                                                         | TXT   | `v=spf1 include:amazonses.com mx -all` (exactly one SPF record) |
| `_dmarc`                                                    | TXT   | `v=DMARC1; p=none;` (exactly one DMARC record)                  |
| 3× `<token>._domainkey`                                     | CNAME | `<token>.dkim.amazonses.com` (from the SES identity page)       |
| `bounce`                                                    | MX    | `10 feedback-smtp.us-east-2.amazonses.com.`                     |
| `bounce`                                                    | TXT   | `v=spf1 include:amazonses.com ~all`                             |
| `autoconfig`, `autodiscover`                                | CNAME | `mail.estrogenuinely.ca`                                        |
| `_imaps/_imap/_submission(s)/_jmap/_caldavs/_carddavs._tcp` | SRV   | → `mail.estrogenuinely.ca`                                      |

- **PTR** (OVH → IP → Reverse DNS, not "Secondary DNS"): both `15.235.101.89` and
  `2607:5300:205:200::d27c` → `mail.estrogenuinely.ca`. Verified (FCrDNS holds for v4 and v6).
- Stalwart's webadmin also generates DKIM keys, TLSA (DANE), MTA-STS, TLS-RPT and its own
  SPF/DMARC suggestions. I removed TLSA and MTA-STS (DANE needs DNSSEC and cert-rotation
  automation, MTA-STS needs a publicly served policy) and Stalwart's duplicate SPF/DMARC
  (two SPF or two DMARC records invalidates both). Don't re-import Stalwart's zone blindly.
- Later: tighten DMARC to `p=quarantine` with an `rua=` once a few messages pass.

## Gotchas / lessons

- **Queue routing must keep local delivery.** `queue.strategy.route = "'ses'"` replaced
  Stalwart's default and sent *inbound* mail for our own users out to SES, which rejected it
  (sender not a verified SES identity), so mail was silently lost. Correct form:
  `[{if = "is_local_domain('*', rcpt_domain)", then = "'local'"}, {else = "'ses'"}]`.
  An LDAP directory has no domain list, so `directory.kanidm.lookup.domains` must be set too.
  Test: send to `rui@` and check the journal shows "Message ingested" and no
  `email-smtp...amazonaws.com` line.
- **`bind.auth.search = false` is required with kanidm.** After the password bind Stalwart
  re-reads the user's entry over the *user's own* LDAP session by default, and kanidm hides
  `emailprimary` from user-bound sessions. The cached principal then had **no emails** and
  every send failed with "You are not allowed to send from this address". With
  `search = false` it uses the service-account lookup instead. Check:
  `GET /api/principal/rhuang` on the admin listener must show `"emails":["rui@estrogenuinely.ca"]`.
- **Turn off Stalwart's own DKIM signing when SES signs.** Default is two signatures (RSA +
  Ed25519); SES rejects with `Duplicate header 'DKIM-Signature'`. Config:
  `auth.dkim.sign = [{if="false", then="[...]"}, {else=false}]` (an `else`-only list is a parse
  error: "Found 'else' before 'if'"). Mail is signed by SES via the 3 DKIM CNAMEs. The
  Stalwart-generated DKIM TXT records are therefore unused; don't publish them.
- **Don't map kanidm `mail` to Stalwart `email`.** `mail` also holds the external aliases
  (Proton, Gmail). Stalwart registers every address it sees as *local*, so `protonmail.com`
  became a local domain (visible under webadmin → Domains) and mail to any Proton user got
  `550 Mailbox does not exist`. Use kanidm's `emailprimary` (single address) instead.
  Deleting the domain in the UI alone doesn't help; it comes back at the next login.
  Check with an RCPT probe: `RCPT TO:<x@protonmail.com>` must give `Relay not allowed`.
- Inbound probe without sending anything (run it from the vps; many home ISPs block outbound 25):
  connect to `15.235.101.89:25`, `EHLO`, `MAIL FROM`, `RCPT TO`, `QUIT`.

- **Fallback-admin password must have no trailing newline.** Stalwart compares the credential
  file byte for byte, so a secret saved by `agenix -e` (editors add a final newline) only works
  if you can type a newline, which you can't. Symptom: webadmin says "You are not authorized"
  and the API returns 401 even though the secret is right. Fix: re-encrypt without the newline,
  e.g. `printf %s "$(age -d -i /etc/ssh/ssh_host_ed25519_key stalwart_admin.age)" | age -r <vps> -r <rhuang> -a -o stalwart_admin.age`.
  Check with `wc -c /run/agenix/stalwart_admin` (should equal the password length).
  Also: **after rotating any `LoadCredential` secret, `systemctl restart stalwart`**. `switch`
  does not restart it, and it keeps the old value until then (same for the LDAP token and SES creds).
- **Cloudflare token printed in chat.** A debug command on the vps secret only redacted
  `NAME=value` lines and the file had no `=`, so the token went into a transcript. Rotate
  it in Cloudflare (done 2026-10-11), then re-encrypt for `vps/secrets/cloudflare_api.age` **and**
  `satsuma/secrets/cloudflare_api.age` (same token, env-file format).
  `agenix -e` run on the vps leaves the change uncommitted in the vps checkout, and a
  `git reset --hard origin/...` deploy would erase it. Commit/push first, or copy the `.age`
  to satsuma.
- Always make redaction commands fail closed (print only lengths/var names, never the line).
- ACME/NixOS "dependant services will still start" with a self-signed cert: verify the served
  issuer after any ACME change.
- Tailscale `--accept-dns` on the vps makes `/etc/resolv.conf` point at 100.100.100.100;
  public names still resolve, but `tailscale set --accept-dns=false` flips it to OVH's
  resolver (I restored it; kanidm's tailnet name needs it).
- OVH VPS: outbound 25 blocked, 587 open.
- Don't also set `services.tailscale` per host (it lives in `common.nix`).

## webadmin package issue (nixpkgs pin)

nixpkgs `stalwart.webadmin` (v0.1.37) doesn't build: `libdeflate-sys` 1.23.1 emits GCC
`target("evex512")` attributes that GCC 16 rejects, and it isn't in cache.nixos.org.
Workaround in use: fetch the upstream release zip for the same tag and point Stalwart at it.

```nix
webadminZip = pkgs.fetchurl {
  url  = "https://github.com/stalwartlabs/webadmin/releases/download/v0.1.37/webadmin.zip";
  hash = "sha256-nIJFxOFHoIBt1/lH97tfOHYay6o3Gwtb3Ap5A2s7WQk=";
};
# settings.webadmin.resource = "file://${webadminZip}";
```

Remove once nixpkgs builds or substitutes it.

## Stalwart 0.16.x (future)

Pinned to 0.15.5 because `services.stalwart` references `cfg.package.webadmin`, which
`pkgs.stalwart_0_16` (0.16.23) doesn't have (`attribute 'webadmin' missing`, tested).
0.16 would bring **automatic DNS management** (`DnsServer` + `Domain.dnsManagement =
Automatic`, publishes MX/SPF/DKIM/DMARC to Cloudflare itself) and the declarative
`stalwart-cli apply` model. Config is JSON objects there, not TOML, so most of the key
names above change. Upgrade path: wait for the module, or override the package and patch
around the `webadmin` reference, then migrate with `migrate_v016`. DKIM stays a webadmin
task until then.

## TODO

Done so far: Thunderbird login, inbound (Gmail → rui@), outbound via SES (SPF/DKIM/DMARC pass at
Proton), Cloudflare token rotation (both hosts), merge to main.

### Should do soon
- [ ] **Reload Stalwart after cert renewal.** `security.acme.certs."mail.estrogenuinely.ca"` has no
      `reloadServices`, and Stalwart reads the cert only at startup. The cert expires
      **2027-01-09**; the first renewal (~2026-12) will succeed but Stalwart will keep serving the
      old cert until restarted, then clients start failing. Fix: add
      `reloadServices = [ "stalwart.service" ];` (or `postRun = "systemctl restart stalwart"`),
      deploy, and confirm with the `openssl s_client` issuer/expiry check.
- [ ] **Backups.** Nothing backs up `/var/lib/stalwart` (RocksDB: all mail) or the vps secrets.
      Decide on restic/borg to satsuma or object storage, and test a restore.
- [x] **Log in once as `lena`** and check her account gets only `lena@estrogenuinely.ca` and no `gmail.com` appears under Domains (the Proton-domain fix was only tested on `rhuang`).
- [ ] **SES production access** (sandbox only delivers to verified recipients). No config change
      needed afterwards. Then re-test sending to an unverified address.
- [x] **Test autodiscovery** from a fresh Thunderbird profile off the tailnet (just email + password). Only the HTTPS endpoint was verified, not a real client.
- [x] **Verify the new Cloudflare tokens can edit DNS.** Only zone/DNS *read* was tested. Run astaging ACME order, or wait for the first renewal and check `journalctl -u acme-order-renew-mail.estrogenuinely.ca`.

### Cleanup
- [ ] Delete `~/Downloads/smtp-credentials.csv` (unused Mail Manager creds) and the
      `~/Downloads/estrogenuinely.ca*.txt` zone exports.
- [ ] Keep `~/Downloads/ovh_credentials.csv` (the SES SMTP creds in use) in a password manager,
      then delete it from Downloads. If lost, create new SES SMTP credentials and re-encrypt
      `ses_smtp_user.age` / `ses_smtp_pass.age`.
- [ ] Remove local scratch files: `~/stalwart-fix.nix`, `~/vps-configuration.nix`, `~/stalwart-work/`.
- [ ] Remove any leftover `/var/lib/acme/.lego/accounts.unregistered-*` on the vps.
- [x] The cached Stalwart principals may still hold stale data from before the `emailprimary` change; confirm `rhuang` shows only `rui@estrogenuinely.ca` (it did on 2026-10-11).

### Later
- [ ] Tighten DMARC from `p=none` to `p=quarantine`, add `rua=mailto:rui@estrogenuinely.ca`,
      after a few clean sends and a look at the reports.
- [ ] Remove the `webadmin.zip` override once nixpkgs `stalwart.webadmin` builds or substitutes.
- [ ] Upgrade to Stalwart 0.16 when the NixOS module supports it: native DNS management,
      declarative config. DKIM would then be managed by Stalwart; revisit the SES-signs-DKIM choice.
- [ ] Consider webmail/JMAP once a client is worth using (JMAP is already public on 443).
- [ ] Keep the `Stalwart.md` "Gotchas" section current.


# System Mail / Alerts (satsuma → Stalwart)

Reworked 2026-10-15. All outbound mail from **satsuma** — disk alerts, cron,
`systemd` `OnFailure`, Nextcloud, Vaultwarden — now relays through our own
[[Stalwart]] server on the **mail** VPS and goes out as per-service
`@estrogenuinely.ca` addresses. This replaces the old Postfix → Proton relay that
rewrote every sender to a single `alerts@ruihuang.io`.

> Supersedes the old `Mail.md` (Postfix→Proton relay). See [[Stalwart]] for the
> mail server itself and [[Monitoring]] for metrics/alerting ideas.

## At a glance

| Thing | Value |
| ----- | ----- |
| Relay (Postfix on satsuma) | `services.postfix` → `[mail.estrogenuinely.ca]:587` (STARTTLS + SASL) |
| Auth account | kanidm `homelab-svc` (one credential for everything on satsuma) |
| Sender addresses | `alerts@`, `nextcloud@`, `vaultwarden@` `estrogenuinely.ca` |
| Default sender (no explicit From) | `alerts@estrogenuinely.ca` (via `myorigin`) |
| Outbound path | satsuma Postfix → Stalwart (vps) → **AWS SES** → internet |
| Secrets | `postfix_sasl.age`, `mail_pass.age`, `vaultwarden_token.age` (all = `homelab-svc` password) |

## Why

- Stalwart (via SES) can send from **any** `*@estrogenuinely.ca`, so there is no
  reason to collapse everything onto one rewritten address any more. Each service
  gets its own From, which makes filtering and reading alerts far nicer.
- Keeps all mail on our own domain/infra instead of Proton SMTP.

## Architecture

```
smartd / cron / systemd ─┐
Nextcloud  ──────────────┤  (From: <service>@estrogenuinely.ca)
Vaultwarden ─────────────┘
          │
          ▼  AUTH as homelab-svc, STARTTLS :587
   Postfix relay (satsuma)              apps connect to Stalwart directly too
          │
          ▼
   Stalwart (mail VPS) ──:587 STARTTLS──▶ AWS SES (us-east-2) ──▶ internet
```

- Postfix handles locally-generated system mail (smartd, cron, `OnFailure`).
- Nextcloud and Vaultwarden talk SMTP to Stalwart **directly** (not through
  Postfix), but with the same `homelab-svc` credential and their own From.

## The `homelab-svc` account

One kanidm account authenticates all of satsuma's senders.

- It is a **person** account, not a service account. kanidm service accounts
  **cannot** do an LDAP password bind (`service-account credential generate` says
  the password "can NOT be used with the LDAP interface", and there is no
  `posix set-password` for them). Stalwart authenticates by binding to kanidm
  *as the user*, so the account needs a POSIX **unix password** — a person-only
  feature. Functionally it is still a shared service identity.
- Holds all sender addresses in its multi-valued `mail` attribute; the first is
  the primary:

```bash
kanidm person get homelab-svc -D idm_admin
# mail: alerts@estrogenuinely.ca      (primary)
# mail: nextcloud@estrogenuinely.ca
# mail: vaultwarden@estrogenuinely.ca
```

- Login name for SMTP AUTH is the kanidm **name** (`homelab-svc`), not an email
  (same as Thunderbird; see [[Stalwart]]).
- Create / change addresses / set the LDAP-bindable password:

```bash
kanidm person create homelab-svc "Homelab Service (outbound mail)" -D idm_admin
kanidm person update homelab-svc -m alerts@estrogenuinely.ca \
  -m nextcloud@estrogenuinely.ca -m vaultwarden@estrogenuinely.ca -D idm_admin
kanidm person posix set homelab-svc -D idm_admin           # posix extension
kanidm person posix set-password homelab-svc -D idm_admin  # TTY prompt (x2)
```

> `posix set-password` reads from a TTY; it can't be piped. Drive it from a real
> terminal (or a `pty` wrapper). After setting it, re-encrypt the three secrets
> below to the new value.

## Sender authorization (the multi-address trick)

Stalwart's default `must-match-sender` only lets a principal send from its **own**
addresses (primary + aliases). We did **not** widen the global LDAP attribute
mapping to expose `mail` as aliases, because kanidm's `mail` also holds users'
**external** addresses (`rhuang` → Proton, `lena` → Gmail) and Stalwart would
register `protonmail.com` / `gmail.com` as *local* domains — the exact bug called
out in [[Stalwart]] → Gotchas.

Instead, `email = emailprimary` stays as-is for everyone, and a **scoped
exception** in `vps/stalwart.nix` authorizes just `homelab-svc` for just the three
service addresses:

```nix
session.auth.must-match-sender = [
  {
    "if" = ''
      (authenticated_as == 'homelab-svc' ||
       authenticated_as == 'homelab-svc@idm.estrogenuinely.ca') &&
      contains(
        ['alerts@estrogenuinely.ca', 'nextcloud@estrogenuinely.ca', 'vaultwarden@estrogenuinely.ca'],
        sender
      )'';
    "then" = false;          # false = "no match required" = allowed
  }
  { "else" = true; }         # everyone else keeps the strict default
];
```

- `authenticated_as` resolves to the bare kanidm name (`homelab-svc`), confirmed
  from a live send.
- To add a new service sender later: add the address to `homelab-svc`'s `mail` in
  kanidm **and** to the `contains([...])` list here, then rebuild the vps.

## Files changed

| File | Change |
| ---- | ------ |
| `satsuma/mail.nix` | Relay → `[mail.estrogenuinely.ca]:587`; dropped the sender-rewrite `mapFiles`/`smtp_generic_maps`; `myorigin = estrogenuinely.ca`, `myhostname = satsuma.estrogenuinely.ca` |
| `satsuma/hardware-configuration.nix` | smartd `sender = alerts@…`, `recipient = rui@estrogenuinely.ca` |
| `satsuma/nextcloud/nextcloud.nix` | SMTP → Stalwart, `mail_smtpname = homelab-svc`, From `nextcloud@…`, `mail_smtpsecure = ""` (STARTTLS) |
| `satsuma/vaultwarden.nix` | SMTP → Stalwart, `SMTP_USERNAME = homelab-svc`, `SMTP_FROM = vaultwarden@…` |
| `vps/stalwart.nix` | Scoped `session.auth.must-match-sender` exception |
| `satsuma/secrets/postfix_sasl.age` | `[mail.estrogenuinely.ca]:587 homelab-svc:<pw>` (Postfix texthash) |
| `satsuma/secrets/mail_pass.age` | Nextcloud `mail_smtppassword` = `homelab-svc` pw (plain) |
| `satsuma/secrets/vaultwarden_token.age` | `SMTP_PASSWORD=<homelab-svc pw>` (env file) |

Commits `c709aac` (switch) and `7b3dc38` (Nextcloud `mail_smtpsecure` fix) on
`main`. Deploy flow is the usual one (see [[Stalwart]] → Git / NixOS / deploying):
commit → push → on each host `git fetch && git reset --hard origin/main &&
nixos-rebuild switch`.

## Gotchas / lessons

- **Service accounts can't LDAP-bind.** Use a *person* account with a POSIX unix
  password. See above.
- **Nextcloud `mail_smtpsecure` only accepts `""` or `"ssl"`.** `"tls"` fails the
  module's type check at eval time. STARTTLS on 587 = `""`; implicit TLS on 465 =
  `"ssl"`.
- **After rotating a Stalwart `LoadCredential` secret, `systemctl restart
  stalwart`** — a `switch` alone doesn't restart it (see [[Stalwart]]). Not needed
  for this change (the exception is config, not a credential), but keep it in mind
  when rotating the `homelab-svc` password: re-encrypt all three `.age` files, then
  `nixos-rebuild switch` on satsuma (postfix/nextcloud/vaultwarden pick it up on
  restart).
- The Stalwart "Database key defined in local configuration" journal warnings for
  the new `session.auth.must-match-sender.*` keys are **expected and harmless**
  (same as every other local expression key).

## Verified (2026-10-15)

- Postfix relay: `alerts@`, `nextcloud@`, `vaultwarden@` all `status=sent`
  (`250 … queued`), `relay=mail.estrogenuinely.ca:587 tls=encrypt`; Stalwart logged
  *Message ingested* + *Queued message submission for delivery*.
- Direct SMTP (simulating the apps): STARTTLS + AUTH as `homelab-svc`; all three
  senders `MAIL FROM` → `250 OK`.
- **Negative test:** `notallowed@estrogenuinely.ca` is rejected with
  `501 5.5.4 You are not allowed to send from this address` — the exception is
  scoped to exactly the three addresses, no domain-wide spoofing.
- Nextcloud `occ config:system:get` shows the new host/name/from; Vaultwarden
  restarted clean.

## Not done yet / ideas

- The old **Proton SMTP app token** is now unused everywhere; revoke it in Proton
  when convenient.
- No automated test that mail still flows (e.g. a daily `sendmail` canary → inbox).
- SES is still in **sandbox** (see [[Stalwart]]): outbound only reaches *verified*
  recipients until production access is granted. `rui@`/`lena@` work; alerts to an
  unverified external address will be held by SES.
- See [[Monitoring]] → *Grafana alerting* for turning these mail paths into real
  alert notifications.

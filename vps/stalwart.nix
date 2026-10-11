{ config, pkgs, lib, ... }:

let
  domain = "estrogenuinely.ca";
  mailHost = "mail.estrogenuinely.ca";

  # kanidm LDAPS endpoint, reached privately over the Tailscale network.
  # satsuma is the kanidm host; MagicDNS resolves this name on the tailnet.
  kanidmLdapUrl = "ldaps://satsuma.tailf59fe4.ts.net:3636";
  kanidmBaseDn = "dc=idm,dc=estrogenuinely,dc=ca";

  # The nixpkgs `stalwart.webadmin` derivation (v0.1.37) fails to build from
  # source on this toolchain: libdeflate-sys 1.23.1 emits GCC target()
  # attributes ("evex512"/"no-evex512") that GCC 16 rejects. Upstream ships a
  # prebuilt artifact for the exact same tag, so we fetch that release zip and
  # point Stalwart's webadmin resource at it instead of building from source.
  webadminZip = pkgs.fetchurl {
    url = "https://github.com/stalwartlabs/webadmin/releases/download/v0.1.37/webadmin.zip";
    hash = "sha256-nIJFxOFHoIBt1/lH97tfOHYay6o3Gwtb3Ap5A2s7WQk=";
  };
in
{
  # ---------------------------------------------------------------------------
  # Secrets
  # ---------------------------------------------------------------------------
  # Cloudflare API token (DNS-01 ACME) - reused from the shared pattern.
  age.secrets.cloudflare_api.file = ./secrets/cloudflare_api.age;

  # kanidm read-only API token used by Stalwart as the LDAP service-bind
  # password (bind DN "dn=token"). Owned by the stalwart service user.
  age.secrets.kanidm_ldap_token = {
    file = ./secrets/kanidm_ldap_token.age;
    owner = "stalwart";
    group = "stalwart";
    mode = "0400";
  };

  # Random fallback-admin password for the Stalwart web admin. Because
  # authentication is delegated to the kanidm directory, this built-in admin
  # is the reliable way to reach the web UI (e.g. to register domains, read
  # DNS records, rotate DKIM) even if the directory is unavailable.
  age.secrets.stalwart_admin = {
    file = ./secrets/stalwart_admin.age;
    owner = "stalwart";
    group = "stalwart";
    mode = "0400";
  };

  # AWS SES SMTP relay credentials (outbound). The username is an SES SMTP
  # user (AKIA...), the secret its SMTP password. Kept out of the world-
  # readable nix store via agenix + systemd LoadCredential.
  age.secrets.ses_smtp_user = {
    file = ./secrets/ses_smtp_user.age;
    owner = "stalwart";
    group = "stalwart";
    mode = "0400";
  };
  age.secrets.ses_smtp_pass = {
    file = ./secrets/ses_smtp_pass.age;
    owner = "stalwart";
    group = "stalwart";
    mode = "0400";
  };

  # ---------------------------------------------------------------------------
  # TLS certificates via ACME (Cloudflare DNS-01)
  # ---------------------------------------------------------------------------
  security.acme = {
    acceptTerms = true;
    defaults.email = "rui.huang17@protonmail.com";
    certs."${mailHost}" = {
      domain = mailHost;
      extraDomainNames = [
        "autoconfig.${domain}"
        "autodiscover.${domain}"
        "mta-sts.${domain}"
      ];
      group = "stalwart";
      dnsProvider = "cloudflare";
      environmentFile = config.age.secrets.cloudflare_api.path;
      dnsResolver = "1.1.1.1:53";
      extraLegoRunFlags = [ "--ari-disable" ];
    };
  };

  # Let the stalwart service read the ACME certificate material.
  users.users.stalwart.extraGroups = [ "acme" ];

  # ---------------------------------------------------------------------------
  # Stalwart mail server
  # ---------------------------------------------------------------------------
  services.stalwart = {
    enable = true;
    # Fresh install on current NixOS: use the modern RocksDB storage layout.
    stateVersion = "26.05";
    # Firewall ports are opened explicitly below (per interface), so the
    # module's blanket openFirewall is disabled. This lets us keep the HTTP
    # listener (web admin / management API / JMAP) off the public internet.
    openFirewall = false;

    # The kanidm LDAP service-bind token is exposed to the process via
    # systemd LoadCredential at /run/credentials/stalwart.service/ldap_token
    credentials.ldap_token = config.age.secrets.kanidm_ldap_token.path;

    # Fallback admin password, loaded as a credential and referenced below.
    credentials.fallback_admin = config.age.secrets.stalwart_admin.path;

    # AWS SES SMTP relay credentials, exposed to the service via LoadCredential.
    credentials.ses_user = config.age.secrets.ses_smtp_user.path;
    credentials.ses_pass = config.age.secrets.ses_smtp_pass.path;

    settings = {
      # -- Server identity ---------------------------------------------------
      server.hostname = mailHost;

      # -- Fallback admin ----------------------------------------------------
      # Built-in administrator for the web UI / management API. Username is
      # "admin"; the password comes from the loaded credential. Needed because
      # normal authentication is delegated to the kanidm directory.
      authentication.fallback-admin = {
        user = "admin";
        secret = "%{file:/run/credentials/stalwart.service/fallback_admin}%";
      };

      # -- Web admin: use the upstream prebuilt zip (see webadminZip note) ----
      webadmin.resource = "file://${webadminZip}";

      # -- HTTP endpoint access control (Option A) ---------------------------
      # The public `https` listener (443) serves everything EXCEPT the admin
      # UI (/admin) and management API (/api). Those are served only on the
      # `https-admin` listener (8443), which is firewalled to tailscale0.
      # This keeps autodiscovery (.well-known, autoconfig, autodiscover),
      # JMAP and OAuth reachable publicly while the admin surface stays on
      # the tailnet. The expression returns an HTTP status: 200 allow / 403 deny.
      # (Admin/API also still require authentication; this is defense in depth.)
      http.allowed-endpoint = [
        {
          "if" = "listener == 'https-admin' || !contains(['admin', 'api'], split(url_path, '/')[1])";
          "then" = 200;
        }
        { "else" = 403; }
      ];

      # -- TLS: use the ACME certificate issued above ------------------------
      certificate.default = {
        cert = "%{file:/var/lib/acme/${mailHost}/fullchain.pem}%";
        private-key = "%{file:/var/lib/acme/${mailHost}/key.pem}%";
      };
      server.tls.certificate = "default";

      # -- Listeners ---------------------------------------------------------
      server.listener = {
        smtp = {
          protocol = "smtp";
          bind = "[::]:25";
        };
        submission = {
          protocol = "smtp";
          bind = "[::]:587";
        };
        submissions = {
          protocol = "smtp";
          bind = "[::]:465";
          tls.implicit = true;
        };
        imap = {
          protocol = "imap";
          bind = "[::]:143";
        };
        imaptls = {
          protocol = "imap";
          bind = "[::]:993";
          tls.implicit = true;
        };
        # Public HTTPS: JMAP, autoconfig/autodiscover, .well-known, OAuth.
        # (Admin UI / management API are blocked here by allowed-endpoint.)
        https = {
          protocol = "http";
          bind = "[::]:443";
          tls.implicit = true;
        };
        # Tailnet-only HTTPS for the admin UI + management API (8443,
        # firewalled to tailscale0). allowed-endpoint lets /admin and /api
        # through only on this listener.
        https-admin = {
          protocol = "http";
          bind = "[::]:8443";
          tls.implicit = true;
        };
      };

      # -- Storage (defaults from the module provide RocksDB) ----------------
      # Authenticate/look up principals against the kanidm LDAP directory.
      storage.directory = "kanidm";

      # -- Outbound relay via AWS SES (smarthost) ----------------------------
      # OVH blocks outbound port 25, and sending directly from a VPS IP has
      # poor deliverability, so all outbound mail is relayed through Amazon
      # SES (region us-east-2) over submission/STARTTLS with SASL auth. SES
      # signs with the DKIM identity we verified, and the custom MAIL FROM
      # (bounce.estrogenuinely.ca) gives SPF alignment too.
      queue.route.ses = {
        type = "relay";
        address = "email-smtp.us-east-2.amazonaws.com";
        port = 587;
        protocol = "smtp";
        tls.implicit = false; # STARTTLS on 587
        tls.allow-invalid-certs = false;
        auth.username = "%{file:/run/credentials/stalwart.service/ses_user}%";
        auth.secret = "%{file:/run/credentials/stalwart.service/ses_pass}%";
      };
      # Route remote recipients through the SES relay, but keep local
      # delivery for our own domains. (A bare 'ses' here replaced Stalwart's
      # default and sent mail for local mailboxes out to SES, which rejected
      # it: inbound mail was lost.) Expressions need quoted string literals.
      queue.strategy.route = [
        { "if" = "is_local_domain('*', rcpt_domain)"; "then" = "'local'"; }
        { "else" = "'ses'"; }
      ];

      # Do not DKIM-sign in Stalwart. Outbound mail is signed by SES (Easy
      # DKIM, the three *.dkim.amazonses.com CNAMEs). Stalwart's default signs
      # twice (RSA + Ed25519) and SES rejects the message with
      # "Duplicate header 'DKIM-Signature'".
      auth.dkim.sign = [
        { "if" = "false"; "then" = "['rsa-' + sender_domain]"; }
        { "else" = false; }
      ];

      # -- kanidm LDAP directory --------------------------------------------
      directory.kanidm = {
        type = "ldap";
        url = kanidmLdapUrl;
        base-dn = kanidmBaseDn;
        timeout = "30s";

        # Service-account bind for directory lookups. kanidm accepts a bind
        # DN of "dn=token" with an API token as the password to grant the
        # service account's elevated read permissions.
        bind = {
          dn = "dn=token";
          secret = "%{file:/run/credentials/stalwart.service/ldap_token}%";

          # Bind-authentication: when a user logs in (IMAP/SMTP/JMAP),
          # Stalwart binds to kanidm *as that user* with the supplied
          # password. This is what lets traditional clients such as
          # Thunderbird authenticate with their kanidm credentials.
          auth = {
            # 0.15.x keys: method "template" = bind as the user using a DN
            # built from the template, "?" being the login name. (Older docs
            # use auth.enable / auth.dn; those are ignored by 0.15.5, which
            # then falls back to comparing a password hash that kanidm never
            # exposes, so every login failed without ever binding.)
            method = "template";
            # kanidm generates DNs from the spn/name/uuid attributes.
            template = "name=?,${kanidmBaseDn}";
            # Read the user's entry with the service account, not the user's
            # own bound session: kanidm hides attributes such as emailprimary
            # from a user-bound LDAP session, so the principal ended up with
            # no email addresses ("not allowed to send from this address").
            search = false;
          };
        };

        # Attribute mapping: kanidm -> Stalwart.
        # Local domains served by this directory. is_local_domain() (used by
        # the queue route strategy and recipient checks) matches against this
        # list; an LDAP directory has no domain list of its own.
        lookup.domains = [ domain ];

        attributes = {
          class = "class";
          name = "name";
          # kanidm's `mail` also holds external addresses (Proton, Gmail).
          # Stalwart registers every address it sees as local, which turned
          # protonmail.com into a "local domain" and broke mail to Proton
          # users. `emailprimary` is the single @estrogenuinely.ca address.
          email = "emailprimary";
          groups = "memberof";
          description = "displayname";
        };

        # Lookup filters. Restrict to authenticatable accounts (class=account).
        filter = {
          name = "(&(class=account)(name=?))";
          email = "(&(class=account)(emailprimary=?))";
        };

        cache.entries = 500;

        tls = {
          enable = false; # url already specifies ldaps:// (implicit TLS)
          # kanidm's LDAPS cert is for idm.estrogenuinely.ca, but we connect
          # over the tailnet hostname satsuma.tailf59fe4.ts.net, so the cert
          # name will not match. The connection is already encrypted and
          # authenticated end-to-end by Tailscale (WireGuard), so we accept
          # the kanidm certificate without hostname verification.
          allow-invalid-certs = true;
        };
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Firewall (Option A: public mail + public autodiscovery; admin tailnet-only)
  # ---------------------------------------------------------------------------
  # Public (all interfaces):
  #   25  SMTP (inbound MX)      465 submissions (implicit TLS)
  #   587 submission (STARTTLS)  143 IMAP        993 IMAPS
  #   443 HTTPS (JMAP, autoconfig/autodiscover, .well-known, OAuth)
  # The admin UI / management API are blocked on 443 by `allowed-endpoint`;
  # they are only served on the `https-admin` listener (8443) below.
  networking.firewall.allowedTCPPorts = [ 25 465 587 143 993 443 ];

  # Tailnet-only: the admin HTTP listener (8443) carrying the web admin UI
  # and management API. Reach it at https://<tailnet-name>:8443. ACME uses
  # DNS-01 (Cloudflare), so none of this is needed for cert issuance.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 8443 ];
}

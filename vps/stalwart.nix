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
        # JMAP / web admin / autoconfig over HTTPS.
        https = {
          protocol = "http";
          bind = "[::]:443";
          tls.implicit = true;
        };
      };

      # -- Storage (defaults from the module provide RocksDB) ----------------
      # Authenticate/look up principals against the kanidm LDAP directory.
      storage.directory = "kanidm";

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
            enable = true;
            # kanidm generates DNs from the spn/name/uuid attributes.
            dn = "name=?,${kanidmBaseDn}";
          };
        };

        # Attribute mapping: kanidm -> Stalwart.
        attributes = {
          class = "class";
          name = "name";
          email = "mail";
          groups = "memberof";
          description = "displayname";
        };

        # Lookup filters. Restrict to authenticatable accounts (class=account).
        filter = {
          name = "(&(class=account)(name=?))";
          email = "(&(class=account)(mail=?))";
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
  # Firewall (Option B: admin surface is tailnet-only)
  # ---------------------------------------------------------------------------
  # Public (all interfaces): the mail protocols that remote servers and
  # traditional clients (Thunderbird etc.) need.
  #   25  SMTP (inbound MX)      465 submissions (implicit TLS)
  #   587 submission (STARTTLS)  143 IMAP        993 IMAPS
  networking.firewall.allowedTCPPorts = [ 25 465 587 143 993 ];

  # Tailnet-only: the HTTP listener on 443 serves the web admin UI, the
  # management API, JMAP and autoconfig. Keeping it on tailscale0 only means
  # the administrative surface is never exposed to the public internet.
  # ACME uses DNS-01 (Cloudflare), so 443 does NOT need to be public for
  # certificate issuance.
  #
  # NOTE: this also makes JMAP + client autoconfig tailnet-only. That is fine
  # while mail clients use IMAP/SMTP (ports above). See Stalwart.md "Option A"
  # for a future split (separate public JMAP listener) if off-tailnet JMAP /
  # webmail is ever needed.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 443 ];
}

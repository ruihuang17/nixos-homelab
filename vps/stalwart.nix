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
    openFirewall = true;

    # The kanidm LDAP service-bind token is exposed to the process via
    # systemd LoadCredential at /run/credentials/stalwart.service/ldap_token
    credentials.ldap_token = config.age.secrets.kanidm_ldap_token.path;

    settings = {
      # -- Server identity ---------------------------------------------------
      server.hostname = mailHost;

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
  # Firewall: mail + submission + imap + https.
  # (services.stalwart.openFirewall opens the listener ports above, but we
  #  also need the ACME/HTTP(S) flows to work; 25/465/587/143/993/443.)
  # ---------------------------------------------------------------------------
  networking.firewall.allowedTCPPorts = [ 25 465 587 143 993 443 ];
}

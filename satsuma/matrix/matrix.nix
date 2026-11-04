{
  pkgs,
  lib,
  config,
  ...
}:
let
  sharedSecretAuthLegacy = pkgs.python3Packages.buildPythonPackage {
    pname = "matrix-synapse-shared-secret-auth-legacy";
    version = "1.0.0";
    format = "other";
    src = ./shared_secret_auth_legacy.py;
    dontUnpack = true;
    doCheck = false;
    installPhase = ''
      mkdir -p $out/lib/python3.14/site-packages
      cp ${./shared_secret_auth_legacy.py} $out/lib/python3.14/site-packages/shared_secret_auth_legacy.py
    '';
  };
in
{

  age.secrets.matrix_oidc = {
    file = "/etc/nixos/satsuma/secrets/matrix_oidc.age";
    mode = "770";
    owner = "matrix-synapse";
    group = "matrix-synapse";
  };

  # Registration shared secret, used to register the homelab alert bot (and any
  # future service bots) via `register_new_matrix_user`. Kept out of the Nix
  # store via agenix and injected through Synapse's extraConfigFiles so it is
  # not persisted to a world-readable store path.
  age.secrets.synapse_registration_secret = {
    file = "/etc/nixos/satsuma/secrets/synapse_registration_secret.age";
    mode = "440";
    owner = "matrix-synapse";
    group = "matrix-synapse";
  };

  # mautrix-imessage appservice registration. Contains the as_token/hs_token the
  # bridge and Synapse share, so it must not live as a plaintext file under
  # /var/lib. agenix decrypts it to /run/agenix at boot and Synapse reads it
  # from there via app_service_config_files.
  age.secrets.imessage-appservice = {
    file = "/etc/nixos/satsuma/secrets/imessage-appservice.age";
    mode = "440";
    owner = "matrix-synapse";
    group = "matrix-synapse";
  };

  # mautrix-wsproxy keeps the same appservice tokens in its own config. Decrypt
  # it from agenix as well so no plaintext copy of the tokens remains under
  # /var/lib.
  age.secrets.mautrix-wsproxy-config = {
    file = "/etc/nixos/satsuma/secrets/mautrix-wsproxy-config.age";
    mode = "0400";
    owner = "mautrix-wsproxy";
    group = "mautrix-wsproxy";
  };

  # The SMS bridge's appservice registration (same treatment as iMessage).
  age.secrets.sms-appservice = {
    file = "/etc/nixos/satsuma/secrets/sms-appservice.age";
    mode = "440";
    owner = "matrix-synapse";
    group = "matrix-synapse";
  };

  # Password provider for the legacy mautrix-imessage double-puppeting method.
  # The bridge uses the imessage appservice as_token as the shared password
  # (bridge.login_shared_secret is null), so this file contains that same token.
  age.secrets.synapse_shared_secret_auth = {
    file = "/etc/nixos/satsuma/secrets/synapse_shared_secret_auth.age";
    mode = "0400";
    owner = "matrix-synapse";
    group = "matrix-synapse";
  };

  services.matrix-synapse = {
    enable = true;
    plugins = [ sharedSecretAuthLegacy ];
    # Secrets (registration shared secret) injected at runtime, not baked into
    # the Nix store.
    extraConfigFiles = [
      config.age.secrets.synapse_registration_secret.path
      "/run/matrix-synapse/shared-secret-auth.yaml"
    ];
    settings = {
      # server_name is the permanent Matrix identity (user IDs, room IDs,
      # federation signatures). The homeserver was wiped and rebuilt when
      # moving from ruihuang.io to estrogenuinely.ca (synapse#3031).
      server_name = "estrogenuinely.ca";
      public_baseurl = "https://matrix.estrogenuinely.ca/";
      serve_server_wellknown = true;
      listeners = [
        {
          port = 8008;
          bind_addresses = [ "127.0.0.1" ];
          type = "http";
          tls = false;
          x_forwarded = true;
          resources = [
            {
              names = [
                "client"
                "federation"
              ];
              compress = true;
            }
          ];
        }
      ];
      # The mautrix backfill sends bursts of historical messages. The defaults
      # (rc_message 0.2/s, burst 10) cause 429s and also block the user's join
      # requests. This is a single-user homeserver.
      rc_message = {
        per_second = 1;
        burst_count = 100;
      };
      rc_joins = {
        per_second = 0.5;
        burst_count = 50;
      };
      database = {
        args = {
          #dbname = "matrix-synapse";
          user = "matrix-synapse";
          host = "/var/run/postgresql";
        };
      };
      oidc_providers = [
        {
          idp_id = "kanidm";
          idp_name = "Kanidm";
          issuer = "https://idm.estrogenuinely.ca/oauth2/openid/synapse/";
          client_id = "synapse";
          client_secret_path = config.age.secrets.matrix_oidc.path;
          scopes = [
            "openid"
            "profile"
          ];
          user_mapping_provider.config = {
            localpart_template = "{{ user.preferred_username.split('@')[0].split('=')[0]  }}";
            display_name_template = "{{ user.name }}";
          };
        }
      ];
      app_service_config_files = [
        config.age.secrets.imessage-appservice.path
        config.age.secrets.sms-appservice.path
      ];
    };

  };

  # Legacy mautrix-imessage double puppeting: the bridge logs in as @rhuang
  # with the imessage appservice as_token as the password. Generate the
  # password-provider fragment at start so the secret never enters the Nix
  # store and does not depend on Synapse's YAML env-tag support.
  systemd.services.matrix-synapse.preStart = lib.mkAfter ''
    umask 077
    set -a
    . ${config.age.secrets.synapse_shared_secret_auth.path}
    set +a
    printf 'password_providers:\n  - module: shared_secret_auth_legacy.SharedSecretAuthProvider\n    config:\n      shared_secret: "%s"\n' "$SHARED_SECRET_AUTH" > /run/matrix-synapse/shared-secret-auth.yaml
  '';
  users.groups.mautrix-wsproxy = { };
  users.users.mautrix-wsproxy = {
    isSystemUser = true;
    group = "mautrix-wsproxy";
    home = "/var/lib/mautrix-wsproxy";
  };

  systemd.services.mautrix-wsproxy = {
    description = "mautrix-wsproxy - websocket proxy for mautrix bridges";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      # mautrix-wsproxy reads ./config.yaml relative to its working directory,
      # so config.yaml needs to live in /var/lib/mautrix-wsproxy too.
      ExecStart = "/var/lib/mautrix-wsproxy/mautrix-wsproxy -config ${config.age.secrets.mautrix-wsproxy-config.path}";
      WorkingDirectory = "/var/lib/mautrix-wsproxy";
      Restart = "on-failure";
      RestartSec = "5s";

      # Static user instead of DynamicUser: with DynamicUser=yes, systemd
      # recursively re-chowns StateDirectory to a freshly picked UID/GID on
      # EVERY service start, which silently reverts any ownership you set
      # by hand and can produce spurious EXEC-time permission errors.
      User = "mautrix-wsproxy";
      Group = "mautrix-wsproxy";
      StateDirectory = "mautrix-wsproxy";
      StateDirectoryMode = "0750";

      # Hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/mautrix-wsproxy" ];
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RemoveIPC = true;
      UMask = "0077";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
      SystemCallArchitectures = "native";
    };
  };

}

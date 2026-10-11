{
  pkgs,
  lib,
  config,
  ...
}:
{

  age.secrets.matrix_oidc = {
    file = "/etc/nixos/satsuma/secrets/matrix_oidc.age";
    mode = "770";
    owner = "matrix-synapse";
    group = "matrix-synapse";
  };

  services.matrix-synapse = {
    enable = true;
    settings = {
      # NOTE: server_name is the permanent Matrix identity. It is baked into
      # every user ID (@user:ruihuang.io), room ID, and federation signature
      # and CANNOT be changed without creating a brand-new, empty homeserver
      # (see matrix-org/synapse#3031). It is intentionally kept as ruihuang.io
      # to preserve existing accounts/rooms. Only the externally-facing URLs
      # below are migrated to estrogenuinely.ca.
      server_name = "ruihuang.io";
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
        "/var/lib/matrix-synapse/imessage-registraction.yaml"
      ];
    };
  };
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
      ExecStart = "/var/lib/mautrix-wsproxy/mautrix-wsproxy";
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

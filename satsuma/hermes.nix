{
  config,
  inputs,
  pkgs,
  ...
}:

{
  imports = [ inputs.hermes-agent.nixosModules.default ];

  age.secrets.hermes-env = {
    file = ./secrets/hermes-env.age;
    mode = "0400";
    owner = "hermes";
    group = "hermes";
  };

  age.secrets.hermes-discord = {
    file = ./secrets/hermes-discord.age;
    mode = "0400";
    owner = "hermes";
    group = "hermes";
  };

  age.secrets.jellyfin-api-key = {
    file = ./secrets/jellyfin-api-key.age;
    mode = "0400";
    owner = "hermes";
    group = "hermes";
  };

  users.users.hermes.extraGroups = [ "systemd-journal" ];

  services.hermes-agent = {
    enable = true;

    backend = {
      mode = "dashboard";
      host = "127.0.0.1";
      port = 9119;
    };

    settings = {
      model.default = "deepseek/deepseek-v4.1-flash-1017";
      toolsets = [ "all" ];
      terminal = {
        backend = "local";
        timeout = 180;
        env_passthrough = [
          "SONARR_API_KEY"
          "RADARR_API_KEY"
          "PROWLARR_API_KEY"
          "QBITTORRENT_PASSWORD"
          "JELLYFIN_API_KEY"
          "JELLYFIN_URL"
        ];
      };
      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
      };
      platforms.discord.enabled = true;
      display.platforms.discord.tool_progress = "off";
      discord = {
        require_mention = true;
        auto_thread = true;
        allowed_channels = "1563363787090821222";
      };
      dashboard.public_url = "https://hermes.local.estrogenuinely.ca";
      dashboard.oauth.self_hosted = {
        issuer = "https://idm.estrogenuinely.ca/oauth2/openid/hermes";
        client_id = "hermes";
        scopes = "openid profile email";
      };
    };

    environment = {
      DISCORD_ALLOWED_USERS = "454892601175441418,606668600451006485";
      DISCORD_HOME_CHANNEL = "1563363787090821222";
      SONARR_URL = "http://127.0.0.1:8989";
      RADARR_URL = "http://127.0.0.1:7878";
      PROWLARR_URL = "http://127.0.0.1:9696";
      QBITTORRENT_URL = "http://10.200.200.2:8080";
      QBITTORRENT_USERNAME = "admin";
      JELLYFIN_URL = "http://10.0.10.73:8096";
      PROMETHEUS_URL = "http://127.0.0.1:9090";
    };
    environmentFiles = [
      config.age.secrets.hermes-env.path
      config.age.secrets.hermes-discord.path
    ];
    addToSystemPackages = true;
    extraPackages = [ pkgs.nix ];
  };

  systemd.services.hermes-media-acl = {
    description = "Grant Hermes read-only access to the media library";
    wantedBy = [ "multi-user.target" ];
    before = [ "hermes-agent.service" ];
    unitConfig.RequiresMountsFor = [ "/hdd/mediaSrv" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      ${pkgs.zfs}/bin/zfs set acltype=posixacl hdd/mediaSrv
      ${pkgs.acl}/bin/setfacl -m u:hermes:r-x /hdd/mediaSrv
      ${pkgs.acl}/bin/setfacl -m u:hermes:r-x /hdd/mediaSrv/media
      ${pkgs.acl}/bin/setfacl -m u:hermes:r-x /hdd/mediaSrv/torrent
    '';
  };

  systemd.services.hermes-media-keys = {
    description = "Provision Hermes media API credentials";
    wantedBy = [ "multi-user.target" ];
    before = [ "hermes-agent.service" ];
    requires = [ "grove-arr-keys.service" ];
    after = [ "grove-arr-keys.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "hermes-media";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ReadOnlyPaths = [ "/run/agenix" "/run/grove-exporter" ];
      ReadWritePaths = [ "/run/hermes-media" ];
    };
    script = ''
      set -eu
      out=/run/hermes-media/env
      tmp=/run/hermes-media/env.tmp
      : > "$tmp"
      ${pkgs.coreutils}/bin/printf 'SONARR_API_KEY=%s\n' "$(${pkgs.coreutils}/bin/cat /run/grove-exporter/sonarr.key)" >> "$tmp"
      ${pkgs.coreutils}/bin/printf 'RADARR_API_KEY=%s\n' "$(${pkgs.coreutils}/bin/cat /run/grove-exporter/radarr.key)" >> "$tmp"
      ${pkgs.coreutils}/bin/printf 'PROWLARR_API_KEY=%s\n' "$(${pkgs.coreutils}/bin/cat /run/grove-exporter/prowlarr.key)" >> "$tmp"
      ${pkgs.coreutils}/bin/printf 'QBITTORRENT_PASSWORD=%s\n' "$(${pkgs.coreutils}/bin/cat /run/agenix/qbittorrent-password)" >> "$tmp"
      ${pkgs.coreutils}/bin/printf 'JELLYFIN_API_KEY=%s\n' "$(${pkgs.coreutils}/bin/cat /run/agenix/jellyfin-api-key)" >> "$tmp"
      ${pkgs.coreutils}/bin/chmod 0400 "$tmp"
      ${pkgs.coreutils}/bin/mv "$tmp" "$out"
    '';
  };

  systemd.services.hermes-agent = {
    wants = [ "hermes-media-acl.service" "hermes-media-keys.service" ];
    after = [ "hermes-media-acl.service" "hermes-media-keys.service" ];
    serviceConfig.EnvironmentFile = [ "-/run/hermes-media/env" ];
  };
}

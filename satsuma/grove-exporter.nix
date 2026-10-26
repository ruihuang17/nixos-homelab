{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.services.groveExporter;
  keyDir = "/run/grove-exporter";
  anyArr = cfg.sonarr.enable || cfg.radarr.enable || cfg.prowlarr.enable;

  keyService = "grove-arr-keys.service";
  arrService = name: "prometheus-exportarr-${name}-exporter.service";

  scrape =
    job: port:
    {
      job_name = job;
      scrape_interval = cfg.scrapeInterval;
      static_configs = [
        {
          targets = [ "127.0.0.1:${toString port}" ];
        }
      ];
    };
in
{
  options.services.groveExporter = {
    enable = mkEnableOption "the Grove dashboard telemetry exporters";

    bind = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address for the Grove insights exporter to listen on.";
    };

    port = mkOption {
      type = types.port;
      default = 9123;
      description = "Port for the Grove insights exporter.";
    };

    scrapeInterval = mkOption {
      type = types.str;
      default = "30s";
      description = "Prometheus scrape interval for the Grove telemetry jobs.";
    };

    zfs = {
      enable = mkEnableOption "the ZFS pool, vdev and scrub exporter";
      port = mkOption {
        type = types.port;
        default = 9700;
        description = "Port for the zfs-siebenmann exporter.";
      };
    };

    smartctl = {
      enable = mkEnableOption "the SMART drive exporter";
      port = mkOption {
        type = types.port;
        default = 9633;
        description = "Port for the smartctl exporter.";
      };
    };

    sonarr = {
      enable = mkEnableOption "the Sonarr exporter";
      url = mkOption {
        type = types.str;
        default = "http://127.0.0.1:8989";
        description = "URL of the Sonarr API.";
      };
      configFile = mkOption {
        type = types.path;
        default = "/var/lib/sonarr/.config/NzbDrone/config.xml";
        description = "Sonarr config.xml used to read the API key.";
      };
      port = mkOption {
        type = types.port;
        default = 9708;
        description = "Port for the Sonarr exporter.";
      };
    };

    radarr = {
      enable = mkEnableOption "the Radarr exporter";
      url = mkOption {
        type = types.str;
        default = "http://127.0.0.1:7878";
        description = "URL of the Radarr API.";
      };
      configFile = mkOption {
        type = types.path;
        default = "/var/lib/radarr/.config/Radarr/config.xml";
        description = "Radarr config.xml used to read the API key.";
      };
      port = mkOption {
        type = types.port;
        default = 9709;
        description = "Port for the Radarr exporter.";
      };
    };

    prowlarr = {
      enable = mkEnableOption "the Prowlarr exporter";
      url = mkOption {
        type = types.str;
        default = "http://127.0.0.1:9696";
        description = "URL of the Prowlarr API.";
      };
      configFile = mkOption {
        type = types.path;
        default = "/var/lib/private/prowlarr/config.xml";
        description = "Prowlarr config.xml used to read the API key.";
      };
      port = mkOption {
        type = types.port;
        default = 9710;
        description = "Port for the Prowlarr exporter.";
      };
    };

    qbittorrent = {
      enable = mkEnableOption "the qBittorrent exporter";
      url = mkOption {
        type = types.str;
        default = "http://10.200.200.2:8080";
        description = "URL of the qBittorrent web UI.";
      };
      username = mkOption {
        type = types.str;
        default = "admin";
        description = "qBittorrent web UI username.";
      };
      passwordFile = mkOption {
        type = types.path;
        default = "/run/agenix/qbittorrent-password";
        description = "File containing the qBittorrent web UI password.";
      };
      cookieName = mkOption {
        type = types.str;
        default = "QBT_SID_8080";
        description = "qBittorrent session cookie name (QBT_SID_<port> on 5.2+).";
      };
      port = mkOption {
        type = types.port;
        default = 9711;
        description = "Port for the qBittorrent exporter.";
      };
    };

    unifi = {
      enable = mkEnableOption "the Ubiquiti UniFi network exporter";

      url = mkOption {
        type = types.str;
        default = "https://10.0.10.1";
        description = ''
          URL of the UniFi Network controller. UniFi OS consoles such as the
          Cloud Gateway use HTTPS on port 443, while a self-hosted controller
          normally listens on port 8443.
        '';
      };

      user = mkOption {
        type = types.str;
        default = "grove";
        description = ''
          Local UniFi account used for the read-only poll. Create a dedicated
          account with a monitor/viewer role rather than using the owner login.
        '';
      };

      passwordFile = mkOption {
        type = types.path;
        default = "/run/agenix/unifi-grove-password";
        description = ''
          File containing the UniFi account password. The unpoller exporter
          runs as the unpoller-exporter user, so the file must be readable by
          that group.
        '';
      };

      verifySsl = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Verify the controller TLS certificate. UniFi consoles ship with a
          self-signed certificate on the LAN, so this defaults to false.
        '';
      };

      sites = mkOption {
        type = types.either types.str (types.listOf types.str);
        default = "all";
        description = "UniFi site name, a list of site names, or all.";
      };

      port = mkOption {
        type = types.port;
        default = 9130;
        description = "Port for the unpoller Prometheus exporter.";
      };
    };

    jellyfin = {
      enable = mkEnableOption "optional Jellyfin library metrics";
      url = mkOption {
        type = types.str;
        default = "http://10.0.10.73:8096";
        description = "URL of the Jellyfin server.";
      };
      apiKeyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File containing a Jellyfin API key.";
      };
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra arguments for the Grove insights exporter.";
    };
  };

  config = mkIf cfg.enable {
    services.prometheus.exporters.zfs-siebenmann = mkIf cfg.zfs.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.zfs.port;
      depth = 2;
      fullPath = true;
    };

    services.prometheus.exporters.smartctl = mkIf cfg.smartctl.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.smartctl.port;
    };

    services.prometheus.exporters.unpoller = mkIf cfg.unifi.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.unifi.port;
      controllers = [
        {
          url = cfg.unifi.url;
          user = cfg.unifi.user;
          pass = cfg.unifi.passwordFile;
          sites = cfg.unifi.sites;
          verify_ssl = cfg.unifi.verifySsl;
          save_sites = true;
          save_ids = false;
          save_events = false;
          save_alarms = false;
          save_anomalies = false;
          save_dpi = false;
        }
      ];
    };

    systemd.services.grove-arr-keys = mkIf anyArr {
      description = "Extract *arr API keys for Grove exporters";
      wantedBy = [ "multi-user.target" ];
      before =
        lib.optionals cfg.sonarr.enable [ (arrService "sonarr") ]
        ++ lib.optionals cfg.radarr.enable [ (arrService "radarr") ]
        ++ lib.optionals cfg.prowlarr.enable [ (arrService "prowlarr") ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "grove-exporter";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        ExecStart = pkgs.writeShellScript "grove-arr-keys" ''
          set -eu
          extract() {
            app="$1"
            source="$2"
            key=$(${pkgs.gnused}/bin/sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$source")
            if [ -z "$key" ]; then
              echo "grove-arr-keys: no API key in $source" >&2
              exit 1
            fi
            printf '%s' "$key" > "${keyDir}/$app.key"
          }
          ${lib.optionalString cfg.sonarr.enable ''
            extract sonarr ${lib.escapeShellArg (toString cfg.sonarr.configFile)}
          ''}
          ${lib.optionalString cfg.radarr.enable ''
            extract radarr ${lib.escapeShellArg (toString cfg.radarr.configFile)}
          ''}
          ${lib.optionalString cfg.prowlarr.enable ''
            extract prowlarr ${lib.escapeShellArg (toString cfg.prowlarr.configFile)}
          ''}
        '';
      };
    };

    services.prometheus.exporters.exportarr-sonarr = mkIf cfg.sonarr.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.sonarr.port;
      url = cfg.sonarr.url;
      apiKeyFile = "${keyDir}/sonarr.key";
    };

    services.prometheus.exporters.exportarr-radarr = mkIf cfg.radarr.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.radarr.port;
      url = cfg.radarr.url;
      apiKeyFile = "${keyDir}/radarr.key";
    };

    services.prometheus.exporters.exportarr-prowlarr = mkIf cfg.prowlarr.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      port = cfg.prowlarr.port;
      url = cfg.prowlarr.url;
      apiKeyFile = "${keyDir}/prowlarr.key";
    };

    systemd.services."prometheus-exportarr-sonarr-exporter" = mkIf cfg.sonarr.enable {
      requires = [ keyService ];
      after = [ keyService ];
    };

    systemd.services."prometheus-exportarr-radarr-exporter" = mkIf cfg.radarr.enable {
      requires = [ keyService ];
      after = [ keyService ];
    };

    systemd.services."prometheus-exportarr-prowlarr-exporter" = mkIf cfg.prowlarr.enable {
      requires = [ keyService ];
      after = [ keyService ];
    };

    systemd.services.grove-qbittorrent-exporter = mkIf cfg.qbittorrent.enable {
      description = "Prometheus qBittorrent exporter";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.prometheus-qbittorrent-exporter}/bin/qbit-exp";
        Environment = [
          "QBITTORRENT_BASE_URL=${cfg.qbittorrent.url}"
          "QBITTORRENT_USERNAME=${cfg.qbittorrent.username}"
          "QBITTORRENT_PASSWORD_FILE=${toString cfg.qbittorrent.passwordFile}"
          "QBITTORRENT_COOKIE_NAME=${cfg.qbittorrent.cookieName}"
          "EXPORTER_HOST=127.0.0.1"
          "EXPORTER_PORT=${toString cfg.qbittorrent.port}"
        ];
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadOnlyPaths = [ "/run/agenix" ];
      };
    };

    systemd.services.grove-exporter = {
      description = "Grove insights Prometheus exporter";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "postgresql.service"
      ] ++ lib.optional anyArr keyService;
      path = [
        config.services.postgresql.package
        pkgs.util-linux
        pkgs.tailscale
      ];
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.escapeShellArgs (
          [
            "${pkgs.python3}/bin/python3"
            "${./grove_exporter.py}"
            "--bind"
            cfg.bind
            "--port"
            (toString cfg.port)
          ]
          ++ lib.optionals cfg.jellyfin.enable [
            "--jellyfin-url"
            cfg.jellyfin.url
          ]
          ++ lib.optionals (cfg.jellyfin.enable && cfg.jellyfin.apiKeyFile != null) [
            "--jellyfin-api-key-file"
            (toString cfg.jellyfin.apiKeyFile)
          ]
          ++ cfg.extraArgs
        );
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadOnlyPaths =
          lib.optionals (cfg.jellyfin.enable && cfg.jellyfin.apiKeyFile != null) [
            cfg.jellyfin.apiKeyFile
          ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
      };
    };

    services.prometheus.scrapeConfigs = lib.mkAfter (
      lib.optional cfg.zfs.enable (scrape "grove-zfs" cfg.zfs.port)
      ++ lib.optional cfg.smartctl.enable (scrape "grove-smartctl" cfg.smartctl.port)
      ++ lib.optional cfg.sonarr.enable (scrape "grove-sonarr" cfg.sonarr.port)
      ++ lib.optional cfg.radarr.enable (scrape "grove-radarr" cfg.radarr.port)
      ++ lib.optional cfg.prowlarr.enable (scrape "grove-prowlarr" cfg.prowlarr.port)
      ++ lib.optional cfg.qbittorrent.enable (scrape "grove-qbittorrent" cfg.qbittorrent.port)
      ++ lib.optional cfg.unifi.enable (scrape "grove-unifi" cfg.unifi.port)
      ++ [
        (scrape "grove-insights" cfg.port)
      ]
    );
  };
}

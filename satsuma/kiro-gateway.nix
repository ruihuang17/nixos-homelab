{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.kiro-gateway;
  stateDir = "/var/lib/kiro-gateway";
  dbPath = "${stateDir}/kiro-cli/data.sqlite3";

  seedScript = pkgs.writeShellScript "kiro-gateway-seed" ''
    set -eu
    ${pkgs.coreutils}/bin/install -d -m 0700 -o ${cfg.user} -g ${cfg.group} ${stateDir}/kiro-cli
    if [ ! -e ${dbPath} ]; then
      ${pkgs.coreutils}/bin/install -m 0600 -o ${cfg.user} -g ${cfg.group} ${cfg.kiroCliDb} ${dbPath}
    fi
  '';

  syncCredentials = pkgs.writeShellScriptBin "kiro-gateway-sync-creds" ''
    set -euo pipefail
    if [ "$(id -u)" -ne 0 ]; then
      echo "run as root: sudo kiro-gateway-sync-creds" >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/install -m 0600 -o ${cfg.user} -g ${cfg.group} \
      ${cfg.kiroCliDb} ${dbPath}
    ${pkgs.systemd}/bin/systemctl restart kiro-gateway.service
    echo "synced ${cfg.kiroCliDb} -> ${dbPath} and restarted kiro-gateway"
  '';
in
{
  options.services.kiro-gateway = {
    enable = lib.mkEnableOption "the Kiro API proxy gateway";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8123;
      description = "Loopback port for the gateway.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "kiro-gateway";
      description = "User that runs the gateway.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "kiro-gateway";
      description = "Group that runs the gateway.";
    };

    kiroCliDb = lib.mkOption {
      type = lib.types.path;
      default = "/home/rhuang/.local/share/kiro-cli/data.sqlite3";
      description = ''
        kiro-cli SQLite database seeded into the gateway's private state
        directory on first start. Run `kiro-gateway-sync-creds` after logging
        in again with kiro-cli.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/kiro-gateway { };
      description = "kiro-gateway package to run.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.group} = { };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = stateDir;
      createHome = false;
    };

    # PROXY_API_KEY, PROFILE_ARN and KIRO_GATEWAY_API_KEY. The same file is
    # loaded by the OpenCode service so its provider can authenticate to the
    # loopback gateway.
    age.secrets.kiro-gateway-env = {
      file = ./secrets/kiro-gateway-env.age;
      owner = "root";
      group = "root";
      mode = "0400";
    };

    systemd.services.kiro-gateway = {
      description = "Kiro Gateway (Kiro API proxy)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = stateDir;
        ExecStart = "${cfg.package}/bin/kiro-gateway";
        # The seed script has to read rhuang's 0600 kiro-cli database.
        ExecStartPre = [ "+${seedScript}" ];
        EnvironmentFile = config.age.secrets.kiro-gateway-env.path;
        Environment = [
          "SERVER_HOST=127.0.0.1"
          "SERVER_PORT=${toString cfg.port}"
          "KIRO_CLI_DB_FILE=${dbPath}"
          # Both are prompt-injection-style additions to the first user turn.
          # They confuse coding harnesses that already send a large system
          # prompt, and OpenCode works better without them.
          "FAKE_REASONING=false"
          "TRUNCATION_RECOVERY=false"
          "LOG_LEVEL=INFO"
        ];
        StateDirectory = "kiro-gateway";
        StateDirectoryMode = "0700";
        Restart = "always";
        RestartSec = 3;
        UMask = "0077";
      };
    };

    environment.systemPackages = [ syncCredentials ];
  };
}

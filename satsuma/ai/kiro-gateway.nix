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
  accountsDir = "${stateDir}/accounts";
  credentialsFile = "${stateDir}/credentials.json";
  stateFile = "${stateDir}/state.json";

  seedScript = pkgs.writeShellScript "kiro-gateway-seed" ''
        set -eu
        ${pkgs.coreutils}/bin/install -d -m 0700 -o ${cfg.user} -g ${cfg.group} ${stateDir}/kiro-cli
        ${pkgs.coreutils}/bin/install -d -m 0700 -o ${cfg.user} -g ${cfg.group} ${accountsDir}

        # The first account is rhuang's kiro-cli login. Additional accounts are
        # added to ${accountsDir} with kiro-gateway-add-account.
        if [ ! -e ${dbPath} ]; then
          ${pkgs.coreutils}/bin/install -m 0600 -o ${cfg.user} -g ${cfg.group} \
            ${cfg.kiroCliDb} ${dbPath}
        fi

        # Account-system config. The legacy service created this file too, so leave
        # an existing file alone: it may already contain additional accounts.
        if [ ! -e ${credentialsFile} ]; then
          ${pkgs.coreutils}/bin/cat > ${credentialsFile} <<EOF
    [
      {
        "type": "sqlite",
        "path": "${dbPath}"
      }
    ]
    EOF
          ${pkgs.coreutils}/bin/chown ${cfg.user}:${cfg.group} ${credentialsFile}
          ${pkgs.coreutils}/bin/chmod 0600 ${credentialsFile}
        fi
  '';

  syncCredentials = pkgs.writeShellApplication {
    name = "kiro-gateway-sync-creds";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail
      if [ "$(id -u)" -ne 0 ]; then
        echo "run as root: sudo kiro-gateway-sync-creds" >&2
        exit 1
      fi

      install -d -m 0700 -o ${cfg.user} -g ${cfg.group} ${accountsDir}
      install -m 0600 -o ${cfg.user} -g ${cfg.group} ${cfg.kiroCliDb} ${dbPath}

      # Keep the first account's profile ARN in sync with the age secret.
      if [ -r /run/agenix/kiro-gateway-env ] && [ -f ${credentialsFile} ]; then
        profile_arn=$(sed -n 's/^PROFILE_ARN=//p' /run/agenix/kiro-gateway-env)
        if [ -n "$profile_arn" ]; then
          tmp=$(mktemp)
          jq --arg path ${dbPath} --arg arn "$profile_arn" \
            'map(if .path == $path then .profile_arn = $arn else . end)' \
            ${credentialsFile} > "$tmp"
          install -m 0600 -o ${cfg.user} -g ${cfg.group} "$tmp" ${credentialsFile}
          rm -f "$tmp"
        fi
      fi

      systemctl restart kiro-gateway.service
      echo "synced ${cfg.kiroCliDb} -> ${dbPath} and restarted kiro-gateway"
    '';
  };

  addAccount = pkgs.writeShellApplication {
    name = "kiro-gateway-add-account";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.sqlite
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail

      if [ "$(id -u)" -ne 0 ]; then
        echo "run as root: sudo kiro-gateway-add-account <kiro-cli-db> [name] [profile-arn]" >&2
        exit 1
      fi
      if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
        echo "usage: sudo kiro-gateway-add-account <kiro-cli-db> [name] [profile-arn]" >&2
        exit 1
      fi

      db=$1
      name=''${2:-$(basename "$db" .sqlite3)}
      profile_arn=''${3:-}

      if [ ! -f "$db" ]; then
        echo "credential database not found: $db" >&2
        exit 1
      fi
      if [ -z "$name" ]; then
        echo "account name must not be empty" >&2
        exit 1
      fi
      case "$name" in
        *[!A-Za-z0-9._-]*)
          echo "invalid account name '$name'; use letters, digits, dot, underscore or dash" >&2
          exit 1
          ;;
      esac

      if ! sqlite3 "$db" \
        "select name from sqlite_master where type='table' and name='auth_kv';" \
        | grep -q auth_kv; then
        echo "$db does not look like a kiro-cli database (no auth_kv table)" >&2
        exit 1
      fi

      # Prefer an explicit profile ARN, then the token in the database, then
      # the kiro-cli state table. Builder ID accounts usually need it passed in.
      if [ -z "$profile_arn" ]; then
        profile_arn=$(sqlite3 "$db" \
          "select value from auth_kv where key in ('kirocli:odic:token','kirocli:social:token','codewhisperer:odic:token') limit 1;" \
          2>/dev/null | jq -r '.profile_arn // empty' 2>/dev/null || true)
      fi
      if [ -z "$profile_arn" ]; then
        profile_arn=$(sqlite3 "$db" \
          "select value from state where key='api.codewhisperer.profile';" \
          2>/dev/null | jq -r '.arn // empty' 2>/dev/null || true)
      fi
      if [ -z "$profile_arn" ]; then
        echo "could not determine a profile ARN for $db" >&2
        echo "pass it explicitly as the third argument, for example:" >&2
        echo "  sudo kiro-gateway-add-account $db $name 'arn:aws:codewhisperer:us-east-1:...:profile/...'" >&2
        echo "Builder ID accounts expose it in the Kiro CLI log:" >&2
        echo "  grep 'Profile ARN rotated' ~/.kiro/logs/*/kiro.log" >&2
        exit 1
      fi

      install -d -m 0700 -o ${cfg.user} -g ${cfg.group} ${accountsDir}
      target=${accountsDir}/"$name".sqlite3
      if [ -e "$target" ]; then
        echo "refusing to overwrite existing account database $target" >&2
        echo "choose a different name or remove it first" >&2
        exit 1
      fi
      install -m 0600 -o ${cfg.user} -g ${cfg.group} "$db" "$target"

      if [ ! -f ${credentialsFile} ]; then
        printf '[]\n' > ${credentialsFile}
        chown ${cfg.user}:${cfg.group} ${credentialsFile}
        chmod 0600 ${credentialsFile}
      fi

      tmp=$(mktemp)
      jq --arg path "$target" --arg arn "$profile_arn" '
        if any(.[]; .path == $path)
        then map(if .path == $path then .profile_arn = $arn else . end)
        else . + [{"type": "sqlite", "path": $path, "profile_arn": $arn}]
        end
      ' ${credentialsFile} > "$tmp"
      install -m 0600 -o ${cfg.user} -g ${cfg.group} "$tmp" ${credentialsFile}
      rm -f "$tmp"

      systemctl restart kiro-gateway.service
      echo "added account '$name' ($profile_arn); restarted kiro-gateway"
    '';
  };
in
{
  options.services.kiro-gateway = {
    enable = lib.mkEnableOption "the Kiro API proxy gateway";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8123;
      description = "Port the gateway listens on.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address the gateway binds to. Set to "0.0.0.0" to expose it on the LAN
        (the firewall rule below then opens the port on lanInterface).
      '';
    };

    lanInterface = lib.mkOption {
      type = lib.types.str;
      default = "enp4s0";
      description = "LAN interface on which to allow the gateway port when address is not loopback.";
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
        kiro-cli SQLite database for the first account, seeded into the
        gateway's private state directory on first start. Run
        `kiro-gateway-sync-creds` after logging in again with kiro-cli.
        Additional accounts are added with `kiro-gateway-add-account`.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../pkgs/kiro-gateway { };
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
    # gateway.
    age.secrets.kiro-gateway-env = {
      file = ../secrets/kiro-gateway-env.age;
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
          "SERVER_HOST=${cfg.address}"
          "SERVER_PORT=${toString cfg.port}"
          "ACCOUNT_SYSTEM=true"
          "ACCOUNTS_CONFIG_FILE=${credentialsFile}"
          "ACCOUNTS_STATE_FILE=${stateFile}"
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

    # Expose the gateway on the LAN only when it is not loopback-bound. The
    # tailscale0 interface is already trusted, so tailnet access works too.
    networking.firewall.interfaces.${cfg.lanInterface}.allowedTCPPorts = lib.mkIf (
      cfg.address != "127.0.0.1"
    ) [ cfg.port ];

    environment.systemPackages = [
      syncCredentials
      addAccount
    ];
  };
}

{
  config,
  pkgs,
  lib,
  ...
}:
let
  port = 4096;
  primaryHost = "satsuma.local.estrogenuinely.ca";

  # Shared by both vhosts. The IP allowlist keeps the agent LAN/Tailnet-only
  # even if port 443 is reachable from the WAN.
  proxy = {
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      proxyWebsockets = true;
      extraConfig = ''
        allow 127.0.0.1;
        allow ::1;
        allow 10.0.10.0/24;
        allow 100.64.0.0/10;
        allow fd7a:115c:a1e0::/48;
        deny all;

        # SSE / long-running streams.
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 100m;
      '';
    };
  };
in
{
  age.secrets.opencode-password = {
    file = ./secrets/opencode-password.age;
    mode = "0400";
    owner = "opencode";
    group = "opencode";
  };

  users.users.opencode = {
    isSystemUser = true;
    group = "opencode";
    home = "/var/lib/opencode";
    createHome = true;
    extraGroups = [ "opencode-workspace" ];
    shell = pkgs.bash;
  };
  users.groups.opencode = { };

  # Shared workspace: the service owns writes, rhuang can add/edit checkouts,
  # and other users on the box cannot read it.
  users.groups.opencode-workspace = { };
  users.users.rhuang.extraGroups = [ "opencode-workspace" ];

  systemd.tmpfiles.rules = [
    "d /srv/opencode 2770 opencode opencode-workspace -"
    "d /srv/opencode/workspace 2770 opencode opencode-workspace -"
  ];

  systemd.services.opencode = {
    description = "OpenCode server (shared, always-on)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    environment = {
      HOME = "/var/lib/opencode";
      OPENCODE_LOG_LEVEL = "info";
    };

    # The agent's shells inherit this PATH; nixd keeps the configured Nix LSP
    # working for the opencode user.
    path = with pkgs; [
      bashInteractive
      coreutils
      curl
      fd
      git
      jq
      nix
      nixd
      openssh
      ripgrep
      which
    ];

    serviceConfig = {
      Type = "simple";
      User = "opencode";
      Group = "opencode";
      WorkingDirectory = "/var/lib/opencode";
      ExecStart = "${pkgs.opencode}/bin/opencode serve --hostname 127.0.0.1 --port ${toString port}";
      EnvironmentFile = config.age.secrets.opencode-password.path;

      Restart = "always";
      RestartSec = 3;
      TimeoutStopSec = 20;

      StateDirectory = "opencode";
      StateDirectoryMode = "0750";
      ReadWritePaths = [ "/srv/opencode" ];
      UMask = "0002";

      # Sandbox: the agent can write only its state and the workspace.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      CapabilityBoundingSet = "";
    };
  };

  services.nginx.virtualHosts = {
    "${primaryHost}" = {
      useACMEHost = "estrogenuinely.ca";
      forceSSL = true;
    }
    // proxy;

    # Optional nicer name; needs a CNAME to satsuma in Technitium.
    "opencode.local.estrogenuinely.ca" = {
      useACMEHost = "estrogenuinely.ca";
      forceSSL = true;
    }
    // proxy;
  };

  # sudo opencode-pair -> one-time login URL for a browser or the mobile app.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "opencode-pair" ''
      set -euo pipefail
      if [ "$(id -u)" -ne 0 ]; then
        echo "run as root: sudo opencode-pair" >&2
        exit 1
      fi
      password=$(sed -n 's/^OPENCODE_PASSWORD=//p' ${config.age.secrets.opencode-password.path})
      code=$(${pkgs.curl}/bin/curl -fsS -u "opencode:$password" \
        -X POST -H 'content-type: application/json' -d '{}' \
        http://127.0.0.1:${toString port}/api/pair | ${pkgs.jq}/bin/jq -r .code)
      echo "https://${primaryHost}/auth/connect/$code"
    '')
  ];
}

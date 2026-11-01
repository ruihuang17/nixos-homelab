{
  config,
  pkgs,
  lib,
  ...
}:
let
  port = 4096;
  primaryHost = "opencode.local.estrogenuinely.ca";

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
    owner = "root";
    group = "root";
  };

  # The service runs as root so the agent can administer the host (nixos-rebuild,
  # systemctl, /etc/nixos, other services' data). There is deliberately no
  # filesystem sandbox: anything else would defeat that purpose.
  users.groups.opencode-workspace = { };
  users.users.rhuang.extraGroups = [ "opencode-workspace" ];

  systemd.tmpfiles.rules = [
    "d /srv/opencode 2770 root opencode-workspace -"
    "d /srv/opencode/workspace 2770 root opencode-workspace -"
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

    # The full system profile, so agent shells get nixos-rebuild, systemctl,
    # nix, git and the rest without per-tool packaging. Also includes the
    # nixd LSP used by the configured languageserver.
    path = [
      config.system.path
      config.security.wrapperDir
    ];

    serviceConfig = {
      Type = "simple";
      User = "root";
      Group = "root";
      WorkingDirectory = "/var/lib/opencode";
      ExecStart = "${pkgs.opencode}/bin/opencode serve --hostname 127.0.0.1 --port ${toString port}";
      EnvironmentFile = config.age.secrets.opencode-password.path;

      Restart = "always";
      RestartSec = 3;
      TimeoutStopSec = 20;

      StateDirectory = "opencode";
      StateDirectoryMode = "0700";
      UMask = "0022";
    };
  };

  services.nginx.virtualHosts."${primaryHost}" = {
    useACMEHost = "estrogenuinely.ca";
    forceSSL = true;
  }
  // proxy;

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

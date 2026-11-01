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

    # nixos-rebuild must never restart this unit: the agent's shells live in
    # its cgroup, so a restart would kill an in-flight rebuild mid-activation
    # and drop the session that started it. Changes to this unit therefore
    # need an explicit `systemctl restart opencode`.
    unitConfig = {
      X-StopIfChanged = false;
      X-RestartIfChanged = false;
    };

    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    environment = {
      HOME = "/var/lib/opencode";
      OPENCODE_LOG_LEVEL = "info";
      # Point at /run/current-system rather than the store paths of this
      # generation. The unit text then stays byte-identical across rebuilds,
      # and agent shells always see the *current* system profile
      # (nixos-rebuild, systemctl, nix, git, nixd) even though the process is
      # never restarted by a switch.
      PATH = lib.mkForce "/run/current-system/sw/bin:/run/wrappers/bin:/nix/var/nix/profiles/default/bin";
    };

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
    # Detached switch. systemd-run puts the rebuild in its own cgroup
    # (system.slice/<unit>), so it survives this service being restarted and
    # is never killed halfway through activation. Use it from inside an agent
    # session, or when the rebuild may restart opencode itself.
    (pkgs.writeShellScriptBin "oc-rebuild" ''
      set -euo pipefail
      if [ "$(id -u)" -ne 0 ]; then
        echo "run as root: sudo oc-rebuild [extra nixos-rebuild args]" >&2
        exit 1
      fi
      unit="oc-rebuild-$(date +%Y%m%d-%H%M%S)"
      # Transient units inherit systemd's own minimal PATH, not the caller's,
      # so nix/git/nixos-rebuild must be put on it explicitly.
      /run/current-system/sw/bin/systemd-run --unit="$unit" --collect --no-block \
        --property=Type=oneshot \
        --property=WorkingDirectory=/etc/nixos \
        --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin \
        --setenv=HOME=/root \
        /run/current-system/sw/bin/nixos-rebuild switch --flake /etc/nixos#satsuma "$@"
      echo "rebuild queued as $unit.service"
      echo "follow with: journalctl -u $unit -f"
    '')

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

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

  # Kiro model IDs and their context windows, as reported by
  # `kiro-cli chat --list-models`. OpenCode requires the list explicitly
  # because the gateway's /v1/models is not in Anthropic's discovery format.
  kiroModels = [
    {
      id = "auto-kiro";
      name = "Kiro Auto";
      context = 1000000;
    }
    {
      id = "claude-opus-5.5";
      name = "Claude Opus 5.5";
      context = 1000000;
    }
    {
      id = "claude-sonnet-5.5";
      name = "Claude Sonnet 5.5";
      context = 1000000;
    }
    {
      id = "claude-haiku-5.5";
      name = "Claude Haiku 5.5";
      context = 1000000;
    }
    {
      id = "claude-opus-5";
      name = "Claude Opus 5";
      context = 1000000;
    }
    {
      id = "claude-sonnet-5";
      name = "Claude Sonnet 5";
      context = 1000000;
    }
    {
      id = "claude-opus-4.8";
      name = "Claude Opus 4.8";
      context = 1000000;
    }
    {
      id = "claude-opus-4.7";
      name = "Claude Opus 4.7";
      context = 1000000;
    }
    {
      id = "claude-opus-4.6";
      name = "Claude Opus 4.6";
      context = 1000000;
    }
    {
      id = "claude-sonnet-4.6";
      name = "Claude Sonnet 4.6";
      context = 1000000;
    }
    {
      id = "claude-opus-4.5";
      name = "Claude Opus 4.5";
      context = 200000;
    }
    {
      id = "claude-sonnet-4.5";
      name = "Claude Sonnet 4.5";
      context = 200000;
    }
    {
      id = "claude-haiku-4.5";
      name = "Claude Haiku 4.5";
      context = 200000;
    }
    {
      id = "gpt-5.6-sol";
      name = "GPT-5.6 Sol";
      context = 986000;
    }
    {
      id = "gpt-5.6-terra";
      name = "GPT-5.6 Terra";
      context = 986000;
    }
    {
      id = "gpt-5.6-luna";
      name = "GPT-5.6 Luna";
      context = 986000;
    }
    {
      id = "kimi-k3";
      name = "Kimi K3";
      context = 1000000;
    }
    {
      id = "deepseek-3.2";
      name = "DeepSeek 3.2";
      context = 164000;
    }
    {
      id = "minimax-m2.5";
      name = "MiniMax M2.5";
      context = 196000;
    }
    {
      id = "minimax-m2.1";
      name = "MiniMax M2.1";
      context = 196000;
    }
    {
      id = "glm-5";
      name = "GLM-5";
      context = 200000;
    }
    {
      id = "qwen3-coder-next";
      name = "Qwen3 Coder Next";
      context = 256000;
    }
  ];

  kiroProviderModels = builtins.listToAttrs (
    map (model: {
      name = model.id;
      value = {
        inherit (model) name;
        limit = {
          context = model.context;
          output = 32000;
        };
      };
    }) kiroModels
  );
in
{
  age.secrets.opencode-password = {
    file = ./secrets/opencode-password.age;
    mode = "0400";
    owner = "root";
    group = "root";
  };

  # Global OpenCode config (lower precedence than the user's
  # ~/.config/opencode/opencode.jsonc). The Kiro provider is available to every
  # project; the credential comes from the same agenix file as the gateway.
  environment.etc."opencode/opencode.json" = lib.mkIf config.services.kiro-gateway.enable {
    text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      providers.kiro = {
        name = "Kiro Gateway";
        env = [ "KIRO_GATEWAY_API_KEY" ];
        package = "@opencode/ai/providers/anthropic-compatible";
        settings.baseURL = "http://127.0.0.1:${toString config.services.kiro-gateway.port}/v1";
        models = kiroProviderModels;
      };
    };
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
      EnvironmentFile = [
        config.age.secrets.opencode-password.path
      ]
      ++ lib.optional config.services.kiro-gateway.enable config.age.secrets.kiro-gateway-env.path;

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

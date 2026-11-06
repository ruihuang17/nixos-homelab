{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  homelab = import ../../homelab.nix;

  port = 4096;
  primaryHost = "opencode.local.estrogenuinely.ca";

  matrix-mcp = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.matrix-mcp;
  email-mcp = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.email-mcp;
  bitwarden-mcp = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.bitwarden-mcp;

  # The Bitwarden MCP drives the `bw` CLI against our Vaultwarden. The CLI's
  # login state lives in bwDataDir and the unlocked-vault session key in
  # bwSessionFile; both are root-only and written by `bitwarden-mcp-login`.
  bwServer = "https://vaultwarden.estrogenuinely.ca";
  bwDataDir = "/var/lib/opencode/bitwarden";
  bwSessionFile = "${bwDataDir}/session";

  # The MCP server only forwards a short allowlist of environment variables to
  # `bw`, so the data dir and CLI path are set here. The session file is read
  # at start-up; a missing file just leaves the vault locked. File-based tools
  # (attachments, file Sends) stay disabled because BW_ALLOWED_DIRECTORIES is
  # unset.
  bitwarden-mcp-launcher = pkgs.writeShellScript "bitwarden-mcp-launcher" ''
    export BITWARDENCLI_APPDATA_DIR=${bwDataDir}
    export BW_CLI_PATH=${pkgs.bitwarden-cli}/bin/bw
    if [ -s ${bwSessionFile} ]; then
      BW_SESSION=$(cat ${bwSessionFile})
      export BW_SESSION
    fi
    exec ${bitwarden-mcp}/bin/mcp-server-bitwarden
  '';

  # The self-hosted mailbox is only configured once its agenix secret exists.
  # Checking here keeps a fresh checkout (or a missing credential) buildable;
  # create the secret with `email-mcp-set-password` and rebuild to enable it.
  emailSecret = ../secrets/email-mcp-pass.age;
  emailEnabled = builtins.pathExists emailSecret;

  # Public recipients from satsuma/secrets/secrets.nix, embedded in the helper
  # that encrypts a new mail password. These are public keys, not secrets.
  ageRecipients = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMp74d/OCwnetejX24slNj+6kIiEmarYX8j8+Zuku8IF"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH"
  ];

  # Shared by both vhosts. The IP allowlist keeps the agent LAN/Tailnet-only
  # even if port 443 is reachable from the WAN.
  proxy = {
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      proxyWebsockets = true;
      extraConfig = ''
        allow 127.0.0.1;
        allow ::1;
        allow ${homelab.lanCidr};
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
    file = ../secrets/opencode-password.age;
    mode = "0400";
    owner = "root";
    group = "root";
  };

  # Stalwart password for the email MCP. Stored without a trailing newline so
  # OpenCode's {file:...} substitution yields the exact credential.
  age.secrets.email-mcp-pass = lib.mkIf emailEnabled {
    file = emailSecret;
    mode = "0400";
    owner = "root";
    group = "root";
  };

  # Refresh token for the UWaterloo IMAP account. The proxy below owns the
  # on-disk copy after first start; this is the seed and recovery token.
  age.secrets.email-mcp-uw-token = {
    file = ../secrets/email-mcp-uw-token.age;
    mode = "0400";
    owner = "root";
    group = "root";
  };

  # Global OpenCode config (lower precedence than the user's
  # ~/.config/opencode/opencode.jsonc). The Kiro provider is available to every
  # project; the credential comes from the same agenix file as the gateway.
  # matrix-mcp runs as a stdio server under the OpenCode service (HOME
  # /var/lib/opencode), where its credentials and E2EE store live.
  environment.etc."opencode/opencode.json".text = builtins.toJSON (
    {
      "$schema" = "https://opencode.ai/config.json";
      mcp.servers = {
        matrix = {
          type = "local";
          command = [
            "${matrix-mcp}/bin/matrix-mcp"
            "serve"
          ];
        };

        bitwarden = {
          type = "local";
          command = [ "${bitwarden-mcp-launcher}" ];
        };

        # UWaterloo's tenant blocks Microsoft Graph apps, but the university's
        # Thunderbird setup uses IMAP + OAuth2 with Thunderbird's public client.
        # A second email-mcp instance reuses that flow.
        uw = {
          type = "local";
          command = [ "${email-mcp}/bin/email-mcp" "stdio" ];
          environment = {
            XDG_CONFIG_HOME = "/etc/email-mcp-uw";
          };
        };
      } // lib.optionalAttrs emailEnabled {
        email = {
          type = "local";
          command = [ "${email-mcp}/bin/email-mcp" "stdio" ];
          environment = {
            MCP_EMAIL_ACCOUNT_NAME = "estrogenuinely";
            MCP_EMAIL_FULL_NAME = "Rui Huang";
            MCP_EMAIL_ADDRESS = "rui@estrogenuinely.ca";
            # Stalwart resolves IMAP/SMTP logins against the kanidm name, not
            # the mail address (the homelab-svc service account behaves the
            # same way). The address above is still the From/envelope sender.
            MCP_EMAIL_USERNAME = "rhuang";
            MCP_EMAIL_PASSWORD = "{file:${config.age.secrets.email-mcp-pass.path}}";

            MCP_EMAIL_IMAP_HOST = "mail.estrogenuinely.ca";
            MCP_EMAIL_IMAP_PORT = "993";
            MCP_EMAIL_IMAP_TLS = "true";
            MCP_EMAIL_IMAP_VERIFY_SSL = "true";

            MCP_EMAIL_SMTP_HOST = "mail.estrogenuinely.ca";
            MCP_EMAIL_SMTP_PORT = "587";
            MCP_EMAIL_SMTP_TLS = "false";
            MCP_EMAIL_SMTP_STARTTLS = "true";
            MCP_EMAIL_SMTP_VERIFY_SSL = "true";
            MCP_EMAIL_SEND_SAVE_TO_SENT = "true";
            MCP_EMAIL_READ_ONLY = "false";
          };
        };
      };
    }
    // lib.optionalAttrs config.services.kiro-gateway.enable {
      providers.kiro = {
        name = "Kiro Gateway";
        env = [ "KIRO_GATEWAY_API_KEY" ];
        package = "@opencode/ai/providers/anthropic-compatible";
        settings.baseURL = "http://127.0.0.1:${toString config.services.kiro-gateway.port}/v1";
        models = kiroProviderModels;
      };
    }
  );

  # The UWaterloo account is an IMAP/OAuth2 account. Thunderbird's public
  # client ID is a public client, but email-mcp insists on sending a
  # client_secret during refresh; the local proxy drops it and talks to
  # Microsoft. The refresh token itself is in agenix and never in this file.
  environment.etc."email-mcp-uw/email-mcp/config.toml".text = ''
    # Managed by satsuma/ai/opencode.nix.
    [[accounts]]
    name = "uwaterloo"
    email = "r232huan@uwaterloo.ca"
    username = "r232huan@uwaterloo.ca"
    full_name = "Rui Huang"
    save_to_sent = true

    [accounts.oauth2]
    provider = "custom"
    client_id = "9e5f94bc-e8a4-4e73-b8be-63364c29d753"
    client_secret = "local-proxy"
    refresh_token = "local-proxy"
    token_url = "http://127.0.0.1:8799/token"
    auth_url = "http://127.0.0.1:8799/authorize"
    scopes = [
      "https://outlook.office.com/IMAP.AccessAsUser.All",
      "https://outlook.office.com/SMTP.Send",
    ]

    [accounts.imap]
    host = "outlook.office365.com"
    port = 993
    tls = true
    verify_ssl = true

    [accounts.smtp]
    host = "smtp.office365.com"
    port = 587
    tls = false
    starttls = true
    verify_ssl = true
  '';

  # email-mcp always sends a client_secret, which Microsoft rejects for
  # Thunderbird's public client. This loopback-only proxy refreshes with the
  # stored refresh token instead, and persists rotated tokens.
  systemd.services.email-mcp-oauth = {
    description = "Local OAuth2 token endpoint for the UWaterloo email MCP";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = {
      EMAIL_MCP_OAUTH_SEED = config.age.secrets.email-mcp-uw-token.path;
      EMAIL_MCP_OAUTH_STATE_DIR = "/var/lib/email-mcp-oauth";
    };
    serviceConfig = {
      Type = "simple";
      User = "root";
      Group = "root";
      ExecStart = "${pkgs.python3}/bin/python3 ${./email-oauth-proxy.py}";
      Restart = "always";
      RestartSec = 3;
      StateDirectory = "email-mcp-oauth";
      StateDirectoryMode = "0700";
      UMask = "0077";
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
    # The service runs as root with HOME=/var/lib/opencode (Matrix credentials
    # live there). Share root's gh login and SSH keys so git and gh work in the
    # agent's shells. Plain `L` never replaces an existing path.
    "L /var/lib/opencode/.config/gh - - - - /root/.config/gh"
    "L /var/lib/opencode/.ssh - - - - /root/.ssh"
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
    # The MCP server is launched by OpenCode, but keeping it on PATH lets an
    # admin re-run `matrix-mcp auth ...` and `matrix-mcp e2ee setup` directly.
    matrix-mcp

    # IMAP/SMTP MCP for the self-hosted mailbox, plus a helper to (re)encrypt
    # its credential after creating an app password in Stalwart.
    email-mcp
    (pkgs.writeShellScriptBin "email-mcp-set-password" ''
      set -euo pipefail
      if [ "$(id -u)" -ne 0 ]; then
        echo "run as root: sudo email-mcp-set-password" >&2
        exit 1
      fi
      target=/etc/nixos/satsuma/secrets/email-mcp-pass.age
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT
      if [ -t 0 ]; then
        printf 'Stalwart password for rui@estrogenuinely.ca: ' >&2
        IFS= read -r -s pw
        printf '\n' >&2
      else
        IFS= read -r pw
      fi
      if [ -z "''${pw:-}" ]; then
        echo "empty password; nothing written" >&2
        exit 1
      fi
      # No trailing newline: OpenCode substitutes the file contents verbatim
      # into MCP_EMAIL_PASSWORD.
      printf '%s' "$pw" > "$tmp"
      ${pkgs.age}/bin/age \
        -r ${lib.escapeShellArg (builtins.elemAt ageRecipients 0)} \
        -r ${lib.escapeShellArg (builtins.elemAt ageRecipients 1)} \
        -o "$target" "$tmp"
      chmod 0600 "$target"
      # The flake only sees git-tracked files, so stage the new secret.
      git -C /etc/nixos add "$target"
      echo "wrote and staged $target"
      echo "apply it with: sudo oc-rebuild"
    '')

    # Bitwarden CLI plus a helper that logs it into Vaultwarden and stores the
    # vault session key for the MCP. The master password is typed at the
    # prompt and never reaches the agent; only the session key is written.
    pkgs.bitwarden-cli
    bitwarden-mcp
    (pkgs.writeShellScriptBin "bitwarden-mcp-login" ''
      set -euo pipefail
      if [ "$(id -u)" -ne 0 ]; then
        echo "run as root: sudo bitwarden-mcp-login" >&2
        exit 1
      fi
      install -d -m 0700 -o root -g root ${bwDataDir}
      export BITWARDENCLI_APPDATA_DIR=${bwDataDir}
      bw=${pkgs.bitwarden-cli}/bin/bw
      if "$bw" login --check >/dev/null 2>&1; then
        session=$("$bw" unlock --raw)
      else
        "$bw" config server ${bwServer} >&2
        session=$("$bw" login --raw)
      fi
      if [ -z "$session" ]; then
        echo "no session key returned; nothing written" >&2
        exit 1
      fi
      umask 077
      printf '%s' "$session" > ${bwSessionFile}.tmp
      mv ${bwSessionFile}.tmp ${bwSessionFile}
      echo "wrote ${bwSessionFile}; restart the bitwarden MCP (or opencode) to pick it up" >&2
    '')

    # Recreate the runtime Matrix credentials after `matrix-mcp auth logout`
    # or a lost /var/lib/opencode. Synapse's legacy shared-secret password
    # provider lets root log in as @rhuang without an interactive password.
    # Each run creates a fresh dedicated Matrix device, so the guard requires
    # --force when credentials already exist.
    (pkgs.writeShellScriptBin "matrix-mcp-login" ''
      set -euo pipefail
      if [ "$(id -u)" -ne 0 ]; then
        echo "run as root: sudo matrix-mcp-login [--force]" >&2
        exit 1
      fi
      state_dir=/var/lib/opencode/.config/matrix-mcp
      config=$state_dir/config.json
      if [ -e "$config" ] && [ "''${1:-}" != "--force" ]; then
        echo "matrix-mcp is already configured at $config; pass --force to create a new device." >&2
        exit 1
      fi
      set -a
      . ${config.age.secrets.synapse_shared_secret_auth.path}
      set +a
      install -d -m 0700 -o root -g root "$state_dir"
      # Feed the password on stdin rather than argv, so it never appears in
      # the process list.
      printf '%s\n' "$SHARED_SECRET_AUTH" | HOME=/var/lib/opencode ${matrix-mcp}/bin/matrix-mcp auth password \
        https://matrix.estrogenuinely.ca \
        @rhuang:estrogenuinely.ca \
        --device-name "matrix-mcp (OpenCode)" \
        --config "$config"
      chmod 0600 "$config"
    '')

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

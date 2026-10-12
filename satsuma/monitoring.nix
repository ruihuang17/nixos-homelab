{
  config,
  pkgs,
  lib,
  ...
}:
{
  # Grafana admin password, kept out of the Nix store via agenix.
  # Decryptable by the satsuma host key (see secrets/secrets.nix).
  age.secrets.grafana_admin_pass = {
    file = "/etc/nixos/satsuma/secrets/grafana_admin_pass.age";
    mode = "400";
    owner = "grafana";
    group = "grafana";
  };

  # Grafana's secret_key (used to sign/encrypt values in its DB) must be
  # provided explicitly on current nixpkgs. Kept out of the Nix store.
  age.secrets.grafana_secret_key = {
    file = "/etc/nixos/satsuma/secrets/grafana_secret_key.age";
    mode = "400";
    owner = "grafana";
    group = "grafana";
  };

  # Kanidm OAuth2 client secret for the "grafana" client.
  age.secrets.grafana_oidc_secret = {
    file = "/etc/nixos/satsuma/secrets/grafana_oidc_secret.age";
    mode = "400";
    owner = "grafana";
    group = "grafana";
  };

  ##########################################################################
  # node_exporter for satsuma itself is provided by the shared
  # server-common.nix module (imported from the flake), listening on
  # 127.0.0.1:9100 by default.
  ##########################################################################

  ##########################################################################
  # Prometheus
  ##########################################################################
  services.prometheus = {
    enable = true;
    port = 9090;
    # Loopback only; exposed (read-only, internal) through nginx.
    listenAddress = "127.0.0.1";
    retentionTime = "90d";

    globalConfig.scrape_interval = "30s";

    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [
          {
            targets = [ "127.0.0.1:9100" ];
            labels.instance = "satsuma";
          }
          {
            targets = [ "10.0.10.23:9100" ];
            labels.instance = "orange";
          }
          {
            targets = [ "10.0.10.73:9100" ];
            labels.instance = "mac-mini";
          }
          {
            targets = [ "10.0.10.74:9100" ];
            labels.instance = "homeassistant";
          }
          {
            # mail VPS, scraped over the tailnet (its node_exporter binds to
            # its Tailscale address and the port is only open on tailscale0).
            targets = [ "100.91.236.114:9100" ];
            labels.instance = "mail";
          }
        ];
      }
      {
        job_name = "prometheus";
        static_configs = [
          {
            targets = [ "127.0.0.1:9090" ];
            labels.instance = "satsuma";
          }
        ];
      }
    ];
  };

  ##########################################################################
  # Grafana
  ##########################################################################
  services.grafana = {
    enable = true;

    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = 3000;
        domain = "grafana.local.estrogenuinely.ca";
        root_url = "https://grafana.local.estrogenuinely.ca/";
        enforce_domain = false;
      };

      security = {
        admin_user = "admin";
        # Read the admin password from the agenix secret at runtime via the
        # $__file provider, so the password never enters the Nix store.
        admin_password = "$__file{${config.age.secrets.grafana_admin_pass.path}}";
        secret_key = "$__file{${config.age.secrets.grafana_secret_key.path}}";
      };

      # Internal, SSO-less analytics dashboard: disable anonymous access and
      # public sign-up.
      "auth.anonymous".enabled = false;
      users.allow_sign_up = false;

      analytics.reporting_enabled = false;

      # Single sign-on through Kanidm (client "grafana", scope map homelab_user).
      # The local admin login stays enabled as a break-glass fallback.
      "auth.generic_oauth" = {
        enabled = true;
        name = "Kanidm";
        client_id = "grafana";
        client_secret = "$__file{${config.age.secrets.grafana_oidc_secret.path}}";
        scopes = "openid profile email groups";
        auth_url = "https://idm.estrogenuinely.ca/ui/oauth2";
        token_url = "https://idm.estrogenuinely.ca/oauth2/token";
        api_url = "https://idm.estrogenuinely.ca/oauth2/openid/grafana/userinfo";
        # Kanidm requires PKCE.
        use_pkce = true;
        login_attribute_path = "preferred_username";
        email_attribute_name = "email";
        name_attribute_path = "name";
        # Create the Grafana user on first SSO login.
        allow_sign_up = true;
        # homelab_admin -> Grafana Admin, any other homelab_user -> Viewer.
        role_attribute_path = "contains(groups[*], 'homelab_admin@idm.estrogenuinely.ca') && 'Admin' || 'Viewer'";
        role_attribute_strict = true;
      };
    };

    # Provision the Prometheus datasource and the Node Exporter Full dashboard.
    provision = {
      enable = true;

      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          uid = "prometheus";
          access = "proxy";
          url = "http://127.0.0.1:9090";
          isDefault = true;
        }
      ];

      dashboards.settings.providers = [
        {
          name = "homelab";
          # Copy the dashboards into the Nix store so Grafana reads them from
          # an immutable, world-readable path (not the root-owned git repo).
          options.path = ./grafana-dashboards;
          options.foldersFromFilesStructure = false;
        }
      ];
    };
  };
}

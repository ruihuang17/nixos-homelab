{
  config,
  pkgs,
  lib,
  ...
}:
let
  # Build the query+reduce+threshold data pipeline for a Grafana-managed alert
  # rule. `expr` is a PromQL instant query whose result is non-empty exactly
  # when the alert should fire (e.g. `up == 0`). We reduce to the last value
  # and the threshold C fires when that value is >= 1 (i.e. the series exists).
  mkFiringData = expr: [
    {
      refId = "A";
      datasourceUid = "prometheus";
      relativeTimeRange = {
        from = 300;
        to = 0;
      };
      model = {
        refId = "A";
        expr = expr;
        instant = true;
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
      };
    }
    {
      refId = "B";
      datasourceUid = "__expr__";
      model = {
        refId = "B";
        type = "reduce";
        reducer = "last";
        expression = "A";
        datasource = {
          type = "__expr__";
          uid = "__expr__";
        };
      };
    }
    {
      refId = "C";
      datasourceUid = "__expr__";
      model = {
        refId = "C";
        type = "threshold";
        expression = "B";
        datasource = {
          type = "__expr__";
          uid = "__expr__";
        };
        conditions = [
          {
            evaluator = {
              type = "gt";
              params = [ 0 ];
            };
          }
        ];
      };
    }
  ];

  # Helper to assemble a single alert rule.
  mkRule =
    {
      uid,
      title,
      expr,
      forDur ? "5m",
      summary,
      labels ? { },
    }:
    {
      inherit uid title labels;
      condition = "C";
      data = mkFiringData expr;
      noDataState = "OK";
      execErrState = "Alerting";
      "for" = forDur;
      annotations.summary = summary;
    };
in
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

  # SMTP password for the homelab-svc mail account, used by Grafana's email
  # contact point to send alerts via Stalwart (mail.estrogenuinely.ca:587).
  # Same secret as Nextcloud's mail_smtppassword (plain homelab-svc password).
  age.secrets.grafana_mail_pass = {
    file = "/etc/nixos/satsuma/secrets/mail_pass.age";
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

      # SMTP for alert emails, relayed through Stalwart as homelab-svc.
      # Password read at runtime from the agenix secret, not in the store.
      smtp = {
        enabled = true;
        host = "mail.estrogenuinely.ca:587";
        user = "homelab-svc";
        password = "$__file{${config.age.secrets.grafana_mail_pass.path}}";
        from_address = "alerts@estrogenuinely.ca";
        from_name = "Homelab Grafana";
        startTLS_policy = "MandatoryStartTLS";
      };

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

      # Unified alerting: contact points (email + Matrix via webhook receiver),
      # notification policy, and alert rules — all provisioned from the flake.
      alerting = {
        enable = true;

        contactPoints.settings = {
          apiVersion = 1;
          contactPoints = [
            {
              orgId = 1;
              name = "homelab";
              receivers = [
                {
                  uid = "homelab-email";
                  type = "email";
                  settings.addresses = "rui@estrogenuinely.ca";
                }
                {
                  uid = "homelab-matrix";
                  type = "webhook";
                  # matrix-alertmanager-receiver on satsuma -> homelab-alerts room.
                  settings = {
                    url = "http://127.0.0.1:9686/alerts/homelab";
                    httpMethod = "POST";
                  };
                }
              ];
            }
          ];
        };

        policies.settings = {
          apiVersion = 1;
          policies = [
            {
              orgId = 1;
              receiver = "homelab";
              group_by = [
                "alertname"
                "instance"
              ];
              group_wait = "30s";
              group_interval = "5m";
              repeat_interval = "4h";
            }
          ];
        };

        rules.settings = {
          apiVersion = 1;
          groups = [
            {
              orgId = 1;
              name = "homelab-core";
              folder = "Homelab";
              interval = "1m";
              rules = [
                (mkRule {
                  uid = "homelab-host-down";
                  title = "Host down (node_exporter unreachable)";
                  expr = "up{job=\"node\"} == 0";
                  forDur = "3m";
                  summary = "node_exporter target {{ $labels.instance }} is down (up == 0).";
                  labels.severity = "critical";
                })
                (mkRule {
                  uid = "homelab-service-down";
                  title = "Service down";
                  expr = "homelab:service_up == 0";
                  forDur = "5m";
                  summary = "Service {{ $labels.service }} on {{ $labels.host }} is DOWN.";
                  labels.severity = "critical";
                })
                (mkRule {
                  uid = "homelab-disk-full";
                  title = "Filesystem almost full";
                  expr = ''
                    (node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|overlay|squashfs|devtmpfs"}
                      / node_filesystem_size_bytes{fstype!~"tmpfs|ramfs|overlay|squashfs|devtmpfs"}) < 0.10'';
                  forDur = "15m";
                  summary = "{{ $labels.instance }} {{ $labels.mountpoint }} has <10% free space.";
                  labels.severity = "warning";
                })
              ];
            }
          ];
        };
      };
    };
  };
}

# Homelab overview: one service catalog that drives
#   1. blackbox probes (Prometheus scrape config),
#   2. the `homelab:service_up` recording rules (0/1 per service),
#   3. the generated "Homelab Overview" Grafana dashboard.
# To add a service, add one entry to `services` below and rebuild.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  blackboxAddr = "127.0.0.1:9115";
  nodeDashboardUid = "rYdddlPWk"; # "Node Exporter Full" (grafana-dashboards/)

  # Machines (node_exporter `instance` label) and the filesystem to report as
  # "disk used" for each.
  hosts = {
    satsuma.mount = "/";
    orange.mount = "/";
    mail.mount = "/";
    mac-mini.mount = "/System/Volumes/Data";
    homeassistant.mount = "/mnt/data";
  };

  # ---------------------------------------------------------------------------
  # Service catalog. `type` selects how the service is checked:
  #   http    GET `target`, any 2xx (after redirects) is up
  #   tcp     TCP connect to `target` (host:port)
  #   dns     `dnsServer` must answer a known query
  #   systemd node_exporter reports `unit` as active on `host`
  # `host` is the machine the service runs on (default satsuma).
  # ---------------------------------------------------------------------------
  services = map (s: { host = "satsuma"; } // s) [
    # Core
    {
      group = "Core";
      name = "nginx";
      type = "tcp";
      target = "127.0.0.1:443";
    }
    {
      group = "Core";
      name = "PostgreSQL";
      type = "tcp";
      target = "127.0.0.1:5432";
    }
    {
      group = "Core";
      name = "Kanidm";
      type = "http";
      target = "https://idm.estrogenuinely.ca/status";
    }
    {
      group = "Core";
      name = "Tailscale";
      type = "systemd";
      unit = "tailscaled.service";
    }
    {
      group = "Core";
      name = "NFS";
      type = "tcp";
      target = "127.0.0.1:2049";
    }
    {
      group = "Core";
      name = "Postfix";
      type = "tcp";
      target = "127.0.0.1:25";
    }

    # Files & documents
    {
      group = "Files & Documents";
      name = "Nextcloud";
      type = "http";
      target = "https://nextcloud.estrogenuinely.ca/status.php";
    }
    {
      group = "Files & Documents";
      name = "Collabora";
      type = "http";
      target = "https://collabora.estrogenuinely.ca/";
    }
    {
      group = "Files & Documents";
      name = "Paperless";
      type = "http";
      target = "http://127.0.0.1:28981/";
    }
    {
      group = "Files & Documents";
      name = "Immich";
      type = "http";
      target = "http://[::1]:2283/api/server/ping";
    }
    {
      group = "Files & Documents";
      name = "Immich ML";
      type = "systemd";
      unit = "immich-machine-learning.service";
    }
    {
      group = "Files & Documents";
      name = "Vaultwarden";
      type = "http";
      target = "http://127.0.0.1:8222/alive";
    }

    # Media
    {
      group = "Media";
      name = "Jellyfin";
      type = "http";
      target = "http://127.0.0.1:8096/health";
    }
    {
      group = "Media";
      name = "Sonarr";
      type = "http";
      target = "http://127.0.0.1:8989/ping";
    }
    {
      group = "Media";
      name = "Radarr";
      type = "http";
      target = "http://127.0.0.1:7878/ping";
    }
    {
      group = "Media";
      name = "Prowlarr";
      type = "http";
      target = "http://127.0.0.1:9696/ping";
    }
    {
      group = "Media";
      name = "FlareSolverr";
      type = "http";
      target = "http://127.0.0.1:8191/health";
    }
    # qBittorrent's web UI lives inside the VPN network namespace, so check the unit.
    {
      group = "Media";
      name = "qBittorrent";
      type = "systemd";
      unit = "qbittorrent.service";
    }
    {
      group = "Media";
      name = "PIA VPN";
      type = "systemd";
      unit = "pia-vpn.service";
    }
    {
      group = "Media";
      name = "PIA forward";
      type = "systemd";
      unit = "pia-port-forwarder.service";
    }

    # Messaging & mail
    {
      group = "Messaging & Mail";
      name = "Synapse";
      type = "http";
      target = "http://127.0.0.1:8008/health";
    }
    {
      group = "Messaging & Mail";
      name = "wsproxy";
      type = "systemd";
      unit = "mautrix-wsproxy.service";
    }
    {
      group = "Messaging & Mail";
      host = "mail";
      name = "Stalwart SMTP";
      type = "tcp";
      target = "100.91.236.114:25";
    }
    {
      group = "Messaging & Mail";
      host = "mail";
      name = "Stalwart IMAP";
      type = "tcp";
      target = "100.91.236.114:993";
    }

    # Network & home
    {
      group = "Network & Home";
      host = "orange";
      name = "DNS (Technitium)";
      type = "dns";
      target = "10.0.10.23:53";
    }
    {
      group = "Network & Home";
      host = "orange";
      name = "DNS web UI";
      type = "http";
      target = "http://10.0.10.23:5380/";
    }
    {
      group = "Network & Home";
      host = "homeassistant";
      name = "Home Assistant";
      type = "http";
      target = "http://10.0.10.74:8123/manifest.json";
    }

    # Monitoring
    {
      group = "Monitoring";
      name = "Prometheus";
      type = "http";
      target = "http://127.0.0.1:9090/-/healthy";
    }
    {
      group = "Monitoring";
      name = "Grafana";
      type = "http";
      target = "http://127.0.0.1:3000/api/health";
    }
  ];

  # TLS certificates, checked by handshaking with the given SNI name.
  certs = [
    {
      name = "*.estrogenuinely.ca";
      host = "satsuma";
      target = "127.0.0.1:443";
      sni = "estrogenuinely.ca";
    }
    {
      name = "*.ruihuang.io";
      host = "satsuma";
      target = "127.0.0.1:443";
      sni = "ruihuang.io";
    }
    {
      name = "mail (Stalwart)";
      host = "mail";
      target = "100.91.236.114:443";
      sni = "mail.estrogenuinely.ca";
    }
  ];

  groupNames = lib.unique (map (s: s.group) services);

  # ---------------------------------------------------------------------------
  # Blackbox exporter
  # ---------------------------------------------------------------------------
  blackboxConfig = pkgs.writeText "blackbox.yml" (
    builtins.toJSON {
      modules = {
        http = {
          prober = "http";
          timeout = "10s";
          http.follow_redirects = true;
        };
        tcp = {
          prober = "tcp";
          timeout = "5s";
        };
        # The DNS server must answer a real record (not just accept packets).
        dns = {
          prober = "dns";
          timeout = "5s";
          dns = {
            query_name = "jellyfin.local.estrogenuinely.ca";
            query_type = "A";
            transport_protocol = "udp";
            preferred_ip_protocol = "ip4";
            valid_rcodes = [ "NOERROR" ];
            validate_answer_rrs.fail_if_none_matches_regexp = [ ".*10\\.0\\.10\\.72" ];
          };
        };
      }
      // lib.listToAttrs (
        map (c: {
          name = "tls_${c.sni}";
          value = {
            prober = "tcp";
            timeout = "5s";
            tcp = {
              tls = true;
              tls_config.server_name = c.sni;
            };
          };
        }) certs
      );
    }
  );

  # One Prometheus target per probed service/certificate. The `module` label is
  # turned into the ?module= parameter by the relabel rules below.
  probedServices = lib.filter (s: s.type != "systemd") services;

  serviceTarget = s: {
    targets = [ s.target ];
    labels = {
      module = s.type;
      service = s.name;
      inherit (s) host group;
      check = s.type;
    };
  };

  certTarget = c: {
    targets = [ c.target ];
    labels = {
      module = "tls_${c.sni}";
      service = c.name;
      inherit (c) host;
      group = "Certificates";
      check = "cert";
    };
  };

  # ---------------------------------------------------------------------------
  # Recording rules: homelab:service_up{service,host,group,check} = 1 | 0
  # ---------------------------------------------------------------------------
  q = s: ''"${s}"'';

  probeRule = {
    record = "homelab:service_up";
    # `up == 0` covers the case where the probe itself could not be scraped.
    expr = ''max by (service, host, group, check) (probe_success{job="blackbox", check!="cert"} or (up{job="blackbox", check!="cert"} == 0))'';
  };

  systemdRule = s: {
    record = "homelab:service_up";
    # `or on() vector(0)` turns a missing series (host down, unit gone) into DOWN.
    expr = ''max(node_systemd_unit_state{instance=${q s.host}, name=${q s.unit}, state="active"}) or on() vector(0)'';
    labels = {
      service = s.name;
      inherit (s) host group;
      check = "systemd";
    };
  };

  rules = builtins.toJSON {
    groups = [
      {
        name = "homelab-services";
        interval = "30s";
        rules = [ probeRule ] ++ map systemdRule (lib.filter (s: s.type == "systemd") services);
      }
    ];
  };

  # ---------------------------------------------------------------------------
  # Dashboard
  # ---------------------------------------------------------------------------
  ds = {
    type = "prometheus";
    uid = "prometheus";
  };

  target =
    refId: expr: extra:
    {
      inherit refId expr;
      datasource = ds;
    }
    // extra;

  upDownMappings = [
    {
      type = "value";
      options = {
        "0" = {
          text = "DOWN";
          color = "red";
          index = 0;
        };
        "1" = {
          text = "UP";
          color = "green";
          index = 1;
        };
      };
    }
  ];

  thresholds = steps: {
    mode = "absolute";
    steps = lib.imap0 (i: s: {
      color = s.color;
      value = if i == 0 then null else s.value;
    }) steps;
  };

  nServices = toString (lib.length services);
  nHosts = toString (lib.length (lib.attrNames hosts));

  # Big number tile at the top.
  statPanel =
    {
      x,
      title,
      expr,
      unit ? "none",
      steps,
      decimals ? null,
      description ? "",
    }:
    {
      type = "stat";
      inherit title description;
      datasource = ds;
      gridPos = {
        inherit x;
        y = 0;
        w = 4;
        h = 4;
      };
      # Instant: these show the current state, so avoid range-step alignment.
      targets = [
        (target "A" expr {
          instant = true;
          range = false;
        })
      ];
      fieldConfig = {
        defaults = {
          inherit unit;
          thresholds = thresholds steps;
          color.mode = "thresholds";
          noValue = "n/a";
        }
        // lib.optionalAttrs (decimals != null) { inherit decimals; };
        overrides = [ ];
      };
      options = {
        colorMode = "background";
        graphMode = "none";
        textMode = "value";
        justifyMode = "center";
        reduceOptions = {
          calcs = [ "lastNotNull" ];
          fields = "";
          values = false;
        };
      };
    };

  topRow = [
    (statPanel {
      x = 0;
      title = "Machines up";
      expr = ''sum(up{job="node"})'';
      unit = "suffix:/${nHosts}";
      steps = [
        { color = "red"; }
        {
          color = "orange";
          value = 1;
        }
        {
          color = "green";
          value = lib.toInt nHosts;
        }
      ];
    })
    (statPanel {
      x = 4;
      title = "Services up";
      expr = "sum(homelab:service_up)";
      unit = "suffix:/${nServices}";
      steps = [
        { color = "red"; }
        {
          color = "orange";
          value = 1;
        }
        {
          color = "green";
          value = lib.toInt nServices;
        }
      ];
    })
    (statPanel {
      x = 8;
      title = "Services down";
      expr = "count(homelab:service_up == 0) or vector(0)";
      steps = [
        { color = "green"; }
        {
          color = "red";
          value = 1;
        }
      ];
    })
    (statPanel {
      x = 12;
      title = "Failed systemd units";
      expr = ''sum(node_systemd_unit_state{state="failed"}) or vector(0)'';
      description = "satsuma, mail and orange";
      steps = [
        { color = "green"; }
        {
          color = "red";
          value = 1;
        }
      ];
    })
    (statPanel {
      x = 16;
      title = "ZFS pools not online";
      expr = ''count(node_zfs_zpool_state{state!="online"} == 1) or vector(0)'';
      steps = [
        { color = "green"; }
        {
          color = "red";
          value = 1;
        }
      ];
    })
    (statPanel {
      x = 20;
      title = "Next cert expiry";
      expr = ''(min(probe_ssl_earliest_cert_expiry{check="cert"}) - time()) / 86400'';
      unit = "d";
      decimals = 0;
      steps = [
        { color = "red"; }
        {
          color = "orange";
          value = 7;
        }
        {
          color = "green";
          value = 14;
        }
      ];
    })
  ];

  rowPanel = y: title: {
    type = "row";
    inherit title;
    collapsed = false;
    gridPos = {
      x = 0;
      inherit y;
      w = 24;
      h = 1;
    };
    panels = [ ];
  };

  # Machines table: one row per node_exporter instance.
  diskExpr = lib.concatStringsSep " or " (
    lib.mapAttrsToList (
      h: v:
      "(1 - node_filesystem_avail_bytes{instance=${q h}, mountpoint=${q v.mount}} / node_filesystem_size_bytes{instance=${q h}, mountpoint=${q v.mount}})"
    ) hosts
  );

  tableTarget =
    refId: expr:
    target refId expr {
      instant = true;
      range = false;
      format = "table";
    };

  gauge = {
    "custom.cellOptions" = {
      type = "gauge";
      mode = "basic";
    };
  };

  percentColumn = name: {
    matcher = {
      id = "byName";
      options = name;
    };
    properties = [
      {
        id = "unit";
        value = "percentunit";
      }
      {
        id = "min";
        value = 0;
      }
      {
        id = "max";
        value = 1;
      }
      {
        id = "custom.cellOptions";
        value = gauge."custom.cellOptions";
      }
      {
        id = "thresholds";
        value = thresholds [
          { color = "green"; }
          {
            color = "orange";
            value = 0.75;
          }
          {
            color = "red";
            value = 0.9;
          }
        ];
      }
      {
        id = "color";
        value = {
          mode = "thresholds";
        };
      }
    ];
  };

  machinesPanel = {
    type = "table";
    title = "Machines";
    description = "Click a machine name to open its Node Exporter Full dashboard.";
    datasource = ds;
    gridPos = {
      x = 0;
      y = 5;
      w = 24;
      h = 8;
    };
    targets = [
      (tableTarget "A" ''max by (instance) (up{job="node"})'')
      (tableTarget "B" ''max by (instance) (time() - node_boot_time_seconds{job="node"})'')
      (tableTarget "C" ''1 - avg by (instance) (rate(node_cpu_seconds_total{job="node", mode="idle"}[5m]))'')
      (tableTarget "D" ''max by (instance) (1 - node_memory_MemAvailable_bytes{job="node"} / node_memory_MemTotal_bytes{job="node"}) or max by (instance) (1 - (node_memory_free_bytes{job="node"} + node_memory_inactive_bytes{job="node"} + node_memory_purgeable_bytes{job="node"}) / node_memory_total_bytes{job="node"})'')
      (tableTarget "E" "max by (instance) (${diskExpr})")
    ];
    transformations = [
      {
        id = "joinByField";
        options = {
          byField = "instance";
          mode = "outer";
        };
      }
      {
        id = "filterFieldsByName";
        options.include.pattern = "^(instance|Value #[A-E])$";
      }
      {
        id = "organize";
        options = {
          indexByName = {
            instance = 0;
            "Value #A" = 1;
            "Value #B" = 2;
            "Value #C" = 3;
            "Value #D" = 4;
            "Value #E" = 5;
          };
          renameByName = {
            instance = "Machine";
            "Value #A" = "Status";
            "Value #B" = "Uptime";
            "Value #C" = "CPU";
            "Value #D" = "Memory";
            "Value #E" = "Disk";
          };
        };
      }
      {
        id = "sortBy";
        options.sort = [ { field = "Machine"; } ];
      }
    ];
    fieldConfig = {
      defaults = {
        custom.align = "left";
        noValue = "-";
      };
      overrides = [
        {
          matcher = {
            id = "byName";
            options = "Machine";
          };
          properties = [
            {
              id = "links";
              value = [
                {
                  title = "Node Exporter Full";
                  url = "/d/${nodeDashboardUid}/node-exporter-full?var-job=node&var-node=\${__value.raw}&\${__url_time_range}";
                }
              ];
            }
          ];
        }
        {
          matcher = {
            id = "byName";
            options = "Status";
          };
          properties = [
            {
              id = "mappings";
              value = upDownMappings;
            }
            {
              id = "custom.cellOptions";
              value = {
                type = "color-background";
              };
            }
            {
              id = "thresholds";
              value = thresholds [
                { color = "red"; }
                {
                  color = "green";
                  value = 1;
                }
              ];
            }
            {
              id = "color";
              value = {
                mode = "thresholds";
              };
            }
            {
              id = "custom.width";
              value = 90;
            }
          ];
        }
        {
          matcher = {
            id = "byName";
            options = "Uptime";
          };
          properties = [
            {
              id = "unit";
              value = "s";
            }
            {
              id = "custom.width";
              value = 140;
            }
          ];
        }
        (percentColumn "CPU")
        (percentColumn "Memory")
        (percentColumn "Disk")
      ];
    };
    options = {
      showHeader = true;
      cellHeight = "md";
    };
  };

  # One tile per service, one panel per group.
  tileCount = g: lib.length (lib.filter (s: s.group == g) services);
  perRow = 3;
  groupRows = (lib.length groupNames + perRow - 1) / perRow;
  groupsY = 14;
  tilesPerRow = 4; # tiles per row inside a group panel (see minVizWidth below)
  panelHeight = g: if tileCount g > tilesPerRow then 7 else 5;
  # Height of each row of group panels = tallest panel in that row.
  groupRowHeights = lib.genList (
    r: lib.foldl' lib.max 0 (map panelHeight (lib.sublist (r * perRow) perRow groupNames))
  ) groupRows;
  groupRowY = r: groupsY + lib.foldl' (a: b: a + b) 0 (lib.take r groupRowHeights);

  groupPanel = i: g: {
    type = "stat";
    title = g;
    datasource = ds;
    gridPos = {
      x = 8 * (lib.mod i perRow);
      y = groupRowY (i / perRow);
      w = 8;
      h = lib.elemAt groupRowHeights (i / perRow);
    };
    targets = [
      (target "A" "homelab:service_up{group=${q g}}" {
        legendFormat = "{{service}}";
        instant = true;
        range = false;
      })
    ];
    fieldConfig = {
      defaults = {
        mappings = upDownMappings;
        thresholds = thresholds [
          { color = "red"; }
          {
            color = "green";
            value = 1;
          }
        ];
        color.mode = "thresholds";
        noValue = "n/a";
      };
      overrides = [ ];
    };
    options = {
      colorMode = "background";
      graphMode = "none";
      textMode = "value_and_name";
      justifyMode = "center";
      orientation = "auto";
      # The service name is the headline; UP/DOWN is secondary.
      text = {
        titleSize = 15;
        valueSize = 12;
      };
      minVizWidth = 180;
      minVizHeight = 50;
      reduceOptions = {
        calcs = [ "lastNotNull" ];
        fields = "";
        values = false;
      };
    };
  };

  historyY = groupRowY groupRows;

  # TEMPORARY (remove after 2026-10-13): three services were renamed on
  # 2026-10-11 to shorten their tiles. This folds the old names' history into
  # the new names so each service keeps a single history row. It writes the
  # display name to a separate `svc` label so no label sets collide.
  renamed = {
    "Matrix Synapse" = "Synapse";
    "mautrix-wsproxy" = "wsproxy";
    "PIA port forward" = "PIA forward";
  };
  renameStep = e: old: ''label_replace(${e}, "svc", ${q renamed.${old}}, "service", ${q old})'';
  historyBase = ''label_replace(min_over_time(homelab:service_up[$__interval]), "svc", "$1", "service", "(.*)")'';
  historyExpr = "max by (svc) (${lib.foldl' renameStep historyBase (lib.attrNames renamed)})";

  historyPanel = {
    type = "status-history";
    title = "Service status history";
    datasource = ds;
    gridPos = {
      x = 0;
      y = historyY + 1;
      w = 24;
      h = 26;
    };
    # Bound the number of points; min_over_time keeps short outages visible
    # even when each bucket spans many minutes.
    maxDataPoints = 150;
    # Outer-join all series on time so services that start recording later
    # (newly added or renamed) are shown instead of being dropped.
    transformations = [
      {
        id = "joinByField";
        options = {
          byField = "Time";
          mode = "outer";
        };
      }
    ];
    targets = [
      (target "A" historyExpr {
        legendFormat = "{{svc}}";
      })
    ];
    fieldConfig = {
      defaults = {
        mappings = upDownMappings;
        thresholds = thresholds [
          { color = "red"; }
          {
            color = "green";
            value = 1;
          }
        ];
        color.mode = "thresholds";
        custom.fillOpacity = 80;
      };
      overrides = [ ];
    };
    options = {
      showValue = "never";
      rowHeight = 0.9;
      colWidth = 0.95;
      legend.showLegend = false;
      tooltip.mode = "single";
    };
  };

  detailsY = historyY + 1 + 26 + 1;

  bargauge =
    {
      x,
      title,
      expr,
      legend,
      unit,
      min ? 0,
      max ? null,
      steps,
      description ? "",
      mode ? "gradient",
    }:
    {
      type = "bargauge";
      inherit title description;
      datasource = ds;
      gridPos = {
        inherit x;
        y = detailsY + 1;
        w = 8;
        h = 9;
      };
      targets = [
        (target "A" expr {
          legendFormat = legend;
          instant = true;
        })
      ];
      fieldConfig = {
        defaults = {
          inherit unit min;
          thresholds = thresholds steps;
          color.mode = "thresholds";
          noValue = "none";
        }
        // lib.optionalAttrs (max != null) { inherit max; };
        overrides = [ ];
      };
      options = {
        orientation = "horizontal";
        displayMode = mode;
        showUnfilled = true;
        valueMode = "color";
        reduceOptions = {
          calcs = [ "lastNotNull" ];
          fields = "";
          values = false;
        };
      };
    };

  detailPanels = [
    (rowPanel detailsY "Details")
    (bargauge {
      x = 0;
      title = "Slowest checks";
      description = "Probe round-trip time, top 10.";
      expr = ''topk(10, max by (service) (probe_duration_seconds{job="blackbox", check!="cert"}))'';
      legend = "{{service}}";
      unit = "s";
      max = 0.5;
      steps = [
        { color = "green"; }
        {
          color = "orange";
          value = 0.2;
        }
        {
          color = "red";
          value = 0.4;
        }
      ];
    })
    (bargauge {
      x = 8;
      title = "TLS certificate lifetime left";
      description = "ACME renews well before expiry; red means renewal is failing.";
      expr = ''probe_ssl_earliest_cert_expiry{check="cert"} - time()'';
      legend = "{{service}}";
      unit = "s";
      max = 7776000;
      steps = [
        { color = "red"; }
        {
          color = "orange";
          value = 604800;
        }
        {
          color = "green";
          value = 1209600;
        }
      ];
    })
    {
      type = "table";
      title = "Failed systemd units";
      datasource = ds;
      gridPos = {
        x = 16;
        y = detailsY + 1;
        w = 8;
        h = 9;
      };
      targets = [ (tableTarget "A" ''node_systemd_unit_state{state="failed"} == 1'') ];
      transformations = [
        {
          id = "filterFieldsByName";
          options.include.names = [
            "instance"
            "name"
          ];
        }
        {
          id = "organize";
          options.renameByName = {
            instance = "Machine";
            name = "Unit";
          };
        }
      ];
      fieldConfig = {
        defaults.noValue = "No failed units";
        overrides = [ ];
      };
      options.showHeader = true;
    }
  ];

  dashboard = {
    uid = "homelab-overview";
    title = "Homelab Overview";
    tags = [ "homelab" ];
    timezone = "browser";
    schemaVersion = 41;
    editable = true;
    refresh = "30s";
    time = {
      from = "now-24h";
      to = "now";
    };
    links = [
      {
        title = "Node Exporter Full";
        type = "link";
        url = "/d/${nodeDashboardUid}/node-exporter-full";
        icon = "dashboard";
      }
    ];
    panels =
      topRow
      ++ [
        (rowPanel 4 "Machines")
        machinesPanel
        (rowPanel (groupsY - 1) "Services")
      ]
      ++ lib.imap0 groupPanel groupNames
      ++ [
        (rowPanel historyY "History")
        historyPanel
      ]
      ++ detailPanels;
  };

  # Give every panel a stable numeric id.
  withIds = d: d // { panels = lib.imap1 (i: p: p // { id = i; }) d.panels; };

  dashboardDir = pkgs.writeTextDir "homelab-overview.json" (builtins.toJSON (withIds dashboard));
in
{
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9115;
    configFile = blackboxConfig;
  };

  services.prometheus.scrapeConfigs = [
    {
      job_name = "blackbox";
      metrics_path = "/probe";
      scrape_interval = "30s";
      scrape_timeout = "15s";
      static_configs = map serviceTarget probedServices ++ map certTarget certs;
      relabel_configs = [
        {
          source_labels = [ "__address__" ];
          target_label = "__param_target";
        }
        {
          source_labels = [ "module" ];
          target_label = "__param_module";
        }
        {
          source_labels = [ "__param_target" ];
          target_label = "instance";
        }
        {
          target_label = "__address__";
          replacement = blackboxAddr;
        }
      ];
    }
  ];

  services.prometheus.rules = [ rules ];

  services.grafana.provision.dashboards.settings.providers = [
    {
      name = "homelab-generated";
      options.path = dashboardDir;
    }
  ];
}

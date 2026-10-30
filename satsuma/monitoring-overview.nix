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
    lime.mount = "/System/Volumes/Data";
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
      host = "lime";
      name = "Jellyfin";
      type = "http";
      target = "http://10.0.10.73:8096/health";
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
      # The probe above only proves Technitium is alive: it asks for a local,
      # unsigned name, so it stayed green during the 2026-10-30 DNSSEC/clock
      # outage while every external lookup returned SERVFAIL. This second probe
      # asks for a signed public name, which only succeeds if validation passed.
      group = "Network & Home";
      host = "orange";
      name = "DNS (external DNSSEC)";
      type = "dns";
      module = "dns_external";
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
        # A signed public name. If the resolver's clock is wrong (DNSSEC
        # signatures not yet valid) or validation is broken, Technitium returns
        # SERVFAIL and this probe fails. Deliberately no answer-regexp: the point
        # is that validation succeeded, not which CDN address was returned.
        dns_external = {
          prober = "dns";
          timeout = "5s";
          dns = {
            query_name = "cloudflare.com";
            query_type = "A";
            transport_protocol = "udp";
            preferred_ip_protocol = "ip4";
            valid_rcodes = [ "NOERROR" ];
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
      # `module` defaults to the service type; a service can override it when
      # it needs a different blackbox module (e.g. the external-DNSSEC probe).
      module = s.module or s.type;
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
  #
  # Design notes:
  #   - One palette everywhere. A host keeps the same colour in every chart, so
  #     a line is recognisable without reading the legend.
  #   - The top of the page answers "is anything broken?"; lower rows are for
  #     investigation (reliability, capacity, and the monitoring stack itself).
  #   - Status colour is reserved for status. Non-status series use the muted
  #     palette so red always means "look here".
  # ---------------------------------------------------------------------------
  ds = {
    type = "prometheus";
    uid = "prometheus";
  };

  palette = {
    ok = "#34D399";
    warn = "#FBBF24";
    crit = "#F87171";
    info = "#38BDF8";
    accent = "#FB923C";
    violet = "#A78BFA";
    teal = "#2DD4BF";
    pink = "#F472B6";
    muted = "#94A3B8";
  };

  # Stable host identity colours, reused by every time series.
  hostColors = {
    satsuma = palette.accent;
    mail = palette.info;
    orange = palette.violet;
    lime = palette.teal;
    homeassistant = palette.pink;
  };

  hostOverrides = lib.mapAttrsToList (
    h: c: {
      matcher = {
        id = "byRegexp";
        options = "^${h}$";
      };
      properties = [
        {
          id = "color";
          value = {
            mode = "fixed";
            fixedColor = c;
          };
        }
      ];
    }
  ) hostColors;

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
          color = palette.crit;
          index = 0;
        };
        "1" = {
          text = "UP";
          color = palette.ok;
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

  # Reusable threshold sets, so the same condition looks the same everywhere.
  greenRed = [
    { color = palette.ok; }
    {
      color = palette.crit;
      value = 1;
    }
  ];
  redGreen = [
    { color = palette.crit; }
    {
      color = palette.ok;
      value = 1;
    }
  ];
  capacity = [
    { color = palette.ok; }
    {
      color = palette.warn;
      value = 0.75;
    }
    {
      color = palette.crit;
      value = 0.9;
    }
  ];
  certDays = [
    { color = palette.crit; }
    {
      color = palette.warn;
      value = 7;
    }
    {
      color = palette.ok;
      value = 14;
    }
  ];
  uptimePct = [
    { color = palette.crit; }
    {
      color = palette.warn;
      value = 95;
    }
    {
      color = palette.ok;
      value = 99;
    }
  ];
  latency = [
    { color = palette.ok; }
    {
      color = palette.warn;
      value = 0.2;
    }
    {
      color = palette.crit;
      value = 0.4;
    }
  ];

  nServices = toString (lib.length services);
  nHosts = toString (lib.length (lib.attrNames hosts));

  statPanel =
    {
      x,
      y ? 0,
      w ? 4,
      h ? 4,
      title,
      expr,
      unit ? "none",
      steps,
      decimals ? null,
      description ? "",
      graphMode ? "none",
      colorMode ? "value",
      textMode ? "value",
      instant ? false,
      min ? null,
      max ? null,
    }:
    {
      type = "stat";
      inherit title description;
      datasource = ds;
      gridPos = { inherit x y w h; };
      targets = [
        (target "A" expr {
          inherit instant;
          range = !instant;
        })
      ];
      fieldConfig = {
        defaults =
          {
            inherit unit;
            thresholds = thresholds steps;
            color.mode = "thresholds";
            noValue = "n/a";
          }
          // lib.optionalAttrs (decimals != null) { inherit decimals; }
          // lib.optionalAttrs (min != null) { inherit min; }
          // lib.optionalAttrs (max != null) { inherit max; };
        overrides = [ ];
      };
      options = {
        inherit colorMode graphMode textMode;
        justifyMode = "center";
        orientation = "auto";
        reduceOptions = {
          calcs = [ "lastNotNull" ];
          fields = "";
          values = false;
        };
        text = {
          titleSize = 13;
          valueSize = 38;
        };
      };
    };

  tableTarget =
    refId: expr:
    target refId expr {
      instant = true;
      range = false;
      format = "table";
    };

  tsPanel =
    {
      x,
      y,
      w,
      h,
      title,
      description ? "",
      unit ? "none",
      targets,
      overrides ? [ ],
      legend ? {
        displayMode = "list";
        placement = "bottom";
        calcs = [ ];
      },
      min ? null,
      max ? null,
      decimals ? null,
      thresholdSteps ? null,
      stacking ? null,
    }:
    {
      type = "timeseries";
      inherit title description;
      datasource = ds;
      gridPos = { inherit x y w h; };
      inherit targets;
      fieldConfig = {
        defaults =
          {
            inherit unit;
            color = { mode = "palette-classic"; };
            custom =
              {
                lineWidth = 2;
                fillOpacity = 8;
                gradientMode = "opacity";
                showPoints = "never";
                spanNulls = true;
                axisPlacement = "auto";
                axisColorMode = "text";
                scaleDistribution = { type = "linear"; };
              }
              // lib.optionalAttrs (stacking != null) {
                stacking = { mode = stacking; };
              }
              // lib.optionalAttrs (thresholdSteps != null) {
                thresholdsStyle = {
                  mode = "dashed";
                  lineWidth = 1;
                };
              };
          }
          // lib.optionalAttrs (thresholdSteps != null) {
            thresholds = thresholds thresholdSteps;
          }
          // lib.optionalAttrs (decimals != null) { inherit decimals; }
          // lib.optionalAttrs (min != null) { inherit min; }
          // lib.optionalAttrs (max != null) { inherit max; };
        inherit overrides;
      };
      options = {
        inherit legend;
        tooltip = {
          mode = "multi";
          sort = "desc";
        };
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
        id = "decimals";
        value = 1;
      }
      {
        id = "custom.align";
        value = "right";
      }
      {
        id = "custom.cellOptions";
        value = {
          type = "color-text";
        };
      }
      {
        id = "thresholds";
        value = thresholds capacity;
      }
      {
        id = "color";
        value = {
          mode = "thresholds";
        };
      }
    ];
  };

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

  # A host's primary filesystem, used for the "disk used" column.
  diskExpr = lib.concatStringsSep " or " (
    lib.mapAttrsToList (
      h: v:
      "(1 - node_filesystem_avail_bytes{instance=${q h}, mountpoint=${q v.mount}} / node_filesystem_size_bytes{instance=${q h}, mountpoint=${q v.mount}})"
    ) hosts
  );

  # ---------------------------------------------------------------------------
  # Layout
  # ---------------------------------------------------------------------------
  kpiH = 4;
  fleetRowY = kpiH;
  fleetY = fleetRowY + 1;
  fleetH = 8;
  servicesRowY = fleetY + fleetH;
  groupsY = servicesRowY + 1;

  # One tile per service, one panel per group.
  tileCount = g: lib.length (lib.filter (s: s.group == g) services);
  perRow = 3;
  groupRows = (lib.length groupNames + perRow - 1) / perRow;
  tilesPerRow = 4; # tiles per row inside a group panel (see minVizWidth below)
  panelHeight = g: if tileCount g > tilesPerRow then 7 else 5;
  # Height of each row of group panels = tallest panel in that row.
  groupRowHeights = lib.genList (
    r: lib.foldl' lib.max 0 (map panelHeight (lib.sublist (r * perRow) perRow groupNames))
  ) groupRows;
  groupRowY = r: groupsY + lib.foldl' (a: b: a + b) 0 (lib.take r groupRowHeights);

  historyRowY = groupRowY groupRows;
  historyY = historyRowY + 1;
  historyH = 16;
  reliabilityRowY = historyY + historyH;
  reliabilityY = reliabilityRowY + 1;
  reliabilityH = 8;
  infraRowY = reliabilityY + reliabilityH;
  infraY1 = infraRowY + 1;
  infraY2 = infraY1 + 8;
  storageRowY = infraY2 + 8;
  storageY = storageRowY + 1;
  storageH = 8;
  monitorRowY = storageY + storageH;
  monitorY = monitorRowY + 1;
  monitorH = 8;

  # ---------------------------------------------------------------------------
  # Row 0: the only six numbers needed to know if today is a good day.
  # ---------------------------------------------------------------------------
  topRow = [
    (statPanel {
      x = 0;
      title = "Services up / ${nServices}";
      expr = "sum(homelab:service_up)";
      steps = [
        { color = palette.crit; }
        {
          color = palette.warn;
          value = 1;
        }
        {
          color = palette.ok;
          value = lib.toInt nServices;
        }
      ];
      description = "Blackbox and systemd checks that are currently passing.";
    })
    (statPanel {
      x = 4;
      title = "Services down";
      expr = "count(homelab:service_up == 0) or vector(0)";
      steps = greenRed;
      description = "Anything above zero is listed under Active alerts.";
    })
    (statPanel {
      x = 8;
      title = "Machines up / ${nHosts}";
      expr = ''sum(up{job="node"})'';
      steps = [
        { color = palette.crit; }
        {
          color = palette.warn;
          value = 1;
        }
        {
          color = palette.ok;
          value = lib.toInt nHosts;
        }
      ];
      description = "node_exporter targets: satsuma, mail, orange, lime, homeassistant.";
    })
    (statPanel {
      x = 12;
      title = "Failed units";
      expr = ''sum(node_systemd_unit_state{state="failed"}) or vector(0)'';
      steps = greenRed;
      description = "systemd units in the failed state across all exporters.";
    })
    (statPanel {
      x = 16;
      title = "ZFS problems";
      expr = ''count(node_zfs_zpool_state{state!="online"} == 1) or vector(0)'';
      steps = greenRed;
      description = "Pools that are degraded, faulted, or otherwise not online.";
    })
    (statPanel {
      x = 20;
      title = "Cert expiry";
      expr = ''(min(probe_ssl_earliest_cert_expiry{check="cert"}) - time()) / 86400'';
      unit = "d";
      decimals = 0;
      steps = certDays;
      description = "Days until the soonest TLS certificate expires. ACME renews at 30 days.";
    })
  ];

  # ---------------------------------------------------------------------------
  # Fleet: one row per machine, plus the alert list.
  # ---------------------------------------------------------------------------
  machinesPanel = {
    type = "table";
    title = "Machines";
    description = "Click a machine name to open its Node Exporter Full dashboard. Colour = threshold, not decoration.";
    datasource = ds;
    gridPos = {
      x = 0;
      y = fleetY;
      w = 16;
      h = fleetH;
    };
    targets = [
      (tableTarget "A" ''max by (instance) (up{job="node"})'')
      (tableTarget "B" ''max by (instance) (time() - node_boot_time_seconds{job="node"})'')
      (tableTarget "C" ''1 - avg by (instance) (rate(node_cpu_seconds_total{job="node", mode="idle"}[5m]))'')
      (tableTarget "D" ''max by (instance) (1 - node_memory_MemAvailable_bytes{job="node"} / node_memory_MemTotal_bytes{job="node"}) or max by (instance) (1 - (node_memory_free_bytes{job="node"} + node_memory_inactive_bytes{job="node"} + node_memory_purgeable_bytes{job="node"}) / node_memory_total_bytes{job="node"})'')
      (tableTarget "E" "max by (instance) (${diskExpr})")
      (tableTarget "F" ''max by (instance) (node_load1{job="node"})'')
      (tableTarget "G" ''max by (instance) (node_hwmon_temp_celsius{chip=~"0000:00:08.*|platform_coretemp.*"}) or max by (instance) (node_thermal_zone_temp)'')
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
        options.include.pattern = "^(instance|Value #[A-G])$";
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
            "Value #F" = 6;
            "Value #G" = 7;
          };
          renameByName = {
            instance = "Machine";
            "Value #A" = "Status";
            "Value #B" = "Uptime";
            "Value #C" = "CPU";
            "Value #D" = "Memory";
            "Value #E" = "Disk";
            "Value #F" = "Load";
            "Value #G" = "Temp";
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
              value = thresholds redGreen;
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
              value = 130;
            }
          ];
        }
        (percentColumn "CPU")
        (percentColumn "Memory")
        (percentColumn "Disk")
        {
          matcher = {
            id = "byName";
            options = "Load";
          };
          properties = [
            {
              id = "decimals";
              value = 2;
            }
            {
              id = "custom.align";
              value = "right";
            }
            {
              id = "custom.width";
              value = 80;
            }
          ];
        }
        {
          matcher = {
            id = "byName";
            options = "Temp";
          };
          properties = [
            {
              id = "unit";
              value = "celsius";
            }
            {
              id = "decimals";
              value = 0;
            }
            {
              id = "thresholds";
              value = thresholds [
                { color = palette.ok; }
                {
                  color = palette.warn;
                  value = 70;
                }
                {
                  color = palette.crit;
                  value = 80;
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
              id = "custom.align";
              value = "right";
            }
            {
              id = "custom.width";
              value = 80;
            }
          ];
        }
      ];
    };
    options = {
      showHeader = true;
      cellHeight = "sm";
    };
  };

  alertsPanel = {
    type = "alertlist";
    title = "Active alerts";
    description = "Firing and pending Grafana alerts. Empty means quiet.";
    gridPos = {
      x = 16;
      y = fleetY;
      w = 8;
      h = fleetH;
    };
    options = {
      showAlerts = "current";
      alertName = "";
      dashboardAlerts = false;
      alertInstanceLabelFilter = "";
      stateFilter = {
        firing = true;
        pending = true;
        noData = true;
        error = true;
        normal = false;
      };
      maxItems = 20;
      sortOrder = 1;
      viewMode = "list";
      groupBy = [ "alertname" ];
      showNoAlerts = true;
    };
  };

  # ---------------------------------------------------------------------------
  # Services: a tile per check, grouped by what the service is for.
  # ---------------------------------------------------------------------------
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
    # sort() puts DOWN (0) first, so failures surface without scanning.
    targets = [
      (target "A" "sort(homelab:service_up{group=${q g}})" {
        legendFormat = "{{service}}";
        instant = true;
        range = false;
      })
    ];
    fieldConfig = {
      defaults = {
        mappings = upDownMappings;
        thresholds = thresholds redGreen;
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
      text = {
        titleSize = 14;
        valueSize = 11;
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

  # ---------------------------------------------------------------------------
  # Service health over time
  # ---------------------------------------------------------------------------
  # Folds the three services renamed on 2026-10-11 so each keeps one history
  # row. Writes the display name to `svc` so label sets never collide.
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
    description = "Every check, one row. A red sliver is a real outage even at 24h zoom.";
    datasource = ds;
    gridPos = {
      x = 0;
      y = historyY;
      w = 24;
      h = historyH;
    };
    maxDataPoints = 60;
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
      (target "A" historyExpr { legendFormat = "{{svc}}"; })
    ];
    fieldConfig = {
      defaults = {
        mappings = upDownMappings;
        thresholds = thresholds redGreen;
        color.mode = "thresholds";
        custom.fillOpacity = 80;
      };
      overrides = [ ];
    };
    options = {
      showValue = "never";
      rowHeight = 0.92;
      colWidth = 1;
      legend.showLegend = false;
      tooltip.mode = "single";
    };
  };

  reliabilityPanel = {
    type = "table";
    title = "Service reliability (selected range)";
    description = "Average availability from the recording rule, plus the latest probe time. Sorted worst first.";
    datasource = ds;
    gridPos = {
      x = 0;
      y = reliabilityY;
      w = 14;
      h = reliabilityH;
    };
    targets = [
      (tableTarget "A" ''avg_over_time(homelab:service_up[$__range]) * 100'')
      (tableTarget "B" ''max by (service) (probe_duration_seconds{job="blackbox", check!="cert"}) * 1000'')
    ];
    transformations = [
      {
        id = "joinByField";
        options = {
          byField = "service";
          mode = "outer";
        };
      }
      {
        id = "filterFieldsByName";
        options.include.names = [
          "service"
          "host"
          "group"
          "Value #A"
          "Value #B"
        ];
      }
      {
        id = "organize";
        options = {
          indexByName = {
            service = 0;
            host = 1;
            group = 2;
            "Value #A" = 3;
            "Value #B" = 4;
          };
          renameByName = {
            service = "Service";
            host = "Host";
            group = "Group";
            "Value #A" = "Uptime";
            "Value #B" = "Response";
          };
        };
      }
      {
        id = "sortBy";
        options.sort = [ { field = "Uptime"; } ];
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
            options = "Service";
          };
          properties = [
            {
              id = "custom.width";
              value = 170;
            }
          ];
        }
        {
          matcher = {
            id = "byName";
            options = "Host";
          };
          properties = [
            {
              id = "custom.width";
              value = 100;
            }
          ];
        }
        {
          matcher = {
            id = "byName";
            options = "Group";
          };
          properties = [
            {
              id = "custom.width";
              value = 150;
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
              value = "percent";
            }
            {
              id = "min";
              value = 0;
            }
            {
              id = "max";
              value = 100;
            }
            {
              id = "decimals";
              value = 2;
            }
            {
              id = "thresholds";
              value = thresholds uptimePct;
            }
            {
              id = "custom.cellOptions";
              value = {
                type = "gauge";
                mode = "basic";
              };
            }
            {
              id = "color";
              value = {
                mode = "thresholds";
              };
            }
          ];
        }
        {
          matcher = {
            id = "byName";
            options = "Response";
          };
          properties = [
            {
              id = "unit";
              value = "ms";
            }
            {
              id = "decimals";
              value = 1;
            }
            {
              id = "custom.width";
              value = 110;
            }
          ];
        }
      ];
    };
    options = {
      showHeader = true;
      cellHeight = "sm";
    };
  };

  certPanel = {
    type = "table";
    title = "TLS certificates";
    description = "Days of validity left. Red under 7 days means ACME renewal is failing.";
    datasource = ds;
    gridPos = {
      x = 14;
      y = reliabilityY;
      w = 10;
      h = reliabilityH;
    };
    targets = [
      (tableTarget "A" ''(probe_ssl_earliest_cert_expiry{check="cert"} - time()) / 86400'')
    ];
    transformations = [
      {
        id = "filterFieldsByName";
        options.include.names = [
          "service"
          "host"
          "Value"
        ];
      }
      {
        id = "organize";
        options = {
          indexByName = {
            service = 0;
            host = 1;
            Value = 2;
          };
          renameByName = {
            service = "Certificate";
            host = "Host";
            Value = "Days left";
          };
        };
      }
      {
        id = "sortBy";
        options.sort = [ { field = "Days left"; } ];
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
            options = "Certificate";
          };
          properties = [
            {
              id = "custom.width";
              value = 190;
            }
          ];
        }
        {
          matcher = {
            id = "byName";
            options = "Host";
          };
          properties = [
            {
              id = "custom.width";
              value = 90;
            }
          ];
        }
        {
          matcher = {
            id = "byName";
            options = "Days left";
          };
          properties = [
            {
              id = "unit";
              value = "d";
            }
            {
              id = "decimals";
              value = 1;
            }
            {
              id = "min";
              value = 0;
            }
            {
              id = "max";
              value = 90;
            }
            {
              id = "thresholds";
              value = thresholds certDays;
            }
            {
              id = "custom.cellOptions";
              value = {
                type = "gauge";
                mode = "basic";
              };
            }
            {
              id = "color";
              value = {
                mode = "thresholds";
              };
            }
          ];
        }
      ];
    };
    options = {
      showHeader = true;
      cellHeight = "sm";
    };
  };

  # ---------------------------------------------------------------------------
  # Infrastructure: the same four questions for every host.
  # ---------------------------------------------------------------------------
  cpuPanel = tsPanel {
    x = 0;
    y = infraY1;
    w = 8;
    h = 8;
    title = "CPU";
    description = "Busy CPU, 5 minute average, as a percentage of all cores.";
    unit = "percent";
    min = 0;
    max = 100;
    decimals = 1;
    targets = [
      (target "A" ''100 - (avg by (instance) (rate(node_cpu_seconds_total{job="node", mode="idle"}[5m])) * 100)'' {
        legendFormat = "{{instance}}";
      })
    ];
    overrides = hostOverrides;
    legend = {
      displayMode = "table";
      placement = "bottom";
      calcs = [ "lastNotNull" ];
      sortBy = "Last *";
      sortDesc = true;
    };
  };

  memoryPanel = tsPanel {
    x = 8;
    y = infraY1;
    w = 8;
    h = 8;
    title = "Memory";
    description = "Used memory including cache pressure, percent of total.";
    unit = "percent";
    min = 0;
    max = 100;
    decimals = 1;
    targets = [
      (target "A" ''100 * (max by (instance) (1 - node_memory_MemAvailable_bytes{job="node"} / node_memory_MemTotal_bytes{job="node"}) or max by (instance) (1 - (node_memory_free_bytes{job="node"} + node_memory_inactive_bytes{job="node"} + node_memory_purgeable_bytes{job="node"}) / node_memory_total_bytes{job="node"}))'' {
        legendFormat = "{{instance}}";
      })
    ];
    overrides = hostOverrides;
    legend = {
      displayMode = "table";
      placement = "bottom";
      calcs = [ "lastNotNull" ];
      sortBy = "Last *";
      sortDesc = true;
    };
  };

  networkPanel = tsPanel {
    x = 16;
    y = infraY1;
    w = 8;
    h = 8;
    title = "Network";
    description = "Total traffic across all physical interfaces, all hosts.";
    unit = "Bps";
    targets = [
      (target "A" ''sum(rate(node_network_receive_bytes_total{job="node", device!~"lo|veth.*|docker.*|br-.*|tailscale.*|virbr.*"}[5m]))'' {
        legendFormat = "Download";
      })
      (target "B" ''sum(rate(node_network_transmit_bytes_total{job="node", device!~"lo|veth.*|docker.*|br-.*|tailscale.*|virbr.*"}[5m]))'' {
        legendFormat = "Upload";
      })
    ];
    overrides = [
      {
        matcher = {
          id = "byName";
          options = "Download";
        };
        properties = [
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = palette.info;
            };
          }
        ];
      }
      {
        matcher = {
          id = "byName";
          options = "Upload";
        };
        properties = [
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = palette.accent;
            };
          }
        ];
      }
    ];
    legend = {
      displayMode = "list";
      placement = "bottom";
      calcs = [ "lastNotNull" ];
    };
  };

  diskPanel = tsPanel {
    x = 0;
    y = infraY2;
    w = 8;
    h = 8;
    title = "Disk throughput";
    description = "satsuma only: bytes read and written per second, all disks.";
    unit = "Bps";
    targets = [
      (target "A" ''sum(rate(node_disk_read_bytes_total{instance="satsuma"}[5m]))'' {
        legendFormat = "Read";
      })
      (target "B" ''sum(rate(node_disk_written_bytes_total{instance="satsuma"}[5m]))'' {
        legendFormat = "Write";
      })
    ];
    overrides = [
      {
        matcher = {
          id = "byName";
          options = "Read";
        };
        properties = [
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = palette.teal;
            };
          }
        ];
      }
      {
        matcher = {
          id = "byName";
          options = "Write";
        };
        properties = [
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = palette.violet;
            };
          }
        ];
      }
    ];
    legend = {
      displayMode = "list";
      placement = "bottom";
      calcs = [ "lastNotNull" ];
    };
  };

  loadPanel = tsPanel {
    x = 8;
    y = infraY2;
    w = 8;
    h = 8;
    title = "Load average";
    description = "1 minute load. Compare against core count; lime is the usual hotspot.";
    unit = "none";
    decimals = 2;
    targets = [
      (target "A" ''node_load1{job="node"}'' {
        legendFormat = "{{instance}}";
      })
    ];
    overrides = hostOverrides;
    legend = {
      displayMode = "table";
      placement = "bottom";
      calcs = [ "lastNotNull" ];
      sortBy = "Last *";
      sortDesc = true;
    };
  };

  tempPanel = tsPanel {
    x = 16;
    y = infraY2;
    w = 8;
    h = 8;
    title = "Temperature";
    description = "satsuma CPU package, NVMe and board sensors, in Celsius.";
    unit = "celsius";
    min = 20;
    max = 95;
    decimals = 1;
    thresholdSteps = [
      { color = palette.ok; }
      {
        color = palette.warn;
        value = 70;
      }
      {
        color = palette.crit;
        value = 85;
      }
    ];
    targets = [
      (target "A" ''max(node_hwmon_temp_celsius{instance="satsuma", chip=~"0000:00:08.*"})'' {
        legendFormat = "CPU";
      })
      (target "B" ''max(node_hwmon_temp_celsius{instance="satsuma", chip=~"nvme.*"})'' {
        legendFormat = "NVMe";
      })
      (target "C" ''max(node_hwmon_temp_celsius{instance="satsuma", chip=~"i2c.*"})'' {
        legendFormat = "Board";
      })
    ];
    overrides = [
      {
        matcher = {
          id = "byName";
          options = "CPU";
        };
        properties = [
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = palette.accent;
            };
          }
        ];
      }
      {
        matcher = {
          id = "byName";
          options = "NVMe";
        };
        properties = [
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = palette.info;
            };
          }
        ];
      }
      {
        matcher = {
          id = "byName";
          options = "Board";
        };
        properties = [
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = palette.muted;
            };
          }
        ];
      }
    ];
    legend = {
      displayMode = "list";
      placement = "bottom";
      calcs = [ "lastNotNull" ];
    };
  };

  # ---------------------------------------------------------------------------
  # Storage
  # ---------------------------------------------------------------------------
  filesystemExpr = ''max by (instance, mountpoint) (1 - node_filesystem_avail_bytes{job="node", mountpoint=~"/|/hdd|/System/Volumes/Data|/mnt/data", fstype!~"tmpfs|ramfs|overlay|squashfs|devtmpfs"} / node_filesystem_size_bytes{job="node", mountpoint=~"/|/hdd|/System/Volumes/Data|/mnt/data", fstype!~"tmpfs|ramfs|overlay|squashfs|devtmpfs"})'';

  filesystemPanel = {
    type = "bargauge";
    title = "Filesystem usage";
    description = "Primary filesystem per machine, plus satsuma's media pool.";
    datasource = ds;
    gridPos = {
      x = 0;
      y = storageY;
      w = 12;
      h = storageH;
    };
    targets = [
      (target "A" filesystemExpr {
        legendFormat = "{{instance}} {{mountpoint}}";
        instant = true;
      })
    ];
    fieldConfig = {
      defaults = {
        unit = "percentunit";
        min = 0;
        max = 1;
        decimals = 1;
        thresholds = thresholds capacity;
        color.mode = "thresholds";
        noValue = "none";
      };
      overrides = [ ];
    };
    options = {
      orientation = "horizontal";
      displayMode = "gradient";
      showUnfilled = true;
      valueMode = "color";
      reduceOptions = {
        calcs = [ "lastNotNull" ];
        fields = "";
        values = false;
      };
    };
  };

  arcPanel = tsPanel {
    x = 12;
    y = storageY;
    w = 12;
    h = storageH;
    title = "ZFS ARC";
    description = "Cache hit rate and how much of the ARC limit is in use. A falling hit rate with rising disk I/O means cache pressure.";
    unit = "percent";
    min = 0;
    max = 100;
    decimals = 1;
    targets = [
      (target "A" ''rate(node_zfs_arc_hits[5m]) / (rate(node_zfs_arc_hits[5m]) + rate(node_zfs_arc_misses[5m])) * 100'' {
        legendFormat = "Hit rate";
      })
      (target "B" ''node_zfs_arc_size / node_zfs_arc_c_max * 100'' {
        legendFormat = "ARC used";
      })
    ];
    overrides = [
      {
        matcher = {
          id = "byName";
          options = "Hit rate";
        };
        properties = [
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = palette.ok;
            };
          }
        ];
      }
      {
        matcher = {
          id = "byName";
          options = "ARC used";
        };
        properties = [
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = palette.info;
            };
          }
        ];
      }
    ];
    legend = {
      displayMode = "list";
      placement = "bottom";
      calcs = [ "lastNotNull" ];
    };
  };

  # ---------------------------------------------------------------------------
  # Monitoring the monitor
  # ---------------------------------------------------------------------------
  targetsPanel = {
    type = "table";
    title = "Exporter scrape health";
    description = "Prometheus's own view of the node and Prometheus targets.";
    datasource = ds;
    gridPos = {
      x = 0;
      y = monitorY;
      w = 8;
      h = monitorH;
    };
    targets = [
      (tableTarget "A" ''up{job=~"node|prometheus"}'')
    ];
    transformations = [
      {
        id = "filterFieldsByName";
        options.include.names = [
          "job"
          "instance"
          "Value"
        ];
      }
      {
        id = "organize";
        options = {
          indexByName = {
            job = 0;
            instance = 1;
            Value = 2;
          };
          renameByName = {
            job = "Job";
            instance = "Target";
            Value = "Status";
          };
        };
      }
      {
        id = "sortBy";
        options.sort = [
          { field = "Status"; }
          { field = "Target"; }
        ];
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
              value = thresholds redGreen;
            }
            {
              id = "color";
              value = {
                mode = "thresholds";
              };
            }
            {
              id = "custom.width";
              value = 80;
            }
          ];
        }
      ];
    };
    options = {
      showHeader = true;
      cellHeight = "sm";
    };
  };

  slowestPanel = {
    type = "bargauge";
    title = "Slowest checks";
    description = "Probe round-trip time, top 8.";
    datasource = ds;
    gridPos = {
      x = 8;
      y = monitorY;
      w = 8;
      h = monitorH;
    };
    targets = [
      (target "A" ''topk(8, max by (service) (probe_duration_seconds{job="blackbox", check!="cert"}))'' {
        legendFormat = "{{service}}";
        instant = true;
      })
    ];
    fieldConfig = {
      defaults = {
        unit = "s";
        min = 0;
        max = 0.5;
        thresholds = thresholds latency;
        color.mode = "thresholds";
        noValue = "none";
      };
      overrides = [ ];
    };
    options = {
      orientation = "horizontal";
      displayMode = "gradient";
      showUnfilled = true;
      valueMode = "color";
      reduceOptions = {
        calcs = [ "lastNotNull" ];
        fields = "";
        values = false;
      };
    };
  };

  failedUnitsPanel = {
    type = "table";
    title = "Failed systemd units";
    datasource = ds;
    gridPos = {
      x = 16;
      y = monitorY;
      w = 8;
      h = monitorH;
    };
    targets = [
      (tableTarget "A" ''node_systemd_unit_state{state="failed"} == 1'')
    ];
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
    options = {
      showHeader = true;
      cellHeight = "sm";
    };
  };

  dashboard = {
    uid = "homelab-overview";
    title = "Homelab Overview";
    description = "satsuma and friends: service health, fleet capacity, and the monitoring stack that watches it all.";
    tags = [
      "homelab"
      "overview"
      "satsuma"
    ];
    timezone = "browser";
    schemaVersion = 41;
    editable = true;
    graphTooltip = 1;
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
      {
        title = "Alerts";
        type = "link";
        url = "/alerting/list";
        icon = "bell";
      }
      {
        title = "Prometheus";
        type = "link";
        url = "https://prometheus.local.estrogenuinely.ca";
        icon = "external link";
        targetBlank = true;
      }
    ];
    panels =
      topRow
      ++ [
        (rowPanel fleetRowY "Fleet")
        machinesPanel
        alertsPanel
        (rowPanel servicesRowY "Services")
      ]
      ++ lib.imap0 groupPanel groupNames
      ++ [
        (rowPanel historyRowY "Service health")
        historyPanel
        (rowPanel reliabilityRowY "Reliability & certificates")
        reliabilityPanel
        certPanel
        (rowPanel infraRowY "Infrastructure")
        cpuPanel
        memoryPanel
        networkPanel
        diskPanel
        loadPanel
        tempPanel
        (rowPanel storageRowY "Storage")
        filesystemPanel
        arcPanel
        (rowPanel monitorRowY "Monitoring")
        targetsPanel
        slowestPanel
        failedUnitsPanel
      ];
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

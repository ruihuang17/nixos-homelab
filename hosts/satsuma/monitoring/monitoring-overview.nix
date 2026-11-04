# Homelab service catalog that drives
#   1. blackbox probes (Prometheus scrape config),
#   2. the `homelab:service_up` recording rules (0/1 per service).
# To add a service, add one entry to `services` below and rebuild.
{
  config,
  homelab,
  pkgs,
  lib,
  ...
}:
let
  blackboxAddr = "127.0.0.1:9115";

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
      target = "${homelab.url "lime" 8096}/health";
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
      target = "${homelab.ip "mail"}:25";
    }
    {
      group = "Messaging & Mail";
      host = "mail";
      name = "Stalwart IMAP";
      type = "tcp";
      target = "${homelab.ip "mail"}:993";
    }

    # Network & home
    {
      group = "Network & Home";
      host = "orange";
      name = "DNS (Technitium)";
      type = "dns";
      target = "${homelab.ip "orange"}:53";
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
      target = "${homelab.url "orange" 5380}/";
    }
    {
      group = "Network & Home";
      host = "homeassistant";
      name = "Home Assistant";
      type = "http";
      target = "${homelab.url "homeassistant" 8123}/manifest.json";
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
      target = "${homelab.ip "mail"}:443";
      sni = "mail.estrogenuinely.ca";
    }
  ];

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
}

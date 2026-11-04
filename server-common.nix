{
  config,
  lib,
  pkgs,
  ...
}:
# Shared configuration for the NixOS *server* hosts (satsuma, mail).
# Currently this provisions the Prometheus node_exporter in a consistent way;
# more cross-server concerns can be added here over time.
let
  cfg = config.homelab.nodeExporter;
in
{
  options.homelab.nodeExporter = {
    enable = lib.mkEnableOption "the Prometheus node_exporter for this server" // {
      default = true;
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address node_exporter binds to. Defaults to loopback (for hosts where
        Prometheus scrapes over localhost). Set to a Tailscale/LAN address when
        the host must be scraped remotely.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9100;
      description = "Port node_exporter listens on.";
    };

    openFirewallTailscale = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        When true, open the node_exporter port on the tailscale0 interface only
        (never on the public/LAN interface). Used by hosts that Prometheus
        scrapes across the tailnet.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enable = true;
      port = cfg.port;
      listenAddress = cfg.listenAddress;
      enabledCollectors = [
        "systemd"
        "processes"
      ];
    };

    # Only ever expose the exporter on the tailnet, never on the public iface.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts =
      lib.mkIf cfg.openFirewallTailscale [ cfg.port ];
  };
}

{
  config,
  lib,
  pkgs,
  ...
}:
# Shared configuration for the NixOS *server* hosts (satsuma, bergamot).
#
# This is the file they import in addition to common-nixos.nix: second user,
# root's ssh access, passwordless sudo is already in common, tailscale as a
# subnet router, sshd reachable from the LAN, and the Prometheus node
# exporter. Nothing here belongs on a desktop.
let
  homelab = import ./homelab.nix;
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

  config = lib.mkMerge [
    {
      users.users.lena = {
        uid = homelab.users.lena.uid;
        isNormalUser = true;
        shell = pkgs.fish;
        extraGroups = [
          "wheel"
          "media"
        ];
        openssh.authorizedKeys.keys = homelab.users.lena.keys;
        packages = with pkgs; [
          helix
          ripgrep
        ];
      };

      users.users.root = {
        shell = pkgs.fish;
        openssh.authorizedKeys.keys = homelab.users.rhuang.keys ++ homelab.users.lena.keys;
      };

      # Only key auth: both server accounts are reachable, passwords are not.
      services.openssh.settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
      services.openssh.openFirewall = true;

      # Tailscale as a subnet router: other hosts reach the LAN through satsuma,
      # and the VPS reaches kanidm's LDAPS interface over the tailnet instead of
      # the public internet.
      services.tailscale = {
        enable = true;
        useRoutingFeatures = "server";
      };

      # Force tailscaled to use nftables (clean nftables-only systems).
      # Avoids the iptables-compat translation layer.
      systemd.services.tailscaled.serviceConfig.Environment = [
        "TS_DEBUG_FIREWALL_MODE=nftables"
      ];

      # Do not block boot waiting for the network to come online.
      systemd.network.wait-online.enable = false;
      boot.initrd.systemd.network.wait-online.enable = false;

      # Optimize subnet-router / exit-node UDP forwarding performance.
      services.networkd-dispatcher = {
        enable = true;
        rules."50-tailscale-optimizations" = {
          onState = [ "routable" ];
          # networkd-dispatcher exports IFACE; use it instead of hard-coding eth0
          # (satsuma's NIC is enp4s0, so the old rule silently failed there).
          script = ''
            ${pkgs.ethtool}/bin/ethtool -K "$IFACE" rx-udp-gro-forwarding on rx-gro-list off
          '';
        };
      };
    }

    (lib.mkIf cfg.enable {
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
      networking.firewall.interfaces."tailscale0".allowedTCPPorts = lib.mkIf cfg.openFirewallTailscale [
        cfg.port
      ];
    })
  ];
}

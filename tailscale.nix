{ config, pkgs, ... }:

{
  # 1. Enable the service
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
    package = pkgs.tailscale.overrideAttrs (oldAttrs: {
      vendorHash = "sha256-Sd2iLJ7eDfDYdIRuW4xuiKgzhQWJWGAnz97FJWrVRlE=";
    });
  };
  # Firewall config in networking.nix

  # 2. Force tailscaled to use nftables (Critical for clean nftables-only systems)
  # This avoids the "iptables-compat" translation layer issues.
  systemd.services.tailscaled.serviceConfig.Environment = [
    "TS_DEBUG_FIREWALL_MODE=nftables"
  ];

  # 3. Optimization: Prevent systemd from waiting for network online
  systemd.network.wait-online.enable = false;
  boot.initrd.systemd.network.wait-online.enable = false;

  # Optimize the performance of subnet routers and exit nodes
  # In environment.systemPackages, ensure you have pkgs.ethtool
  services.networkd-dispatcher = {
    enable = true;
    rules."50-tailscale-optimizations" = {
      onState = [ "routable" ];
      script = ''
        ${pkgs.ethtool}/bin/ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off
      '';
    };
  };

}

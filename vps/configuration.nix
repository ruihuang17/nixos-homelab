{ lib, ... }: {
  imports = [
    ./hardware-configuration.nix
    ./stalwart.nix
    ./backup-target.nix
  ];

  # Workaround for https://github.com/NixOS/nix/issues/8502
  services.logrotate.checkConfig = false;

  # SSH is reachable only over Tailscale on this public-facing VPS.
  # common.nix sets openFirewall = true, so override it here to stop
  # opening port 22 on the public interface, and allow it on tailscale0.
  services.openssh.openFirewall = lib.mkForce false;

  # Expose node_exporter only across the tailnet (Prometheus on satsuma
  # scrapes it over Tailscale). The port is never opened on the public
  # interface; binding 0.0.0.0 is safe because the firewall only permits
  # 9100 on tailscale0.
  homelab.nodeExporter = {
    listenAddress = "0.0.0.0";
    openFirewallTailscale = true;
  };

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking = {
    useDHCP = true;
    hostName = "mail";
    domain = "estrogenuinely.ca";

    # Allow SSH only on the Tailscale interface.
    firewall.interfaces."tailscale0".allowedTCPPorts = [ 22 ];

    # Static IPv6 (OVH). The gateway sits outside the advertised prefix, so
    # we add an explicit on-link /128 route to it before using it as the
    # default gateway (the standard OVH IPv6 arrangement).
    interfaces.ens3.ipv6 = {
      addresses = [
        {
          address = "2607:5300:205:200::d27c";
          prefixLength = 128;
        }
      ];
      routes = [
        {
          address = "2607:5300:205:200::1";
          prefixLength = 128;
        }
      ];
    };
    defaultGateway6 = {
      address = "2607:5300:205:200::1";
      interface = "ens3";
    };
  };
  system.stateVersion = "23.11";

}

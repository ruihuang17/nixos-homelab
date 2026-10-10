{ config, ... }:

{
  networking = {

    useNetworkd = true;
    nftables.enable = true;
    dhcpcd.enable = false;

    hostName = "satsuma";
    hostId = "af300f15";
    nameservers = [ "127.0.0.1" ];

    hosts = {
      "127.0.0.1" = [
        "nextcloud.ruihuang.io"
        "collabora.ruihuang.io"
        "idm.ruihuang.io"
      ];
      "::1" = [
        "nextcloud.ruihuang.io"
        "collabora.ruihuang.io"
        "idm.ruihuang.io"
      ];
    };

    firewall = {
      allowedTCPPorts = [
        25
        80
        443
        1313
        2049
      ];
      trustedInterfaces = [ config.services.tailscale.interfaceName ];
      allowedUDPPorts = [ config.services.tailscale.port ];
      checkReversePath = "loose";
    };
  };
}

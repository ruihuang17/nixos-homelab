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
        "nextcloud.estrogenuinely.ca"
        "collabora.estrogenuinely.ca"
        "idm.estrogenuinely.ca"
      ];
      "::1" = [
        "nextcloud.estrogenuinely.ca"
        "collabora.estrogenuinely.ca"
        "idm.estrogenuinely.ca"
      ];
    };

    firewall = {
      allowedTCPPorts = [
        25
        80
        111
        443
        1313
        2049
        20048
      ];
      trustedInterfaces = [ config.services.tailscale.interfaceName ];
      allowedUDPPorts = [ config.services.tailscale.port 111 20048 ];
      checkReversePath = "loose";
    };
  };
}

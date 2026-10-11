{ config, ... }:
{
  imports = [
    ./hardware-configuration.nix
  ];

  boot.tmp.cleanOnBoot = true;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  time.timeZone = "America/Toronto";

  networking = {
    useNetworkd = true;
    nftables.enable = true;
    dhcpcd.enable = false;
    useDHCP = true;

    hostName = "tangerine";

    firewall = {
      allowedTCPPorts = [ ];
      trustedInterfaces = [ config.services.tailscale.interfaceName ];
      allowedUDPPorts = [ config.services.tailscale.port ];
      checkReversePath = "loose";
    };
  };

  system.stateVersion = "26.05";
}

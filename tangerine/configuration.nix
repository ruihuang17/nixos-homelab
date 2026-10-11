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
  i18n.defaultLocale = "en_CA.UTF-8";

  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  networking = {
    hostName = "tangerine";
    networkmanager.enable = true;
    nftables.enable = true;

    firewall = {
      trustedInterfaces = [ config.services.tailscale.interfaceName ];
      allowedUDPPorts = [ config.services.tailscale.port ];
      checkReversePath = "loose";
    };
  };

  # GNOME desktop (GDM + GNOME Shell on Wayland).
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Keep the group from the original install; the rest of the user
  # definition (uid, shell, wheel, ssh keys) comes from common.nix.
  users.users.rhuang = {
    description = "Rui Huang";
    extraGroups = [ "networkmanager" ];
  };

  system.stateVersion = "26.05";
}

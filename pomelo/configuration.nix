{ ... }:
# pomelo: Rui's desktop (ASRock X870, Ryzen 7 7700X, RTX 4080), migrated from Fedora 44.
# It imports common-nixos.nix but not server.nix: the server file adds Lena, root's
# ssh keys and a subnet-router Tailscale, none of which belong on a desktop.
{
  imports = [
    ./hardware-configuration.nix
    ../common-nixos.nix
    ./modules/boot.nix
    ./modules/nvidia.nix
    ./modules/users.nix
    ./modules/networking.nix
    ./modules/nfs.nix
    ./modules/desktop.nix
    ./modules/peripherals.nix
    ./modules/system-services.nix
    ./modules/programs.nix
    ./modules/packages.nix
    ./modules/thunderbird.nix
  ];

  system.stateVersion = "26.05"; # the release this machine was first installed with

  networking.hostName = "pomelo";
  time.timeZone = "America/Toronto";
  time.hardwareClockInLocalTime = true; # shared clock with the Windows install
  i18n.defaultLocale = "en_CA.UTF-8";
  services.xserver.xkb = {
    layout = "ca";
    variant = "eng";
  };
  console.useXkbConfig = true;
}

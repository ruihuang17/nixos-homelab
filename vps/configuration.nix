{ ... }: {
  imports = [
    ./hardware-configuration.nix
    ./stalwart.nix
  ];

  # Workaround for https://github.com/NixOS/nix/issues/8502
  services.logrotate.checkConfig = false;

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking = {
    useDHCP = true;
    hostName = "mail";
    domain = "estrogenuinely.ca";
  };
  system.stateVersion = "23.11";

}

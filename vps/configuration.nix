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

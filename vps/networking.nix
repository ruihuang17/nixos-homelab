{ lib, ... }: {
  # This file was populated at runtime with the networking
  # details gathered from the active system.
  networking = {
    nameservers = [ "213.186.33.99"
 ];
    defaultGateway = "15.235.101.1";
    defaultGateway6 = {
      address = "";
      interface = "ens3";
    };
    dhcpcd.enable = false;
    usePredictableInterfaceNames = lib.mkForce true;
    interfaces = {
      ens3 = {
        ipv4.addresses = [
          { address="15.235.101.89"; prefixLength=32; }
        ];
        ipv6.addresses = [
          { address="2607:5300:205:200::d27c"; prefixLength=128; }
{ address="fe80::f816:3eff:feb3:8041"; prefixLength=64; }
        ];
        ipv4.routes = [ { address = "15.235.101.1"; prefixLength = 32; } ];
        ipv6.routes = [ { address = ""; prefixLength = 128; } ];
      };
      
    };
  };
  services.udev.extraRules = ''
    ATTR{address}=="fa:16:3e:b3:80:41", NAME="ens3"
    
  '';
}

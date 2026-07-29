{ config, pkgs, ... }:
{
  # Kanidm
  services.kanidm = {
    package = pkgs.kanidm_1_10;
    server = {
      enable = true;
      settings = {
	      log_level = "debug";
	      tls_chain = "/var/lib/acme/ruihuang.io/fullchain.pem";
        tls_key = "/var/lib/acme/ruihuang.io/key.pem";
        origin = "https://idm.ruihuang.io";
        domain = "idm.ruihuang.io";    
        bindaddress = "127.0.0.1:8443";
	      ldapbindaddress = "127.0.0.1:3636";
      };
    };
    client = {
      enable = true;
      settings = {
        uri = "https://idm.ruihuang.io";
        verify_ca = true;
        verify_hostnames = true;
      };
    };
  };

  users.users.kanidm.extraGroups = [ "nginx" ];
}


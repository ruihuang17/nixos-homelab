{ config, pkgs, ... }:
{
  # Kanidm
  services.kanidm = {
    package = pkgs.kanidm_1_11;
    server = {
      enable = true;
      settings = {
	      log_level = "debug";
	      tls_chain = "/var/lib/acme/estrogenuinely.ca/fullchain.pem";
        tls_key = "/var/lib/acme/estrogenuinely.ca/key.pem";
        origin = "https://idm.estrogenuinely.ca";
        domain = "idm.estrogenuinely.ca";    
        bindaddress = "127.0.0.1:8443";
	      ldapbindaddress = "127.0.0.1:3636";
      };
    };
    client = {
      enable = true;
      settings = {
        uri = "https://idm.estrogenuinely.ca";
        verify_ca = true;
        verify_hostnames = true;
      };
    };
  };

  users.users.kanidm.extraGroups = [ "nginx" ];
}


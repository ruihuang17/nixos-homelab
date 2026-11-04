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
        # LDAPS interface. Bound on all interfaces but firewalled so that
        # only the tailnet (tailscale0) can reach it - this lets the mail
        # VPS perform LDAP lookups/binds against kanidm over Tailscale.
        # Kanidm only ever speaks LDAPS here (StartTLS is unsupported) and
        # reuses the web TLS material configured above.
        ldapbindaddress = "0.0.0.0:3636";
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

  # Expose the kanidm LDAPS port (3636) only over the Tailscale interface.
  # The public internet cannot reach it.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 3636 ];
}

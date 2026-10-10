{ config, pkgs, ... }:

{
  # Secrets Management (agenix)
  age.secrets.postfix_sasl = {
    file = ./secrets/postfix_sasl.age;
    owner = "postfix";
    group = "postfix";
  };

  # Postfix Local Network Relay Configuration
  services.postfix = {
    enable = true;
    setSendmail = true;

    # This block literally writes the file to /etc/postfix/outbound_map
    mapFiles = {
      outbound_map = pkgs.writeText "postfix-outbound-map" ''
        /^(.*)@.*$/    alerts@ruihuang.io
      '';
    };

    settings.main = {
      compatibility_level = "3.9";
      myorigin = "localhost";
      inet_interfaces = "all";
      mydestination = [ "localhost" ];
      mynetworks = [
        "127.0.0.0/8"
        "[::1]/128"
        "10.0.10.0/24"
        "100.64.0.0/10"
      ];
      relayhost = [ "[smtp.protonmail.ch]:587" ];

      # SASL & TLS
      smtp_sasl_auth_enable = "yes";
      smtp_sasl_password_maps = "texthash:${config.age.secrets.postfix_sasl.path}";
      smtp_sasl_security_options = "noanonymous";
      smtp_tls_security_level = "encrypt";
      smtp_tls_CAfile = "/etc/ssl/certs/ca-bundle.crt";
      smtp_tls_session_cache_database = "btree:\${data_directory}/smtp_scache";

      # Postfix looks at the file created above
      smtp_generic_maps = "regexp:/etc/postfix/outbound_map";
    };
  };
}

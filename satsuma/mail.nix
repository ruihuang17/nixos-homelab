{ config, pkgs, ... }:

{
  # Secrets Management (agenix)
  # postfix_sasl.age holds the SASL password map for the Stalwart relay, in
  # Postfix texthash format:  [mail.estrogenuinely.ca]:587 homelab-svc:<password>
  # (homelab-svc is a kanidm person account whose `mail` holds the per-service
  # @estrogenuinely.ca sender addresses; see docs/Stalwart.md.)
  age.secrets.postfix_sasl = {
    file = ./secrets/postfix_sasl.age;
    owner = "postfix";
    group = "postfix";
  };

  # Postfix Local Network Relay Configuration
  #
  # All system/service mail from satsuma is relayed through our own Stalwart
  # mail server on the VPS (mail.estrogenuinely.ca), authenticating as the
  # single kanidm account `homelab-svc`. Stalwart then relays outbound via SES.
  #
  # We no longer rewrite the envelope sender to one fixed address: Stalwart
  # authorizes homelab-svc to send from several @estrogenuinely.ca addresses
  # (alerts@, nextcloud@, vaultwarden@), so each local service keeps its own
  # From. Mail that has no explicit sender (cron, systemd OnFailure, smartd's
  # default, etc.) uses myorigin below and goes out as alerts@estrogenuinely.ca.
  services.postfix = {
    enable = true;
    setSendmail = true;

    settings.main = {
      compatibility_level = "3.9";
      # Envelope sender domain for locally-generated mail without an explicit
      # From. Combined with the smartd sender and per-app From addresses, this
      # keeps everything on @estrogenuinely.ca.
      myorigin = "estrogenuinely.ca";
      myhostname = "satsuma.estrogenuinely.ca";
      inet_interfaces = "all";
      mydestination = [ "localhost" ];
      mynetworks = [
        "127.0.0.0/8"
        "[::1]/128"
        "10.0.10.0/24"
        "100.64.0.0/10"
      ];

      # Relay everything through our Stalwart submission port (STARTTLS+SASL).
      relayhost = [ "[mail.estrogenuinely.ca]:587" ];

      # SASL & TLS
      smtp_sasl_auth_enable = "yes";
      smtp_sasl_password_maps = "texthash:${config.age.secrets.postfix_sasl.path}";
      smtp_sasl_security_options = "noanonymous";
      smtp_tls_security_level = "encrypt";
      smtp_tls_CAfile = "/etc/ssl/certs/ca-bundle.crt";
      smtp_tls_session_cache_database = "btree:\${data_directory}/smtp_scache";
    };
  };
}

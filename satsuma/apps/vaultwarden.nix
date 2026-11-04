# Refer to https://github.com/dani-garcia/vaultwarden/blob/main/.env.template
{ config, pkgs, ... }:
{
  age.secrets.vaultwarden_token.file = "/etc/nixos/satsuma/secrets/vaultwarden_token.age";

  services.vaultwarden = {
    enable = true;
    # in order to avoid having  ADMIN_TOKEN in the nix store it can be also set with the help of an environment file
    # be aware that this file must be created by hand (or via secrets management like sops)
    dbBackend = "postgresql";
    configureNginx = true;
    domain = "vaultwarden.estrogenuinely.ca";

    environmentFile = config.age.secrets.vaultwarden_token.path;

    config = rec {
      SIGNUPS_ALLOWED = false;
      DATABASE_URL = "postgresql://vaultwarden@%2Fvar%2Frun%2Fpostgresql/vaultwarden";

      # Rocket
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8222;
      ROCKET_LOG = "critical";

      # Email — relayed through our Stalwart server, authenticating as the
      # shared homelab-svc kanidm account (login is the kanidm name, not an
      # email) and sending as vaultwarden@estrogenuinely.ca (one of
      # homelab-svc's authorized Stalwart senders). SMTP_PASSWORD comes from
      # the agenix environmentFile (vaultwarden_token.age).
      SMTP_HOST = "mail.estrogenuinely.ca";
      SMTP_PORT = 587;
      SMTP_SECURITY = "starttls";
      SMTP_USERNAME = "homelab-svc";
      SMTP_AUTH_MECHANISM = "Login";
      SMTP_FROM = "vaultwarden@estrogenuinely.ca";
      SMTP_FROM_NAME = "Vaultwarden";
    };
  };
}

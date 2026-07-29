# Refer to https://github.com/dani-garcia/vaultwarden/blob/main/.env.template
{ config, pkgs, ... }:
{
  age.secrets.vaultwarden_openid.file = ./secrets/vaultwarden_openid.age;

  services.vaultwarden = {
    enable = true;
    # in order to avoid having  ADMIN_TOKEN in the nix store it can be also set with the help of an environment file
    # be aware that this file must be created by hand (or via secrets management like sops)
    dbBackend = "postgresql";
    configureNginx = true;
    domain = "vaultwarden.ruihuang.io";
    environmentFile = config.age.secrets.vaultwarden_openid.path; 

    config = {
      SIGNUPS_ALLOWED = false;
      DATABASE_URL = "postgresql://vaultwarden@%2Fvar%2Frun%2Fpostgresql/vaultwarden";

      # Rocket
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8222;
      ROCKET_LOG = "critical";

      # Email
      SMTP_HOST = "127.0.0.1";
      SMTP_PORT = 25;
      SMTP_SECURITY = "off";
      SMTP_FROM = "alerts@ruihuang.io";
      SMTP_FROM_NAME = "Vaultwarden server";

      # --- SSO / OIDC (Kanidm) ---
      SSO_ENABLED = true;
      SSO_ONLY = false;
      SSO_AUTHORITY = "https://idm.ruihuang.io/oauth2/openid/vaultwarden";
      SSO_CLIENT_ID = "vaultwarden";
      SSO_PKCE = true;
      SSO_SCOPES = "profile email";
      SSO_CLIENT_CACHE_EXPIRATION = 600;

      # Only needed while first linking existing local accounts to SSO
      SSO_SIGNUPS_MATCH_EMAIL = true;
      SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION = false;
    };
  };
}

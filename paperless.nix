{ config, pkgs, ... }:
{
  age.secrets.paperless_admin_pass.file = "/etc/nixos/secrets/paperless_admin_pass.age";

  services.paperless = {
    enable = true;
    address = "127.0.0.1";
    port = 28981;
    passwordFile = config.age.secrets.paperless_admin_pass.path;
    dataDir = "/var/lib/paperless";
    domain = "paperless.local.ruihuang.io";
    settings = {
      PAPERLESS_DBENGINE = "postgresql";
      PAPERLESS_DBHOST = "/run/postgresql";
      PAPERLESS_DBNAME = "paperless";
      PAPERLESS_DBUSER = "paperless";
      # no PAPERLESS_DBPASS — unix socket + peer auth handles it
    };
  };
}

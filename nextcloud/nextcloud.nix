{ pkgs, config, ... }:

{
  age.secrets.mail_pass.file = "/etc/nixos/secrets/mail_pass.age";
  age.secrets.nextcloud_admin_pass.file = "/etc/nixos/secrets/nextcloud_admin_pass.age";

  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud35;
    https = true;
    hostName = "nextcloud.ruihuang.io";
    home = "/var/lib/nextcloud";
    config = {
      dbtype = "pgsql";
      dbname = "nextcloud";
      dbuser = "nextcloud";
      dbhost = "/run/postgresql";
      adminpassFile = config.age.secrets.nextcloud_admin_pass.path;
    };

    # config.php
    settings = {
      trusted_proxies = [
        "127.0.0.1"
        "10.0.30.20"
      ];
      maintenance_window_start = 9;
      default_phone_region = "CA";
      mail_smtpmode = "smtp";
      mail_smtphost = "smtp.protonmail.ch";
      mail_smtpport = 587;
      mail_smtpsecure = "";
      mail_smtpauth = true;
      mail_smtpname = "nextcloud@ruihuang.io";
      mail_from_address = "nextcloud";
      mail_domain = "ruihuang.io";
      allow_local_remote_servers = true;
      lost_password_link = "disabled";
    };
    secrets = {
      mail_smtppassword = config.age.secrets.mail_pass.path;
    };

    # php.ini
    phpOptions = {
      "opcache.interned_strings_buffer" = 16;
    };

    # Apps
    appstoreEnable = true;
    extraAppsEnable = true;
    extraApps = with config.services.nextcloud.package.packages.apps; {
      inherit
        richdocuments
        user_oidc
        ;
    };
  };
}

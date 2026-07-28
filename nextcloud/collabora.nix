{
  pkgs,
  config,
  lib,
  ...
}:

{
  services.collabora-online = {
    enable = true;
    port = 9980; # default

    settings = {
      # Rely on reverse proxy for SSL
      ssl = {
        enable = false;
        termination = true;
      };

      net = {
        listen = "loopback";
        post_allow.host = [ "::1" ];
      };

      # Restrict loading documents from WOPI Host nextcloud.example.com
      storage.wopi = {
        "@allow" = true;
        host = [ "nextcloud.ruihuang.io" ];
      };

      # Set FQDN of server
      server_name = "collabora.ruihuang.io";

    };
  };
}

{ config, pkgs, ... }:
let
  homelab = import ../../../homelab.nix;
in
{
  # Same GID as the `storage` group on pomelo and lime, so NFS access works.
  users.groups.media = {
    gid = homelab.storageGid;
  };

  services.sonarr = {
    enable = true;
    group = "media";
    settings = {
      postgres = {
        PostgresHost = "/run/postgresql";
        PostgresUser = "sonarr";
        PostgresMainDb = "sonarr-main";
        PostgresLogDb = "sonarr-log";
      };
    };
  };

  services.radarr = {
    enable = true;
    group = "media";
    settings = {
      postgres = {
        PostgresHost = "/run/postgresql";
        PostgresUser = "radarr";
        PostgresMainDb = "radarr-main";
        PostgresLogDb = "radarr-log";
      };
    };
  };

  services.prowlarr = {
    enable = true;
    settings = {
      postgres = {
        PostgresHost = "/run/postgresql";
        PostgresUser = "prowlarr";
        PostgresMainDb = "prowlarr-main";
        PostgresLogDb = "prowlarr-log";
      };
    };
  };

  services.flaresolverr.enable = true;

}

{ config, pkgs, ... }:
{
  users.groups.media = {
    gid = 3000;
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

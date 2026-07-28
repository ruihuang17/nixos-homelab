{ config, pkgs, ... }:
{
  services.postgresql = {
    enable = true;
    dataDir = "/var/lib/psql";

    ensureDatabases = [
      "nextcloud"
      "paperless"
      "immich"
      "sonarr-main"
      "sonarr-log"
      "radarr-main"
      "radarr-log"
      "prowlarr-main"
      "prowlarr-log"
    ];
    ensureUsers = [
      {
        name = "nextcloud";
        ensureDBOwnership = true;
      }
      {
        name = "paperless";
        ensureDBOwnership = true;
      }
      {
        name = "immich";
        ensureDBOwnership = true;
      }
      { name = "sonarr"; }
      { name = "radarr"; }
      { name = "prowlarr"; }
    ];

    identMap = ''
      # ArbitraryMapName systemUser DBUser
         superuser_map      root      postgres
         superuser_map      postgres  postgres
         # Let other names login as themselves
         superuser_map      /^(.*)$   \1
    '';

    authentication = pkgs.lib.mkOverride 10 ''
      #type database      DBuser    auth-method optional_ident_map
      local all           postgres  peer        map=superuser_map
      local postgres      all       peer        map=superuser_map
      local sonarr-main   sonarr    peer        map=superuser_map
      local sonarr-log    sonarr    peer        map=superuser_map
      local radarr-main   radarr    peer        map=superuser_map
      local radarr-log    radarr    peer        map=superuser_map
      local prowlarr-main prowlarr  peer        map=superuser_map
      local prowlarr-log  prowlarr  peer        map=superuser_map
      local sameuser      all       peer        map=superuser_map
    '';
  };
}

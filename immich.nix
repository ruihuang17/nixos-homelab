{ config, pkgs, ... }:
{
  services.immich = {
    enable = true;
    package = pkgs.unstable.immich;
    environment.IMMICH_LOG_LEVEL = "warn";
    mediaLocation = "/var/lib/immich";
    database.createDB = false; # Declared in postgres.nix
  };
}

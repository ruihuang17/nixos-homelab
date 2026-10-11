# Local ZFS snapshot + replication backup of /var (zpool/var) onto the hdd pool.
#
#   sanoid  -> takes & prunes periodic snapshots of zpool/var
#   syncoid -> replicates those snapshots (incrementally) to hdd/backup/var
#
# Destination dataset hdd/backup/var is created out-of-band (not mounted:
# canmount=off, mountpoint=none) so the received copy never shadows live /var.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  # --- Periodic snapshots (source side) -------------------------------------
  services.sanoid = {
    enable = true;

    datasets = {
      "zpool/var" = {
        useTemplate = [ "var" ];
        recursive = true;
      };

      # Destination: keep the replicated snapshots per the same retention,
      # but never take new snapshots there (syncoid pushes them in).
      "hdd/backup/var" = {
        useTemplate = [ "backup" ];
        recursive = true;
      };
    };

    templates = {
      var = {
        autosnap = true;
        autoprune = true;
        hourly = 36;
        daily = 14;
        weekly = 4;
        monthly = 3;
      };

      backup = {
        autosnap = false; # snapshots arrive via syncoid, don't create here
        autoprune = true; # but do prune old ones on the backup pool
        hourly = 36;
        daily = 14;
        weekly = 4;
        monthly = 3;
      };
    };
  };

  # --- Replication to the hdd pool (destination side) -----------------------
  services.syncoid = {
    enable = true;

    # Run once per day.
    interval = "daily";

    # Local root->root replication; no SSH needed.
    commands."var-to-hdd" = {
      source = "zpool/var";
      target = "hdd/backup/var";
      recursive = true;
      # Reuse sanoid's snapshots instead of syncoid taking its own.
      extraArgs = [ "--no-sync-snap" ];
    };
  };
}

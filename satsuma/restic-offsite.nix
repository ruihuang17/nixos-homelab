# Offsite restic backups to OVHcloud Object Storage (Toronto, ca-east-tor).
#
# Scope: all service data under /var except derived/re-downloadable paths and
# live database directories, plus /etc (host keys, network config, NixOS tree).
# /home is intentionally excluded.
#
# The repository is initialized automatically on the first run. Restic encrypts
# client-side; the bucket also has OVH SSE-OMK and versioning enabled.
#
# Check status:
#   systemctl list-timers 'restic-backups-ovh*'
#   journalctl -u restic-backups-ovh.service -n 50
#   restic-ovh snapshots
#
# Manual run:
#   systemctl start restic-backups-ovh.service
#
# Restore (on satsuma; the wrapper already has the repo and secrets set):
#   restic-ovh restore latest --target /tmp/restore
#   # or a single path:
#   restic-ovh restore latest --target /tmp/restore --include /var/lib/nextcloud
#
# If satsuma is gone, decrypt restic_offsite_password.age and restic_s3_env.age
# from the git repo with the rhuang age key, then use restic from any machine.
{
  config,
  ...
}:
let
  repository = "s3:https://s3.ca-east-tor.io.cloud.ovh.net/satsuma-backup";
in
{
  age.secrets.restic_offsite_password = {
    file = "/etc/nixos/satsuma/secrets/restic_offsite_password.age";
    mode = "400";
  };

  age.secrets.restic_s3_env = {
    file = "/etc/nixos/satsuma/secrets/restic_s3_env.age";
    mode = "400";
  };

  services.restic.backups.ovh = {
    initialize = true;
    repository = repository;
    passwordFile = config.age.secrets.restic_offsite_password.path;
    environmentFile = config.age.secrets.restic_s3_env.path;
    paths = [
      "/var"
      "/etc"
    ];
    exclude = [
      # Re-downloadable / regenerable.
      "/var/lib/jellyfin"
      "/var/lib/immich/thumbs"
      "/var/lib/immich/encoded-video"

      # Live databases. Consistent dumps are in /var/backup/postgresql and are
      # also shipped to the mail VPS by restic-backups-postgres-vps.
      "/var/lib/psql"
      "/var/lib/mysql"
      "/var/lib/redis-immich"

      # Transient / rebuildable.
      "/var/cache"
      "/var/tmp"
      "/var/log"
      "/var/lib/docker"
      "/var/lib/containers"
    ];

    extraBackupArgs = [
      # Keep the initial ~210 GB upload from saturating the WAN. Restic's
      # --limit-upload unit is KiB/s, so 8000 = ~8 MB/s.
      "--limit-upload"
      "8000"
      "--exclude-caches"
    ];

    timerConfig = {
      OnCalendar = "04:30";
      Persistent = true;
      RandomizedDelaySec = "10min";
    };

    pruneOpts = [
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 12"
    ];
  };

  # Quarterly integrity check. This downloads 5% of the pack data and fails if
  # any checked pack is corrupt; it does not replace an actual restore test.
  services.restic.backups.ovh-check = {
    repository = repository;
    passwordFile = config.age.secrets.restic_offsite_password.path;
    environmentFile = config.age.secrets.restic_s3_env.path;
    checkOpts = [ "--read-data-subset=1/20" ];
    timerConfig = {
      OnCalendar = "*-01,04,07,10-01 12:00:00";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
  };

  systemd.services.restic-backups-ovh = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  systemd.services.restic-backups-ovh-check = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };
}

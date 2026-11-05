# PostgreSQL backups for satsuma, shipped offsite to the bergamot VPS over the tailnet.
#
#   1. services.postgresqlBackup  -> nightly per-database pg_dump (zstd) to /var/backup/postgresql
#   2. services.restic.backups    -> encrypted, deduplicated snapshots of those dumps pushed via
#                                    SFTP to backup@bergamot-backup (Tailscale only; see bergamot/backup-target.nix)
#
# Restore: restic -r sftp:backup@bergamot-backup:/var/lib/satsuma-backup/postgres restore latest --target /tmp/r
#          then: zstd -dc <db>.sql.zstd | sudo -u postgres psql <db>
# Not covered: roles/globals (declared via ensureUsers); take `pg_dumpall --globals-only` if needed.
{ config, lib, ... }:
let
  homelab = import ../../homelab.nix;
  repo = "sftp:backup@bergamot-backup:/var/lib/satsuma-backup/postgres";
  vpsHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBGkF5aWM2D0nhzl0jYCzzb+ZQ3wKOWK+D4XzWv7Rl9L";
in
{
  age.secrets.restic_postgres_password.file = ../secrets/restic_postgres_password.age;

  services.postgresqlBackup = {
    enable = true;
    # matrix-synapse's DB is created outside ensureDatabases (see postgres.nix header comment).
    databases = config.services.postgresql.ensureDatabases ++ [ "matrix-synapse" ];
    compression = "zstd";
    startAt = "*-*-* 03:00:00";
  };

  # Pin the VPS host key (matches bergamot/secrets/secrets.nix) so SFTP is non-interactive and MITM-safe.
  programs.ssh.knownHosts.bergamot-backup = {
    publicKey = vpsHostKey;
    extraHostNames = [
      "bergamot-backup"
      (homelab.ip "bergamot")
    ];
  };

  # Authenticate to the VPS with satsuma's host key (authorized in
  # bergamot/backup-target.nix). This must be a *separate* Host entry: ssh uses
  # the first value it finds, so reusing `bergamot` here would give root's own
  # `ssh root@bergamot` the host key and `User backup`.
  programs.ssh.extraConfig = ''
    Host bergamot-backup
        HostName ${homelab.ip "bergamot"}
        User backup
        IdentityFile /etc/ssh/ssh_host_ed25519_key
        IdentitiesOnly yes
        BatchMode yes
        ControlMaster no
  '';

  services.restic.backups.postgres-vps = {
    initialize = true;
    repository = repo;
    passwordFile = config.age.secrets.restic_postgres_password.path;
    paths = [ config.services.postgresqlBackup.location ];
    timerConfig = {
      OnCalendar = "03:20";
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
    pruneOpts = [
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 12"
    ];
  };

  # Don't start pushing until tailscale is up.
  systemd.services.restic-backups-postgres-vps = {
    after = [
      "tailscaled.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
  };
}

{ ... }:
# ZFS tuning for the HDD pool. The exported datasets are separate
# fstab-generated mount units, and `zfs share -a` only exports datasets that are
# currently mounted, so zfs-share is ordered after them; otherwise a
# `nixos-rebuild switch` can regenerate an empty NFS export list.
{
  # Reduce ZFS write frequency to disk (fewer wake-ups).
  boot.extraModprobeConfig = ''
    options zfs zfs_txg_timeout=30
  '';

  systemd.services.zfs-share = {
    after = [
      "hdd-data.mount"
      "hdd-mediaSrv.mount"
      "hdd-backup.mount"
    ];
    wants = [
      "hdd-data.mount"
      "hdd-mediaSrv.mount"
      "hdd-backup.mount"
    ];
  };
}

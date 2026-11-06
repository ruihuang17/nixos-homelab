{
  pkgs,
  ...
}:
# HDD power management and the ZFS/NFS ordering that keeps exports alive
# across a `nixos-rebuild switch`.
{
  # Spin down HDDs only — target explicitly by wwn, skip NVMe entirely.
  # Longer idle timeout (30 min) reduces spin-up/down cycling.
  services.udev.extraRules = ''
    ACTION=="add", KERNEL=="sda", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sda"
    ACTION=="add", KERNEL=="sdb", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sdb"
    ACTION=="add", KERNEL=="sdc", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sdc"
    ACTION=="add", KERNEL=="sdd", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sdd"
  '';
  # Reduce ZFS write frequency to disk (fewer wake-ups)
  boot.extraModprobeConfig = ''
    options zfs zfs_txg_timeout=30
  '';

  # Working data on the NVMe mirror (fast). Exported to pomelo with the ZFS
  # `sharenfs` property; see docs/NFS.md. Same pool as /, so it is required at
  # boot and gets no `nofail`. The mountpoint is /ssd-data, whose escaped
  # systemd unit is ssd\x2ddata.mount.
  fileSystems."/ssd-data" = {
    device = "zpool/data";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  # The exported datasets are separate fstab-generated mount units. `zfs share
  # -a` only exports datasets that are currently mounted, so ordering zfs-share
  # after them prevents it from regenerating an empty NFS export list during
  # `nixos-rebuild switch` (which can restart all of these units at once).
  systemd.services.zfs-share = {
    after = [
      "hdd-data.mount"
      "hdd-mediaSrv.mount"
      "hdd-backup.mount"
      "ssd\\x2ddata.mount"
    ];
    wants = [
      "hdd-data.mount"
      "hdd-mediaSrv.mount"
      "hdd-backup.mount"
      "ssd\\x2ddata.mount"
    ];
  };
}

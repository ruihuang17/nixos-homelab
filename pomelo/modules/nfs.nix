{
  ...
}:
# satsuma's NFS exports, mounted from the desktop. Kept out of the generated
# hardware-configuration.nix so a re-scan does not lose them.
let
  homelab = import ../../homelab.nix;

  nfsOptions = [
    "noatime"
    "hard"
    "_netdev"
    "nofail"
    "x-systemd.automount"
    "x-systemd.idle-timeout=10min"
    "x-systemd.mount-timeout=30s"
  ];
in
{
  fileSystems."/home/rhuang/NAS/backup" = {
    device = "${homelab.ip "satsuma"}:/hdd/backup";
    fsType = "nfs4";
    options = nfsOptions;
  };

  fileSystems."/home/rhuang/NAS/data" = {
    device = "${homelab.ip "satsuma"}:/hdd/data";
    fsType = "nfs4";
    options = nfsOptions;
  };

  fileSystems."/home/rhuang/NAS/media" = {
    device = "${homelab.ip "satsuma"}:/hdd/mediaSrv";
    fsType = "nfs4";
    options = nfsOptions;
  };

  # SSD dataset on satsuma holding the career-ops checkout (zpool/data).
  fileSystems."/home/rhuang/NAS/ssd" = {
    device = "${homelab.ip "satsuma"}:/ssd-data";
    fsType = "nfs4";
    options = nfsOptions;
  };
}

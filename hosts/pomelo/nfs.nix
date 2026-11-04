{
  homelab,
  lib,
  ...
}:
# NFS mounts of satsuma's exported datasets. Kept out of
# hardware-configuration.nix so the generated file stays regenerable and the
# server address comes from inventory.nix.
let
  # `nofail` + automount so a boot without the LAN (or before Tailscale is up)
  # still reaches a graphical session.
  nfsOptions = [
    "noatime"
    "hard"
    "_netdev"
    "nofail"
    "x-systemd.automount"
    "x-systemd.idle-timeout=10min"
    "x-systemd.mount-timeout=30s"
  ];

  # Name -> exported dataset on satsuma.
  shares = {
    backup = "/hdd/backup";
    data = "/hdd/data";
    media = "/hdd/mediaSrv";
  };
in
{
  fileSystems = lib.mapAttrs' (
    name: path:
    lib.nameValuePair "/home/rhuang/NAS/${name}" {
      device = "${homelab.ip "satsuma"}:${path}";
      fsType = "nfs4";
      options = nfsOptions;
    }
  ) shares;
}

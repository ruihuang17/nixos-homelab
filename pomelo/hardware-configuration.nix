{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
# Matches the NixOS 26.05 install of 2026-11-03: nvme0n1 is a 1G ESP plus one btrfs
# (label "root") with top-level subvolumes `home` and `nix`; `/` is the top-level subvolume.
let
  btrfsUuid = "635bdc27-1d86-454c-82ad-e9c56643db48";
  btrfsOptions = [
    "compress=zstd:1"
    "discard=async"
  ];
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
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "ahci"
    "xhci_pci"
    "thunderbolt"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-amd" ];

  hardware.cpu.amd.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/${btrfsUuid}";
    fsType = "btrfs";
    options = btrfsOptions;
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-uuid/${btrfsUuid}";
    fsType = "btrfs";
    options = [ "subvol=home" ] ++ btrfsOptions;
  };

  fileSystems."/nix" = {
    device = "/dev/disk/by-uuid/${btrfsUuid}";
    fsType = "btrfs";
    options = [
      "subvol=nix"
      "noatime"
    ]
    ++ btrfsOptions;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/2096-0765";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  fileSystems."/home/rhuang/NAS/backup" = {
    device = "10.0.10.72:/hdd/backup";
    fsType = "nfs4";
    options = nfsOptions;
  };

  fileSystems."/home/rhuang/NAS/data" = {
    device = "10.0.10.72:/hdd/data";
    fsType = "nfs4";
    options = nfsOptions;
  };

  fileSystems."/home/rhuang/NAS/media" = {
    device = "10.0.10.72:/hdd/mediaSrv";
    fsType = "nfs4";
    options = nfsOptions;
  };

  zramSwap.enable = true;

  nixpkgs.hostPlatform = "x86_64-linux";
}

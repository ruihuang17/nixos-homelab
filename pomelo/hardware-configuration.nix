{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
# Hand-written from the Fedora install on 2026-11-02. Before the first boot, compare
# with `nixos-generate-config --show-hardware-config` run from the installer.
let
  btrfsUuid = "24c81200-61c6-4def-b8d0-89e9ae754c67";
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
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-amd" ];

  hardware.cpu.amd.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  # Same btrfs filesystem Fedora uses. `home` is the existing Fedora subvolume;
  # `nixos` and `nix` are new subvolumes created next to Fedora's `root`.
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/${btrfsUuid}";
    fsType = "btrfs";
    options = [ "subvol=nixos" ] ++ btrfsOptions;
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

  fileSystems."/home" = {
    device = "/dev/disk/by-uuid/${btrfsUuid}";
    fsType = "btrfs";
    options = [ "subvol=home" ] ++ btrfsOptions;
  };

  # The Fedora ESP, also holding EFI/Microsoft for the Windows disk. Fedora's
  # separate ext4 /boot (UUID 13a9e8e8-...) is left unmounted.
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/6ECE-C1F0";
    fsType = "vfat";
    options = [
      "umask=0077"
      "shortname=winnt"
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

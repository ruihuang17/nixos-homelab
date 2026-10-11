{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "ahci"
    "xhci_pci"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" "amd_pstate=active" "amdgpu" ];
  boot.extraModulePackages = [ ];
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.extraPools = [ "hdd" ];
  boot.zfs.forceImportRoot = false;

  services.smartd = {
    enable = true;
    autodetect = true;
    defaults.monitored = "-a -c interval=10800 -o on -s (S/../.././02|L/../../7/04) ";
    notifications.mail = {
      enable = true;
      recipient = "alerts@estrogenuinely.ca";
      sender = "alerts@estrogenuinely.ca";
    };
  };


  fileSystems."/" = {
    device = "zpool/root";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/nix" = {
    device = "zpool/nix";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/var" = {
    device = "zpool/var";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/home" = {
    device = "zpool/home";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/A3AB-7D38";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

  # Seagate 8TB Harddrives zpool

  fileSystems."/hdd" = {
    device = "hdd";
    fsType = "zfs";
    options = [ "zfsutil" "nofail" ];
  };

  fileSystems."/hdd/backup" = {
    device = "hdd/backup";
    fsType = "zfs";
    options = [ "zfsutil" "nofail" ];
  };

  fileSystems."/hdd/data" = {
    device = "hdd/data";
    fsType = "zfs";
    options = [ "zfsutil" "nofail" ];
  };

  fileSystems."/hdd/mediaSrv" = {
    device = "hdd/mediaSrv";
    fsType = "zfs";
    options = [ "zfsutil" "nofail" ];
  };

  systemd.tmpfiles.rules = [
    "z /hdd           0775 root media - -"
    "z /hdd/backup    0770 root media - -"
    "z /hdd/data      0770 root media - -"
    "z /hdd/mediaSrv  0770 root media - -"
  ];

  services.nfs.server.enable = true;

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}

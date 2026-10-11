# PLACEHOLDER hardware configuration for the `tangerine` host.
#
# Replace this file with the real one generated on the target machine:
#
#   nixos-generate-config --show-hardware-config > tangerine/hardware-configuration.nix
#
# The values below (filesystems, boot device, kernel modules) are generic
# defaults and almost certainly need to be adjusted for the actual hardware.
{
  config,
  lib,
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # TODO: replace with the real root (and ESP) filesystems for tangerine.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}

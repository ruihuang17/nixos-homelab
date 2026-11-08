{ ... }:
{
  boot.loader = {
    timeout = 5;
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };
    efi.canTouchEfiVariables = true;
  };

  # Same kernel parameters as Fedora; efifb/simpledrm are disabled because the
  # Radeon iGPU and the RTX 4080 both expose a framebuffer.
  boot.kernelParams = [
    "nvidia.NVreg_EnableGpuFirmware=0"
    "initcall_blacklist=simpledrm_platform_driver_init"
    "video=efifb:off"
  ];
  boot.blacklistedKernelModules = [
    "nouveau"
    "nova_core"
  ];
}

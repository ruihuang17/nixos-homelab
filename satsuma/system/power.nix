{
  lib,
  ...
}:
# Low-power tuning for an always-on server.
{
  powerManagement.cpuFreqGovernor = "powersave";
  powerManagement.powertop.enable = true;

  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC = "power";
      PCIE_ASPM_ON_AC = "powersupersave";
      RUNTIME_PM_ON_AC = "auto";
      # Leave SATA_LINKPWR alone if it fights ZFS I/O; test carefully
    };
  };
  services.power-profiles-daemon.enable = false;
}

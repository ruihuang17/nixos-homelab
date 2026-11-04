{ pkgs, ... }:
# The server idles at "powersave" and spins the HDDs down after 30 minutes of
# inactivity; tunables are AC-only because it never runs on battery.
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

  # Spin down HDDs only — target explicitly by device, skip NVMe entirely.
  # A longer idle timeout (30 min) reduces spin-up/down cycling.
  services.udev.extraRules = ''
    ACTION=="add", KERNEL=="sda", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sda"
    ACTION=="add", KERNEL=="sdb", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sdb"
    ACTION=="add", KERNEL=="sdc", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sdc"
    ACTION=="add", KERNEL=="sdd", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sdd"
  '';
}

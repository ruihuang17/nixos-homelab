{ ... }:
{
  services.chrony.enable = true;
  services.irqbalance.enable = true;
  services.smartd = {
    enable = true;
    autodetect = true;
  };

  # Fedora ran the throughput-performance profile. tuned replaces
  # power-profiles-daemon, which Plasma would otherwise enable.
  services.tuned = {
    enable = true;
    ppdSettings.main.default = "performance";
  };
}

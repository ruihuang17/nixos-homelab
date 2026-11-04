{
  config,
  homelab,
  ...
}:
# ZFS/SMART/media/database telemetry for the Grove dashboard.
{
  services.groveExporter = {
    enable = true;
    zfs.enable = true;
    smartctl.enable = true;
    sonarr.enable = true;
    radarr.enable = true;
    prowlarr.enable = true;
    qbittorrent.enable = true;
    unifi = {
      enable = true;
      url = "https://${homelab.gateway}";
      user = "grove";
      passwordFile = config.age.secrets.unifi-grove-password.path;
    };
  };

  # Password for the local UniFi account used by the unpoller exporter. The
  # exporter runs as the unpoller-exporter group, so keep the decrypted copy
  # readable by that group only.
  age.secrets.unifi-grove-password = {
    file = ../secrets/unifi-grove-password.age;
    owner = "root";
    group = "unpoller-exporter";
    mode = "0440";
  };
}

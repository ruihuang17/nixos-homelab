{ pkgs, config, ... }:

{
  services.jellyfin = {
    enable = true;
    group = "media";
    hardwareAcceleration = {
      enable = true;
      type = "vaapi";
      device = "/dev/dri/renderD128";
    };
    transcoding = {
      enableHardwareEncoding = true;
      hardwareDecodingCodecs = {
        av1 = true;
        h264 = true;
        hevc = true;
        hevc10bit = true;
        vp9 = true;
      };
      hardwareEncodingCodecs = {
        hevc = true;
      };
      maxConcurrentStreams = 1;
    };
  };
  environment.systemPackages = with pkgs; [ jellyfin-ffmpeg ];
  users.users.jellyfin.extraGroups = [
    "render"
    "video"
  ];
  hardware.graphics.enable = true;

  systemd.services.jellyfin.serviceConfig.Environment = [
    "XDG_CACHE_HOME=/var/lib/jellyfin/.cache"
  ];
  fonts.fontconfig.localConf = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <!-- Tell Fontconfig to scan your 28G font directory in place -->
      <dir>/var/lib/jellyfin/fonts</dir>
    </fontconfig>
  '';
}

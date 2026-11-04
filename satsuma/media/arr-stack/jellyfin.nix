{ pkgs, config, ... }:

{
  # Jellyfin runs on lime (10.0.10.73); keep satsuma data for rollback.
  services.jellyfin = {
    enable = false;
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
  # Keep the account/UID so /var/lib/jellyfin remains readable if re-enabled.
  users.users.jellyfin = {
    isSystemUser = true;
    group = "media";
    uid = 986;
    extraGroups = [ "render" "video" ];
  };
  hardware.graphics.enable = true;
  fonts.fontconfig.localConf = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <!-- Tell Fontconfig to scan your 28G font directory in place -->
      <dir>/var/lib/jellyfin/fonts</dir>
    </fontconfig>
  '';
}

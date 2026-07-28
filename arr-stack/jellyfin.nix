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
  users.users.jellyfin.extraGroups = [ "render" "video" ];
  hardware.graphics.enable = true;
}

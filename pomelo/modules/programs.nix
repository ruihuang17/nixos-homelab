{ ... }:
{
  programs.steam.enable = true;
  programs.appimage = {
    enable = true;
    binfmt = true; # CurseForge AppImage in ~/bin
  };
  programs.obs-studio = {
    enable = true;
    enableVirtualCamera = true;
  };
  programs.firefox.enable = true;
}

{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # Gaming
    prismlauncher
    mangohud

    # Creative
    prusa-slicer
    darktable
    alsa-scarlett-gui
    scarlett2 # CLI and 4th-gen firmware files
    guvcview

    # Browsers
    google-chrome

    # Terminal
    kitty

    # Communication
    thunderbird
    protonmail-bridge-gui
    element-desktop
    vesktop
    wechat
    nextcloud-client
    spotify
    cider-2
    vlc

    # Security
    bitwarden-desktop
    rbw
    pinentry-qt # rbw is configured with `pinentry = "pinentry"`
    yubioath-flutter

    # Development
    vscode
    sublime4
    opencode
    gh
    git
    btop
    fastfetch
    nmap
    tcpdump
    proxychains-ng
    ethtool
    claude-code
    appimage-run

    # Documents
    libreoffice-qt
    typst
    obsidian

  ];
}

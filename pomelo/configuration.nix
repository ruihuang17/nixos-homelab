{
  config,
  lib,
  pkgs,
  ...
}:
# pomelo: Rui's desktop (ASRock X870, Ryzen 7 7700X, RTX 4080), migrated from Fedora 44.
# It imports common-nixos.nix but not server.nix: the server file adds Lena, root's
# ssh keys and a subnet-router Tailscale, none of which belong on a desktop.
let
  homelab = import ../homelab.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ./nfs.nix
    ./thunderbird.nix
    ../common-nixos.nix
  ];

  system.stateVersion = "26.05"; # the release this machine was first installed with

  networking.hostName = "pomelo";
  time.timeZone = "America/Toronto";
  time.hardwareClockInLocalTime = true; # shared clock with the Windows install
  i18n.defaultLocale = "en_CA.UTF-8";
  services.xserver.xkb = {
    layout = "ca";
    variant = "eng";
  };
  console.useXkbConfig = true;

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

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    open = false;
    modesetting.enable = true;
    powerManagement.enable = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
  };

  users.groups.rhuang.gid = 1000;
  users.groups.storage.gid = homelab.storageGid; # GID that crosses NFS to satsuma's `media` group
  # uid, shell and ssh key come from common-nixos.nix.
  users.users.rhuang = {
    description = "Rui Huang";
    group = "rhuang";
    extraGroups = [
      "networkmanager"
      "storage"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  networking.networkmanager.enable = true;
  networking.interfaces.enp9s0.wakeOnLan.enable = true;

  # Docker is not installed, so the nftables switch has nothing to conflict with.
  networking.nftables.enable = true;
  services.firewalld.enable = true;
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # satsuma advertises 10.0.10.0/24 over Tailscale. Accepting it would send NFS
  # out of tailscale0 with a source address that satsuma's exports reject.
  services.tailscale = {
    enable = true;
    openFirewall = true;
    extraSetFlags = [ "--accept-routes=false" ];
  };

  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.displayManager.defaultSession = "plasma";

  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5 = {
      waylandFrontend = true;
      addons = with pkgs; [
        qt6Packages.fcitx5-chinese-addons
        fcitx5-gtk
        kdePackages.fcitx5-configtool
      ];
    };
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    nerd-fonts.jetbrains-mono
  ];

  services.printing.enable = true;
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
  hardware.printers = {
    ensureDefaultPrinter = "WF-2930_Series";
    ensurePrinters = [
      {
        name = "WF-2930_Series";
        description = "EPSON WF-2930 Series (driverless)";
        deviceUri = "ipps://EPSON0E42B8.local:631/ipp/print";
        model = "everywhere";
      }
    ];
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

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

  # YubiKey: smartcard daemon for Yubico Authenticator.
  services.pcscd.enable = true;

  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-qt;
  };

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

  environment.sessionVariables.NIXOS_OZONE_WL = "1";

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

    # Documents
    libreoffice-qt
    typst
    obsidian
  ];
}

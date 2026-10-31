# lime: Apple M4 Mac mini (aarch64-darwin) - iMessage bridge + Jellyfin.
#
# Two things are deliberately NOT managed by Nix:
#   * ~/mautrix-imessage/mautrix-imessage - its TCC Full Disk Access grant is
#     bound to the binary's cdhash; a /nix/store copy would lose it.
#   * /Applications/Jellyfin.app - Homebrew cask, likewise TCC-bound.
# See docs/lime (macOS).md before moving either.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./agents.nix
    ./homebrew.nix
  ];

  # nix-darwin's own state marker (unrelated to system.stateVersion on NixOS).
  system.stateVersion = 7;

  # Required by launchd.user.agents: nix-darwin writes the plists into this
  # user's ~/Library/LaunchAgents and loads them with `launchctl asuser`.
  system.primaryUser = "rhuang";

  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "rhuang"
    ];
  };
  nix.optimise.automatic = true;
  nix.optimise.interval = [
    {
      Hour = 5;
      Minute = 0;
    }
  ];

  networking.hostName = "lime";
  networking.computerName = "lime";
  time.timeZone = "America/Toronto";

  # This box has to come back unattended: it is only reachable through
  # auto-login (which works because FileVault is off) and nothing reboots it by
  # hand. See docs/lime (macOS).md.
  power.sleep.computer = "never";
  power.sleep.display = "never";
  power.sleep.harddisk = "never";
  power.restartAfterPowerFailure = true;

  programs.fish.enable = true;

  environment.systemPackages = with pkgs; [
    git
    vim
    tmux
    btop
    tree
    ripgrep
    fd
    jq
    wget
  ];

  # --- autofs: the media library ------------------------------------------
  # NFSv3 with an explicit mountport because this macOS client cannot
  # negotiate NFSv4 with satsuma; nolocks because the NLM ports are not opened
  # (Jellyfin otherwise opens a file and hangs on the first read).
  environment.etc."auto_nas".text = ''
    /Users/rhuang/NAS/mediaSrv  -fstype=nfs,nfsvers=3,proto=tcp,port=2049,mountport=20048,resvport,rw,nolocks,hard,timeo=14  10.0.10.72:/hdd/mediaSrv
  '';

  environment.etc."auto_master".text = ''
    #
    # Automounter master map - managed by nix-darwin (lime/configuration.nix).
    #
    +auto_master
    /home   auto_home   -nobrowse,hidefromfinder
    /Network/Servers  -fstab
    /-  -static
    /-  auto_nas  -nosuid,noatime
  '';

  system.activationScripts.postActivation.text = lib.mkAfter ''
    # automountd must be loaded or NFS access fails with ECONNRESET even though
    # a manual mount works (docs/NFS.md). Enabling it persists in launchd's
    # disabled.plist, so this is only a no-op after the first run.
    launchctl enable system/com.apple.automountd 2>/dev/null || true
    /usr/sbin/automount -vc >/dev/null 2>&1 || true
  '';
}

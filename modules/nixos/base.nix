{
  homelab,
  inputs,
  lib,
  pkgs,
  ...
}:
# Everything every NixOS host shares, desktop or server: the human user, the
# shell, the CLI tools and the Nix/SSH defaults. Server-only concerns (Lena,
# root SSH, the subnet router) live in server.nix.
{
  # Local packages (matrix-mcp, kiro-gateway, ...) are used as plain
  # `pkgs.<name>`; see overlays/default.nix.
  nixpkgs.overlays = [ (import ../../overlays) ];

  imports = [
    ../shared/dots.nix
    ../shared/inventory.nix
    ../shared/nix-settings.nix
    ../shared/ssh-hosts.nix
    ../shared/starship.nix
  ];

  dots.users = [ "rhuang" ];

  users.users.rhuang = {
    uid = homelab.userUid "rhuang";
    isNormalUser = true;
    description = "Rui Huang";
    shell = pkgs.fish;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = homelab.userKeys "rhuang";
  };

  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    kitty.terminfo # so SSH from kitty (TERM=xterm-kitty) works
    kiro-cli
    vim
    git
    nixfmt
    gh
    ethtool
    dig
    sourceHighlight
    btop
    smartmontools
    tree
    opencode
    inputs.agenix.packages.${stdenv.hostPlatform.system}.default
  ];

  services.openssh = {
    enable = true;
    settings = {
      # Hosts override these where they need something else; pomelo, for
      # instance, forbids root logins outright.
      PermitRootLogin = lib.mkDefault "prohibit-password";
      PasswordAuthentication = lib.mkDefault false;
      KbdInteractiveAuthentication = lib.mkDefault false;
    };
  };

  programs.git = {
    enable = true;
    config.user = {
      name = "Rui Huang";
      email = "rui@ruihuang.io";
    };
  };

  programs.fish.enable = true;
  programs.nix-ld.enable = true;

  # Key used by the autoUpgrade push hook and by manual pushes from this repo.
  programs.ssh.extraConfig = ''
    Host github.com
        HostName github.com
        User git
        IdentityFile ~/.ssh/general
  '';

  programs.tmux.enable = true;

  nix.optimise.automatic = true;
  nix.optimise.dates = [ "05:00" ];
}

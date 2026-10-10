{ inputs, config, lib, pkgs, ... }:

{
  nixpkgs.config.allowUnfree = true;

  users.users.rhuang = {
    uid = 1000;
    isNormalUser = true;
    shell = pkgs.fish;
    extraGroups = [
      "wheel"
      "media"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH"
    ];
  };

  users.users.lena = {
    uid = 1001;
    isNormalUser = true;
    shell = pkgs.fish;
    extraGroups = [
      "wheel"
      "media"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICw7CHZkiNoG7StuF3NBnCHRWvsujJdX4ZTDIhz6YonH"
    ];
  };

  users.users.root = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH"
    ];
    shell = pkgs.fish;
  };

  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    helix
    ripgrep
    kiro-cli
    vim
    git
    nixfmt
    ethtool
    sourceHighlight
    btop
    smartmontools
    tree
    inputs.agenix.packages.${stdenv.hostPlatform.system}.default
  ];

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  programs.fish.enable = true;
  programs.nix-ld.enable = true;
  programs.ssh.extraConfig = ''
    Host github.com
        HostName github.com
        User git
        IdentityFile ~/.ssh/general
  '';

  nix.optimise.automatic = true;
  nix.optimise.dates = [ "05:00" ]; # Optional; allows customizing optimisation schedule
 

}

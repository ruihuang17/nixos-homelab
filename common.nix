{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:

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

  users.users.root = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICw7CHZkiNoG7StuF3NBnCHRWvsujJdX4ZTDIhz6YonH"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    kiro-cli
    vim
    git
    nixfmt
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
    openFirewall = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  # Tailscale (shared across all hosts).
  # Secures inter-host traffic, e.g. the mail VPS reaching kanidm's LDAPS
  # interface on satsuma over the tailnet instead of the public internet.
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
  };

  # Force tailscaled to use nftables (clean nftables-only systems).
  # Avoids the iptables-compat translation layer.
  systemd.services.tailscaled.serviceConfig.Environment = [
    "TS_DEBUG_FIREWALL_MODE=nftables"
  ];

  # Do not block boot waiting for the network to come online.
  systemd.network.wait-online.enable = false;
  boot.initrd.systemd.network.wait-online.enable = false;

  # Optimize subnet-router / exit-node UDP forwarding performance.
  services.networkd-dispatcher = {
    enable = true;
    rules."50-tailscale-optimizations" = {
      onState = [ "routable" ];
      script = ''
        ${pkgs.ethtool}/bin/ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off
      '';
    };
  };

  programs.fish.enable = true;
  programs.nix-ld.enable = true;
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

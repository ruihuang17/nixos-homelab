{
  config,
  homelab,
  lib,
  pkgs,
  ...
}:
# Shared configuration for the NixOS *server* hosts (satsuma, mail): the second
# admin account, root SSH, the Tailscale subnet router and the Prometheus
# node_exporter. The desktop (pomelo) imports base.nix directly.
{
  imports = [
    ./base.nix
    ./node-exporter.nix
  ];

  dots.users = [
    "root"
    "lena"
  ];

  users.users.root = {
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICw7CHZkiNoG7StuF3NBnCHRWvsujJdX4ZTDIhz6YonH"
    ];
  };

  # media is the NFS group (GID 3000) that owns the exported datasets.
  users.users.rhuang.extraGroups = [ "media" ];

  users.users.lena = {
    uid = homelab.userUid "lena";
    isNormalUser = true;
    shell = pkgs.fish;
    extraGroups = [
      "wheel"
      "media"
    ];
    openssh.authorizedKeys.keys = homelab.userKeys "lena";
    packages = with pkgs; [
      helix
      ripgrep
    ];
  };

  # mail narrows this to the tailnet with mkForce.
  services.openssh.openFirewall = true;

  # Tailscale. Secures inter-host traffic, e.g. the mail VPS reaching kanidm's
  # LDAPS interface on satsuma over the tailnet instead of the public internet.
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
      # networkd-dispatcher exports IFACE; use it instead of hard-coding eth0
      # (satsuma's NIC is enp4s0, so the old rule silently failed there).
      script = ''
        ${pkgs.ethtool}/bin/ethtool -K "$IFACE" rx-udp-gro-forwarding on rx-gro-list off
      '';
    };
  };
}

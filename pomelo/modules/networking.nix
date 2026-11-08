{ ... }:
{
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
}

{ config, pkgs, ... }:

{
  # 1. Enable the official Technitium DNS service
  services.technitium-dns-server = {
    enable = true;
    
    # Automatically opens the default ports (53 TCP/UDP, 5380 TCP) in the firewall
    openFirewall = true; 
  };

  # 2. Disable systemd-resolved to prevent Port 53 conflicts
  services.resolved.enable = false;
}


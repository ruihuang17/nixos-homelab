# SFTP-only backup sink for satsuma's PostgreSQL restic repository.
# Reachable only via Tailscale (sshd is already firewalled to tailscale0 in configuration.nix).
# Data is encrypted client-side by restic; this host never sees the repository password.
{ pkgs, ... }:
{
  users.groups.backup = { };
  users.users.backup = {
    isSystemUser = true;
    group = "backup";
    home = "/var/lib/satsuma-backup";
    createHome = true;
    homeMode = "0700";
    shell = "${pkgs.shadow}/bin/nologin";
    openssh.authorizedKeys.keys = [
      # satsuma's SSH host key, only from satsuma's tailnet address, no forwarding/pty/etc.
      ''restrict,from="100.72.25.50" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMp74d/OCwnetejX24slNj+6kIiEmarYX8j8+Zuku8IF satsuma-backup''
    ];
  };

  # SFTP only, no shell.
  services.openssh.extraConfig = ''
    Match User backup
      ForceCommand internal-sftp
      AllowTcpForwarding no
      X11Forwarding no
      PermitTTY no
  '';
}

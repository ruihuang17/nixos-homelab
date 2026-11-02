{ lib, ... }:
# SSH aliases for every homelab machine, shared by the NixOS hosts (via
# common.nix) and lime (nix-darwin), so each host can reach all the others.
# See docs/IP Address.md and docs/Setup Overview.md. `mail` is reached over Tailscale.
let
  hosts = {
    orange.hostName = "10.0.10.23";
    pomelo.hostName = "10.0.10.40";
    satsuma = {
      hostName = "10.0.10.72";
      user = "root";
    };
    lime.hostName = "10.0.10.73";
    homeassistant = {
      hostName = "10.0.10.74";
      port = 22222;
      user = "root";
    };
    mail = {
      hostName = "100.91.236.114";
      user = "root";
    };
  };

  hostBlock =
    name: h:
    ''
      Host ${name}
          HostName ${h.hostName}
    ''
    + lib.optionalString (h ? port) "    Port ${toString h.port}\n"
    + lib.optionalString (h ? user) "    User ${h.user}\n";
in
{
  # mkAfter keeps host-specific blocks (e.g. the backup job's `Host mail` in
  # satsuma/backup/postgres-backup.nix) first, since ssh uses the first value found.
  programs.ssh.extraConfig = lib.mkAfter ''
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList hostBlock hosts)}
    # Connection sharing: reuse one connection per host for 1 hour after the last session.
    Host ${lib.concatStringsSep " " (lib.attrNames hosts)}
        ControlMaster auto
        ControlPath ~/.ssh/cm-%C
        ControlPersist 1h
  '';
}

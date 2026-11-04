{ lib, homelab, ... }:
# SSH aliases for every homelab machine, generated from inventory.nix so the
# address lives in exactly one place. Shared by the NixOS hosts (via base.nix)
# and lime. `mail` is reached over Tailscale; see docs/Setup Overview.md.
let
  hostBlock =
    name: h:
    ''
      Host ${name}
          HostName ${h.address}
    ''
    + lib.optionalString ((h.sshPort or 22) != 22) "    Port ${toString (h.sshPort or 22)}\n"
    + lib.optionalString (h.sshUser != null) "    User ${h.sshUser}\n";
in
{
  imports = [ ./inventory.nix ];

  # mkAfter keeps host-specific blocks (e.g. the backup job's `Host mail` in
  # satsuma/backup/postgres-backup.nix) first, since ssh uses the first value found.
  programs.ssh.extraConfig = lib.mkAfter ''
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: _: hostBlock name (homelab.host name)) homelab.hosts
    )}
    # Connection sharing: reuse one connection per host for 1 hour after the last session.
    Host ${lib.concatStringsSep " " (lib.attrNames homelab.hosts)}
        ControlMaster auto
        ControlPath ~/.ssh/cm-%C
        ControlPersist 1h
  '';
}

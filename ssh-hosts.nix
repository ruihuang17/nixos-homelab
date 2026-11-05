{ lib, ... }:
# SSH aliases for every homelab machine, generated from homelab.nix and shared
# by the NixOS hosts and lime, so each host can reach all the others.
# See docs/IP Address.md and docs/Setup Overview.md. `mail` is reached over
# Tailscale.
let
  homelab = import ./homelab.nix;
in
{
  # mkAfter keeps host-specific blocks (e.g. the backup job's `Host mail` in
  # satsuma/backup/postgres-backup.nix) first, since ssh uses the first value found.
  programs.ssh.extraConfig = lib.mkAfter homelab.sshConfig;
}

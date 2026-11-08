{ ... }:
let
  homelab = import ../../homelab.nix;
in
{
  users.groups.rhuang.gid = 1000;
  users.groups.storage.gid = homelab.storageGid; # GID that crosses NFS to satsuma's `media` group
  # uid, shell and ssh key come from common-nixos.nix.
  users.users.rhuang = {
    description = "Rui Huang";
    group = "rhuang";
    extraGroups = [
      "networkmanager"
      "storage"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
}

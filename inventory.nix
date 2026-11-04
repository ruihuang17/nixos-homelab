# Single source of truth for the homelab: addresses, SSH users, the human
# accounts and the IDs that have to match across hosts. Consumed through the
# `homelab` module argument (see lib/homelab.nix and modules/shared/inventory.nix)
# and validated by the typed `homelab.hosts` option.
{
  domain = "estrogenuinely.ca";

  lanCidr = "10.0.10.0/24";

  # UniFi controller; also the LAN default gateway.
  gateway = "10.0.10.1";

  # GID of the NFS group that owns satsuma's exported datasets. It has to be
  # the same on every client (macOS sends numeric IDs over NFSv3).
  storageGid = 3000;

  users = {
    rhuang = {
      uid = 1000;
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH"
      ];
    };
    lena = {
      uid = 1001;
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICw7CHZkiNoG7StuF3NBnCHRWvsujJdX4ZTDIhz6YonH"
      ];
    };
  };

  # `address` is the address other hosts should use: the LAN address unless the
  # host is only reachable over the tailnet (`tailnet = true`).
  hosts = {
    orange = {
      address = "10.0.10.23";
      description = "Technitium DNS";
    };
    pomelo = {
      address = "10.0.10.40";
      sshUser = "rhuang";
      description = "desktop";
    };
    satsuma = {
      address = "10.0.10.72";
      sshUser = "root";
      description = "main server";
    };
    lime = {
      address = "10.0.10.73";
      description = "iMessage bridge, digest, Jellyfin";
    };
    homeassistant = {
      address = "10.0.10.74";
      sshUser = "root";
      sshPort = 22222;
      description = "Home Assistant OS";
    };
    mail = {
      address = "100.91.236.114";
      sshUser = "root";
      tailnet = true;
      description = "mail VPS (OVH)";
    };
  };
}

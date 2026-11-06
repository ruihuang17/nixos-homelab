# Data shared by every host: addresses, ssh aliases, users and keys, the
# storage GID, the domain and the dotfiles map.
#
# This is a plain attrset, not a NixOS module. Import it as
# `let homelab = import ../homelab.nix; in` and read the values you need.
# Nothing here defines options, so a host only gets what it asks for.
let
  # LAN host table. `address` is what other hosts dial; `port` and `user` are
  # only present when they differ from the ssh default (22, current user).
  hosts = {
    homeassistant = {
      address = "10.0.10.74";
      port = 22222;
      user = "root";
    };
    lime.address = "10.0.10.73";
    bergamot = {
      # The OVH VPS. networking.hostName stays "mail" (reverse DNS requires it);
      # this is only the repo/flake name. Reached over Tailscale: the VPS only
      # accepts ssh on tailscale0.
      address = "100.91.236.114";
      user = "root";
    };
    orange.address = "10.0.10.23";
    pomelo = {
      address = "10.0.10.40";
      user = "rhuang";
    };
    satsuma = {
      address = "10.0.10.72";
      user = "root";
    };
  };

  hostNames = builtins.attrNames hosts; # sorted

  # "Host lime\n    HostName 10.0.10.73\n" etc. Trailing newline per block.
  sshHostBlock =
    name: h:
    "Host ${name}\n    HostName ${h.address}\n"
    + (if h ? port then "    Port ${toString h.port}\n" else "")
    + (if h ? user then "    User ${h.user}\n" else "");
in
{
  inherit hosts;
  # `homelab.ip "lime"` -> "10.0.10.73"
  ip = name: hosts.${name}.address;
  # `homelab.tag "lime"` -> "lime:<port>" for a scrape target
  endpoint = name: port: "${hosts.${name}.address}:${toString port}";

  lanCidr = "10.0.10.0/24";
  lanGateway = "10.0.10.1";
  domain = "estrogenuinely.ca";

  # Alias block for ~/.ssh/config, plus one shared control connection per host.
  sshConfig =
    builtins.concatStringsSep "\n" (map (n: sshHostBlock n hosts.${n}) hostNames)
    + "\n"
    + ''
      # Every homelab machine uses the same key; on satsuma root has its own
      # copy at /root/.ssh/general, on lime and pomelo rhuang has ~/.ssh/general.
      Host ${builtins.concatStringsSep " " hostNames}
          IdentityFile ~/.ssh/general
          ControlMaster auto
          ControlPath ~/.ssh/cm-%C
          ControlPersist 1h
    '';

  # uid + ssh key per person account. Hosts decide which of them to create:
  # satsuma and mail get both, pomelo only rhuang, lime manages rhuang itself.
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

  # GID that crosses NFS: satsuma exports media with group `media`, and the
  # clients must use the same number. See docs/NFS.md.
  storageGid = 3000;

  # Dotfiles linked into every user's home. Keys are paths relative to $HOME.
  dotfiles = {
    ".config/starship.toml" = ./dots/starship/starship.toml;
    ".config/kitty/kitty.conf" = ./dots/kitty/kitty.conf;
    ".config/kitty/catppuccin-mocha.conf" = ./dots/kitty/catppuccin-mocha.conf;
  };
}

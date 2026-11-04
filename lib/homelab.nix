{ lib }:
# Helpers over inventory.nix, exposed to every module as the `homelab`
# argument. Pure functions of the inventory, so they can be used in `let`
# bindings and string interpolation without pulling in `config`.
let
  inv = import ../inventory.nix;

  # Normalised entry: the optional fields are filled in so callers can use them
  # without `or` chains.
  host =
    name:
    let
      h = inv.hosts.${name} or (throw "inventory: unknown host `${name}'");
    in
    h
    // {
      sshUser = h.sshUser or null;
      sshPort = h.sshPort or 22;
      tailnet = h.tailnet or false;
      description = h.description or "";
    };

  ip = name: (host name).address;
in
{
  inherit (inv)
    domain
    lanCidr
    gateway
    storageGid
    users
    hosts
    ;
  inherit host ip;

  # sshd port, used by ssh-hosts.nix and by anything that builds an ssh target.
  sshPort = name: (host name).sshPort;

  sshUser = name: (host name).sshUser;

  # user@address, for ssh/scp/rsync invocations.
  sshTarget = name: "${(host name).sshUser}@${ip name}";

  # http://address:port, for probes and upstreams.
  url = name: port: "http://${ip name}:${toString port}";

  userUid = name: inv.users.${name}.uid;
  userKeys = name: inv.users.${name}.keys;
}

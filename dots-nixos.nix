{ config, lib, ... }:
# NixOS side of dots.nix: creates parent directories and links via tmpfiles.
let
  cfg = config.dots;

  # ".config/a/b.toml" -> [ ".config" ".config/a" ]
  parentDirs =
    rel:
    let
      parts = lib.splitString "/" rel;
    in
    map (n: lib.concatStringsSep "/" (lib.take n parts)) (lib.range 1 (lib.length parts - 1));

  allDirs = lib.unique (lib.concatMap parentDirs (lib.attrNames cfg.files));
in
{
  imports = [ ./dots.nix ];

  systemd.tmpfiles.rules = lib.concatMap (
    user:
    let
      u = config.users.users.${user};
    in
    (map (d: "d ${u.home}/${d} - ${user} ${u.group} -") allDirs)
    ++ (lib.mapAttrsToList (rel: src: "L+ ${u.home}/${rel} - - - - ${src}") cfg.files)
  ) cfg.users;
}

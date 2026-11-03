{ config, lib, ... }:
# nix-darwin side of dots.nix: links via the activation script, run as the user
# so the links and parent directories get the right owner.
let
  cfg = config.dots;
in
{
  imports = [ ./dots.nix ];

  system.activationScripts.postActivation.text = lib.mkAfter (
    lib.concatMapStrings (
      user:
      let
        home = config.users.users.${user}.home;
        as = "sudo -u ${lib.escapeShellArg user}";
      in
      lib.concatStrings (
        lib.mapAttrsToList (rel: src: ''
          ${as} mkdir -p ${lib.escapeShellArg (dirOf "${home}/${rel}")}
          ${as} ln -sfn ${src} ${lib.escapeShellArg "${home}/${rel}"}
        '') cfg.files
      )
    ) cfg.users
  );
}

{
  lib,
  pkgs,
  ...
}:
# nix-darwin counterpart of common-nixos.nix: the Nix settings and shell
# tooling lime shares with the other machines.
#
# NixOS-only options (systemd, users via activation, sshd) stay out, so this
# file is imported only by lime. It reads homelab.nix itself, so lime imports
# this one file.
let
  homelab = import ./homelab.nix;

  # Dotfiles are linked by the activation script, run as the user so the links
  # and their parent directories get the right owner.
  dotUsers = [ "rhuang" ];
in
{
  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = [ pkgs.starship ];

  programs.fish.interactiveShellInit = ''
    if test "$TERM" != "dumb"
      ${pkgs.starship}/bin/starship init fish | source
    end
  '';

  # The prompt uses Nerd Font glyphs. Only the Mac runs a terminal locally;
  # over SSH the font comes from the client, so the servers skip it.
  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];

  system.activationScripts.postActivation.text = lib.mkAfter (
    lib.concatMapStrings (
      user:
      let
        home = "/Users/${user}";
        as = "sudo -u ${lib.escapeShellArg user}";
      in
      lib.concatStrings (
        lib.mapAttrsToList (rel: src: ''
          ${as} mkdir -p ${lib.escapeShellArg (dirOf "${home}/${rel}")}
          ${as} ln -sfn ${src} ${lib.escapeShellArg "${home}/${rel}"}
        '') homelab.dotfiles
      )
    ) dotUsers
  );
}

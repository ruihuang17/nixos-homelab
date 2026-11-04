{ lib, pkgs, ... }:
# Starship prompt (Catppuccin Mocha) for fish, shared by the NixOS hosts (via
# base.nix) and lime (nix-darwin). The config is linked to
# ~/.config/starship.toml by dots.nix, which is where starship looks by default.
{
  environment.systemPackages = [ pkgs.starship ];

  dots.files.".config/starship.toml" = ./dots/starship/starship.toml;

  programs.fish.interactiveShellInit = ''
    if test "$TERM" != "dumb"
      ${pkgs.starship}/bin/starship init fish | source
    end
  '';

  # The prompt uses Nerd Font glyphs. Only the Mac runs a terminal locally;
  # over SSH the font comes from the client, so the servers skip it.
  fonts.packages = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.nerd-fonts.jetbrains-mono
  ];
}

{ lib, ... }:
# Nix defaults shared by NixOS and nix-darwin. Only options that exist on both
# platforms belong here (the module system rejects platform-specific options
# even under mkIf).
{
  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}

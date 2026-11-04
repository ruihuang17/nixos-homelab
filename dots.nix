{ lib, ... }:
# Home Manager replacement for plain dotfiles. Files live under ./dots and are
# symlinked into each listed user's home directory. Each tool's module adds its
# own entries to `dots.files`; a host picks the users with `dots.users`.
#
#   dots.files.".config/foo/foo.toml" = ./dots/foo/foo.toml;
#
# This file only declares the options. The linking is done by dots-nixos.nix
# (systemd-tmpfiles) or dots-darwin.nix (activation script); a host imports
# whichever matches its platform. They are separate files because the module
# system rejects `systemd.*` definitions on nix-darwin even under mkIf.
#
# Links point at the file's copy in the nix store, so edits take effect after a
# rebuild. An existing file at a target path is replaced by the link.
{
  options.dots = {
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users whose home directory receives the links in `dots.files`.";
    };

    files = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = "Link targets relative to the home directory, mapped to their source files.";
    };
  };
}

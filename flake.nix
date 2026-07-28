{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = inputs@{ self, nixpkgs, ... }: {
    nixosConfigurations.satsuma = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        {
          nixpkgs.config.allowUnfree = true;

          nix.settings.experimental-features = [
            "nix-command"
            "flakes"
          ];
        }
      ];
    };
  };
}

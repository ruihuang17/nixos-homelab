{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent.url = "github:NousResearch/hermes-agent";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      agenix,
      ...
    }:
    {
      nixosConfigurations.satsuma = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./satsuma/configuration.nix
          ./server-common.nix
          ./lena.nix
          ./common.nix
          agenix.nixosModules.default
          {
            nixpkgs.config.allowUnfree = true;
            nix.settings.experimental-features = [
              "nix-command"
              "flakes"
            ];
          }
        ];
      };

      nixosConfigurations.mail = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./vps/configuration.nix
          ./server-common.nix
          ./lena.nix
          ./common.nix
          agenix.nixosModules.default
          {
            nixpkgs.config.allowUnfree = true;
            nix.settings.experimental-features = [
              "nix-command"
              "flakes"
            ];
          }
        ];
      };

      nixosConfigurations.tangerine = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./tangerine/configuration.nix
          ./common.nix
          agenix.nixosModules.default
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

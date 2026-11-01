{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent.url = "github:NousResearch/hermes-agent";
    # macOS host (lime). `master` corresponds to nixpkgs-unstable; nix-darwin
    # refuses to evaluate against a mismatched release branch.
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      agenix,
      nix-darwin,
      ...
    }:
    let
      groveShell =
        pkgs:
        pkgs.mkShell {
          packages = with pkgs; [
            nodejs_24
            git
            openssh
            rsync
            curl
            netcat-openbsd
            chromium
          ];

          shellHook = ''
            export CHROMIUM_PATH="${pkgs.chromium}/bin/chromium"
            export PROM_URL="''${PROM_URL:-http://127.0.0.1:9090}"
            echo "Grove dev shell: Node $(node --version), npm $(npm --version)"
            echo "  npm install   install dependencies"
            echo "  npm run dev   start Vite against Prometheus (PROM_URL override)"
            echo "  npm run qa    run the Playwright checks"
          '';
        };

      # Tail module shared by every NixOS host (satsuma, mail).
      nixosBase = {
        nixpkgs.config.allowUnfree = true;
        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];
      };
    in
    {
      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" ] (system: {
        kiro-gateway = nixpkgs.legacyPackages.${system}.callPackage ./pkgs/kiro-gateway { };
      });

      devShells = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (system: {
        default = groveShell nixpkgs.legacyPackages.${system};
        grove = groveShell nixpkgs.legacyPackages.${system};
      });

      nixosConfigurations.satsuma = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./satsuma/configuration.nix
          ./server-common.nix
          ./lena.nix
          ./common.nix
          agenix.nixosModules.default
          nixosBase
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
          nixosBase
        ];
      };

      darwinConfigurations.lime = nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit inputs; };
        modules = [
          ./lime/configuration.nix
          agenix.darwinModules.default
        ];
      };
    };
}

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
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      groveShell = pkgs.mkShell {
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
    in
    {
      devShells.x86_64-linux = {
        default = groveShell;
        grove = groveShell;
      };

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

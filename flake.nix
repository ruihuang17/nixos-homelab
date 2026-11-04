{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent.url = "github:NousResearch/hermes-agent";
    # Grove dashboard and Prometheus exporter. Only its NixOS module and the
    # exporter script are used here, so it is taken as a plain source tree.
    grove = {
      url = "github:ruihuang17/grove";
      flake = false;
    };
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
      lib = import ./lib {
        inherit
          inputs
          nixpkgs
          agenix
          nix-darwin
          ;
      };

      # Packages built by this flake also come from the local overlay, so the
      # `packages` output and the hosts agree on what `pkgs.matrix-mcp` is.
      pkgsFor = system: nixpkgs.legacyPackages.${system}.appendOverlays [ (import ./overlays) ];

      systems = [ "x86_64-linux" ];

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
    in
    {
      # Reusable in other flakes: services.kiro-gateway.
      nixosModules.kiro-gateway = ./modules/nixos/services/kiro-gateway.nix;

      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit (pkgs) mindroom-nio matrix-mcp kiro-gateway;
        }
      );

      formatter = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (
        system: nixpkgs.legacyPackages.${system}.nixfmt
      );

      devShells = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (system: {
        default = groveShell nixpkgs.legacyPackages.${system};
        grove = groveShell nixpkgs.legacyPackages.${system};
      });

      # `nix flake check` builds every host's toplevel, so an evaluation error
      # is caught here instead of at 04:00 by system.autoUpgrade.
      checks = {
        x86_64-linux = {
          satsuma = self.nixosConfigurations.satsuma.config.system.build.toplevel;
          mail = self.nixosConfigurations.mail.config.system.build.toplevel;
          pomelo = self.nixosConfigurations.pomelo.config.system.build.toplevel;
        };
        aarch64-darwin = {
          lime = self.darwinConfigurations.lime.system;
        };
      };

      nixosConfigurations.satsuma = lib.mkNixos [
        ./hosts/satsuma/configuration.nix
        ./modules/nixos/server.nix
      ];

      nixosConfigurations.mail = lib.mkNixos [
        ./hosts/mail/configuration.nix
        ./modules/nixos/server.nix
      ];

      nixosConfigurations.pomelo = lib.mkNixos [ ./hosts/pomelo/configuration.nix ];

      darwinConfigurations.lime = lib.mkDarwin [ ./hosts/lime/configuration.nix ];
    };
}

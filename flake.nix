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

      # opencode 2.1.1 ends its generated fish completion file with a stray
      # "c" and no trailing newline, so fish tries to run `c` while sourcing
      # it. Drop that byte; keep the check so this becomes a no-op once
      # upstream fixes the generator.
      opencodeCompletionFix = _final: prev: {
        opencode = prev.opencode.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            completion="$out/share/fish/vendor_completions.d/opencode.fish"
            if [ -f "$completion" ] && [ "$(tail -c 1 "$completion")" = c ]; then
              truncate -s -1 "$completion"
            fi
          '';
        });
      };

      # Tail module shared by every NixOS host (satsuma, mail, pomelo).
      # Only the overlay is left here: allowUnfree and experimental-features
      # are set by common-nixos.nix / common-darwin.nix.
      nixosBase = {
        nixpkgs.overlays = [ opencodeCompletionFix ];
      };
    in
    {
      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" ] (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          mindroom-nio = pkgs.callPackage ./pkgs/mindroom-nio { };
        in
        {
          inherit mindroom-nio;
          matrix-mcp = pkgs.callPackage ./pkgs/matrix-mcp { inherit mindroom-nio; };
        }
      );

      devShells = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (system: {
        default = groveShell nixpkgs.legacyPackages.${system};
        grove = groveShell nixpkgs.legacyPackages.${system};
      });

      nixosConfigurations.satsuma = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./satsuma/configuration.nix
          ./server.nix
          ./common-nixos.nix
          agenix.nixosModules.default
          nixosBase
        ];
      };

      nixosConfigurations.bergamot = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./bergamot/configuration.nix
          ./server.nix
          ./common-nixos.nix
          agenix.nixosModules.default
          nixosBase
        ];
      };

      nixosConfigurations.pomelo = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./pomelo/configuration.nix
          ./common-nixos.nix
          nixosBase
        ];
      };

      darwinConfigurations.lime = nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit inputs; };
        modules = [
          ./lime/configuration.nix
          ./common-darwin.nix
          agenix.darwinModules.default
        ];
      };
    };
}

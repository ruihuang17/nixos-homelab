{
  inputs,
  nixpkgs,
  agenix,
  nix-darwin,
}:
# Thin wrappers around nixosSystem/darwinSystem so flake.nix stays a list of
# hosts. Both wire in the shared agenix module and forward `inputs` so modules
# can reach other flake inputs.
rec {
  mkNixos =
    modules:
    nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = modules ++ [ agenix.nixosModules.default ];
    };

  mkDarwin =
    modules:
    nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      specialArgs = { inherit inputs; };
      modules = modules ++ [ agenix.darwinModules.default ];
    };
}

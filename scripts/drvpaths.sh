#!/usr/bin/env bash
# Print the toplevel derivation path of every host in the flake.
# The refactor plan uses this as a baseline: a pure move must not change
# these values, so any difference means something else was edited by mistake.
#
#   scripts/drvpaths.sh            # evaluate the working tree
#   scripts/drvpaths.sh 'path:/etc/nixos'   # explicit flake ref (default)
set -euo pipefail

flake="${1:-path:$(cd "$(dirname "$0")/.." && pwd)}"

targets=(
  nixosConfigurations.satsuma.config.system.build.toplevel
  nixosConfigurations.bergamot.config.system.build.toplevel
  nixosConfigurations.pomelo.config.system.build.toplevel
  darwinConfigurations.lime.system
)

for t in "${targets[@]}"; do
  printf '%-28s %s\n' "${t%%%%.*}" "$(nix eval --raw "${flake}#${t}.drvPath" 2>/dev/null)"
done

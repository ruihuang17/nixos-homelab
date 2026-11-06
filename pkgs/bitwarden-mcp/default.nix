{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  nodejs_22,
}:

buildNpmPackage {
  pname = "bitwarden-mcp-server";
  version = "2026.7.0";

  src = fetchFromGitHub {
    owner = "bitwarden";
    repo = "mcp-server";
    rev = "v2026.7.0";
    hash = "sha256-IYXRpqcJBPE9iZFZeTqZGhJUgUjgO8Di93IapXmDmFo=";
  };

  nodejs = nodejs_22;
  npmDepsHash = "sha256-rCK8vaZdsyOLgWRub54exa8TTgB7NeXjDnhlz5DBTOY=";

  # `prepare` runs husky, which needs a git checkout. The build script is
  # invoked explicitly by buildNpmPackage.
  npmFlags = [ "--ignore-scripts" ];

  # Only the compiled output is needed at runtime.
  npmPruneFlags = [ "--ignore-scripts" ];

  meta = {
    description = "MCP server for Bitwarden vault and organization administration";
    homepage = "https://github.com/bitwarden/mcp-server";
    license = lib.licenses.gpl3Only;
    mainProgram = "mcp-server-bitwarden";
    platforms = lib.platforms.linux;
  };
}

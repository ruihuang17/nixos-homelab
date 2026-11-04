final: prev:
# Local packages, so hosts and modules use plain `pkgs.<name>` instead of
# `inputs.self.packages...` or `callPackage ../../pkgs/...` paths.
let
  inherit (prev) callPackage;
in
{
  mindroom-nio = callPackage ../pkgs/mindroom-nio { };

  matrix-mcp = callPackage ../pkgs/matrix-mcp {
    mindroom-nio = final.mindroom-nio;
  };

  kiro-gateway = callPackage ../pkgs/kiro-gateway { };

  # opencode 2.1.1 ends its generated fish completion file with a stray "c" and
  # no trailing newline, so fish tries to run `c` while sourcing it. Drop that
  # byte; the check makes this a no-op once upstream fixes the generator.
  opencode = prev.opencode.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      completion="$out/share/fish/vendor_completions.d/opencode.fish"
      if [ -f "$completion" ] && [ "$(tail -c 1 "$completion")" = c ]; then
        truncate -s -1 "$completion"
      fi
    '';
  });
}

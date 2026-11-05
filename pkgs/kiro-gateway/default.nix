{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  makeWrapper,
  python3Packages,
  runCommand,
}:

let
  # Our fork: upstream main (a5292ca, 2026-05-18) plus the compatibility fixes
  # on the `homelab` branch. Upstream is unmaintained, so the fixes live there
  # as commits instead of a patch file. See pkgs/kiro-gateway/README.md.
  src = fetchFromGitHub {
    owner = "ruihuang17";
    repo = "kiro-gateway";
    rev = "581160901523225b4ba8bcca589674b88f8d3aec";
    hash = "sha256-lRlAbqxa27zmvFxi+TLdt4RmloyegyiKv9/R6r1X4Xg=";
  };

  # tiktoken downloads cl100k_base on first use and caches it by the SHA-1 of
  # the URL. Ship the cache so the service never depends on that download.
  tiktokenCache = runCommand "kiro-gateway-tiktoken-cache" { } ''
    mkdir -p $out
    cp ${
      fetchurl {
        url = "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken";
        sha256 = "223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7";
      }
    } $out/9b5ad71b2ce5302211f9c61530b329a4922fc6a4
  '';

  python = python3Packages.python.withPackages (
    ps: with ps; [
      fastapi
      httpx
      loguru
      python-dotenv
      tiktoken
      uvicorn
    ]
  );
in
stdenv.mkDerivation {
  pname = "kiro-gateway";
  version = "unstable-2026-11-04";

  inherit src;

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/kiro-gateway $out/bin
    cp -r main.py kiro $out/share/kiro-gateway/

    makeWrapper ${python}/bin/python $out/bin/kiro-gateway \
      --add-flags "$out/share/kiro-gateway/main.py" \
      --set-default TIKTOKEN_CACHE_DIR "${tiktokenCache}"

    runHook postInstall
  '';

  meta = {
    description = "Proxy gateway for the Kiro API (patched community build)";
    homepage = "https://github.com/ruihuang17/kiro-gateway";
    license = lib.licenses.agpl3Only;
    mainProgram = "kiro-gateway";
    platforms = lib.platforms.linux;
  };
}

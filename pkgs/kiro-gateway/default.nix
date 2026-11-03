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
  # Last upstream commit on main (2026-05-18). The project is effectively
  # unmaintained; the compatibility fixes live in the patch file below.
  src = fetchFromGitHub {
    owner = "jwadow";
    repo = "kiro-gateway";
    rev = "a5292ca04c7c6231e0b47673ac3f981f5a706e1e";
    hash = "sha256-LgZiMJXy7v0o4VbQTMYi1Yk2SjBsKj82cUC5FhhZ4zo=";
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
  version = "unstable-2026-05-18";

  inherit src;

  # Community fixes cherry-picked from open pull requests against upstream,
  # plus the stream keepalive needed by OpenCode's idle watchdog.
  patches = [
    ./patches/kiro-gateway-fixes.patch
    # Do not trip the account circuit breaker on Kiro's transient
    # INSUFFICIENT_MODEL_CAPACITY 429, and return the real upstream status
    # instead of a generic "No available accounts" 503.
    ./patches/account-capacity-429.patch
  ];

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
    homepage = "https://github.com/jwadow/kiro-gateway";
    license = lib.licenses.agpl3Only;
    mainProgram = "kiro-gateway";
    platforms = lib.platforms.linux;
  };
}

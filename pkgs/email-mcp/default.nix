{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

# Upstream ships a self-contained Bun-compiled binary for Linux. Package the
# release asset directly instead of rebuilding the TypeScript project: the
# binary has no runtime Node dependency and starts in a few milliseconds.
stdenv.mkDerivation {
  pname = "email-mcp";
  version = "0.6.0";

  src = fetchurl {
    url = "https://github.com/codefuturist/email-mcp/releases/download/v0.6.0/email-mcp_0.6.0_linux_amd64.tar.gz";
    hash = "sha256-u0RMK/ccDT+z92PgdjIq/v8wp5ri3a0DdyMcpZvgjf4=";
  };

  # The archive contains the binary at its root, with no wrapping directory.
  sourceRoot = ".";

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  dontBuild = true;
  dontConfigure = true;
  # Bun stores the bundled application in a trailer appended to the ELF. The
  # default fixup strip pass removes it, leaving a plain Bun runtime.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 email-mcp $out/bin/email-mcp
    runHook postInstall
  '';

  meta = {
    description = "MCP server for reading, searching, organising and sending email via IMAP and SMTP";
    homepage = "https://github.com/codefuturist/email-mcp";
    license = lib.licenses.lgpl3Only;
    mainProgram = "email-mcp";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

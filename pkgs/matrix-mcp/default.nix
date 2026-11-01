{
  lib,
  python3Packages,
  fetchurl,
  mindroom-nio,
}:

let
  # matrix-mcp pins fastmcp==3.2.4, while nixpkgs has moved to 3.4.x and mcp
  # 2.x. Build the pinned release against the mcp 1.x line it declares.
  fastmcp = python3Packages.buildPythonPackage {
    pname = "fastmcp";
    version = "3.2.4";
    format = "wheel";

    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/cf/76/b310d52fa0e30d39bd937eb58ec2c1f1ea1b5f519f0575e9dd9612f01deb/fastmcp-3.2.4-py3-none-any.whl";
      hash = "sha256-5snEKRcQQUVeR6uUuz+DxGV2IqDsKJIvaUAFOVm9WKk=";
    };

    # Mirrors fastmcp 3.2.4's base dependencies, including the
    # py-key-value-aio[filetree,keyring,memory] and pydantic[email] extras.
    dependencies = with python3Packages; [
      aiofile
      anyio
      authlib
      cachetools
      cyclopts
      email-validator
      exceptiongroup
      griffelib
      httpx
      jsonref
      jsonschema-path
      keyring
      mcp_1
      openapi-pydantic
      opentelemetry-api
      packaging
      platformdirs
      py-key-value-aio
      pydantic
      pyperclip
      python-dotenv
      pyyaml
      rich
      uncalled-for
      uvicorn
      watchfiles
      websockets
    ];

    doCheck = false;
    pythonImportsCheck = [ "fastmcp" ];

    meta = {
      description = "Fast, Pythonic way to build MCP servers and clients";
      homepage = "https://github.com/PrefectHQ/fastmcp";
      license = lib.licenses.asl20;
    };
  };
in
python3Packages.buildPythonApplication {
  pname = "matrix-mcp";
  version = "0.9.1";
  format = "wheel";

  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/c3/ae/905987c9909add29d180a00b7ca26430098bf35cb390082dc6d466e93c12/matrix_mcp-0.9.1-py3-none-any.whl";
    hash = "sha256-mj17rxxutkBOPdH2S2nCzZCxV3jtrQOrnqoUyOuED2s=";
  };

  # fastmcp's server/client extras already pull in py-key-value-aio[filetree],
  # so the file-backed stores matrix-mcp relies on are available.
  dependencies = with python3Packages; [
    anyio
    certifi
    cryptography
    fastmcp
    filelock
    httpx
    markdown-it-py
    mindroom-nio
    platformdirs
    py-key-value-aio
    pydantic
    pydantic-settings
    rich
    typer
  ];

  # Render fenced code blocks (and other Markdown) into Matrix's
  # org.matrix.custom.html formatted_body, so clients show real code blocks
  # instead of literal backticks. The wheel unpack phase has no source tree to
  # patch, so apply the patch to the installed package.
  postInstall = ''
    (
      cd "$out/${python3Packages.python.sitePackages}"
      patch -p1 < ${./patches/markdown-formatting.patch}
    )
  '';

  # The tests need a live Matrix homeserver.
  doCheck = false;
  pythonImportsCheck = [ "matrix_mcp" ];

  meta = {
    description = "MCP server that connects coding agents to Matrix";
    homepage = "https://github.com/mindroom-ai/matrix-mcp";
    license = lib.licenses.mit;
    mainProgram = "matrix-mcp";
    platforms = lib.platforms.unix;
  };
}

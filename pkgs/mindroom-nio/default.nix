{
  lib,
  python3Packages,
  fetchurl,
}:

python3Packages.buildPythonPackage {
  pname = "mindroom-nio";
  version = "1.3.0";
  format = "wheel";

  # fetchPypi builds the legacy /packages/py3/... path, which PyPI no longer
  # serves; pin the hashed wheel URL from the release metadata instead.
  src = fetchurl {
    url = "https://files.pythonhosted.org/packages/bb/77/61fe7df2242b5aaf71072287e13c1b5dfb090523c800007d6ca2032e0776/mindroom_nio-1.3.0-py3-none-any.whl";
    hash = "sha256-T4B6yTBE30PB849TEjB7K0yYap3zQoYgOm6c5hA+ewM=";
  };

  # The e2e extra is what matrix-mcp needs: vodozemac, peewee and cachetools.
  dependencies = with python3Packages; [
    aiohttp
    aiofiles
    h11
    h2
    jsonschema
    unpaddedbase64
    pycryptodome
    aiohttp-socks
    cachetools
    peewee
    vodozemac
  ];

  # Upstream's test suite needs a live homeserver and network access.
  doCheck = false;
  pythonImportsCheck = [ "nio" ];

  meta = {
    description = "Matrix client library (MindRoom fork of matrix-nio)";
    homepage = "https://github.com/mindroom-ai/mindroom-nio";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}

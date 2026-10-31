# The Homebrew side of lime: an inventory, not a lockfile. Homebrew cannot pin
# versions, so this only records what is installed and lets `brew bundle`
# install anything missing.
{
  homebrew = {
    enable = true;
    user = "rhuang";

    # Adopt-only until the list has been through one full switch: nothing is
    # ever removed or upgraded behind our back.
    onActivation.cleanup = "none";
    onActivation.autoUpdate = false;
    onActivation.upgrade = false;

    # Deliberately absent:
    #   bluebubbles - uninstalled 2026-10-31, replaced by mautrix-imessage
    #   sunshine    - installed but unused; also a TCC liability (see
    #                 docs/lime (macOS).md)
    casks = [
      "jellyfin"
      "kitty"
    ];

    brews = [
      "aom"
      "boost"
      "brotli"
      "ca-certificates"
      "cmake"
      "curl"
      "dav1d"
      "fastfetch"
      "ffmpeg"
      "fish"
      "gettext"
      "giflib"
      "go"
      "icu4c@78"
      "iperf3"
      "jpeg-turbo"
      "json-c"
      "lame"
      "libde265"
      "libheif"
      "libidn2"
      "libnghttp2"
      "libnghttp3"
      "libngtcp2"
      "libpng"
      "libpsl"
      "libssh2"
      "libtiff"
      "libunistring"
      "libvmaf"
      "libvpx"
      "lua"
      "lz4"
      "miniupnpc"
      "mpg123"
      "node_exporter"
      "openldap"
      "openssl@3"
      "openssl@4"
      "opus"
      "pcre2"
      "pkgconf"
      "sdl2-compat"
      "sdl3"
      "svt-av1"
      "webp"
      "wget"
      "x264"
      "x265"
      "xz"
      "yyjson"
      "zstd"
    ];
  };
}

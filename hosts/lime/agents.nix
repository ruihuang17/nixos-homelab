# launchd user agents for lime. These replace the hand-written plists that
# used to live in ~/Library/LaunchAgents; labels are kept identical so the
# agent identity (and its TCC consent) does not change.
{
  homelab,
  pkgs,
  ...
}:
let
  home = "/Users/rhuang";
  logs = "${home}/Library/Logs";
in
{
  launchd.user.agents = {
    # Replaces the Homebrew service (same label and plist path). Binds all
    # interfaces on purpose: Prometheus on satsuma scrapes 10.0.10.73:9100.
    node-exporter = {
      serviceConfig = {
        Label = "sh.brew.node_exporter";
        ProgramArguments = [
          "${pkgs.prometheus-node-exporter}/bin/node_exporter"
          # The iMessage digest writes imessage_digest.prom here; see
          # lime/digest/default.nix.
          "--collector.textfile.directory=${home}/Library/Application Support/imessage-digest/textfile"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${logs}/node_exporter.log";
        StandardErrorPath = "${logs}/node_exporter.err.log";
      };
    };

    # Jellyfin is a cask; `open` exits immediately, so no KeepAlive.
    jellyfin = {
      command = "/usr/bin/open -a Jellyfin";
      serviceConfig = {
        Label = "com.jellyfin.server";
        RunAtLoad = true;
        LimitLoadToSessionType = "Aqua";
      };
    };

    mautrix-imessage = {
      # ProgramArguments rather than `command`: nix-darwin's `command` wraps
      # things in `/bin/sh -c`, and TCC attributes the chat.db access to that
      # wrapper. The Full Disk Access grant is on the binary itself, so launch
      # it directly.
      serviceConfig = {
        Label = "fi.mau.mautrix-imessage";
        # The config holds the appservice as_token/hs_token, so it is decrypted
        # by agenix into /run/agenix (ramdisk) instead of living in plaintext in
        # the home directory. -n stops the bridge from writing the decrypted
        # copy back to the ramdisk.
        ProgramArguments = [
          "${home}/mautrix-imessage/mautrix-imessage"
          "-c"
          "/run/agenix/imessage-config"
          "-n"
        ];
        WorkingDirectory = "${home}/mautrix-imessage";
        EnvironmentVariables.DYLD_LIBRARY_PATH = "${home}/.local/libolm/lib:/opt/homebrew/lib";
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        StandardOutPath = "${home}/mautrix-imessage/logs/stdout.log";
        StandardErrorPath = "${home}/mautrix-imessage/logs/stderr.log";
      };
    };

    # The unsigned mautrix binary cannot open a LAN socket under macOS Local
    # Network Privacy (EHOSTUNREACH to 10.0.10.72), while Apple-signed
    # /usr/bin/ssh can. Forward the wsproxy's loopback port over SSH so the
    # bridge only connects to 127.0.0.1; see docs/iMessage Digest.md.
    wsproxy-tunnel = {
      serviceConfig = {
        Label = "ca.estrogenuinely.wsproxy-tunnel";
        ProgramArguments = [
          "/usr/bin/ssh"
          "-N"
          "-o"
          "BatchMode=yes"
          "-o"
          "ConnectTimeout=10"
          "-o"
          "ExitOnForwardFailure=yes"
          "-o"
          "ServerAliveInterval=30"
          "-o"
          "ServerAliveCountMax=3"
          "-o"
          "StrictHostKeyChecking=accept-new"
          "-L"
          "127.0.0.1:29331:127.0.0.1:29331"
          "rhuang@${homelab.ip "satsuma"}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        LimitLoadToSessionType = "Aqua";
        StandardOutPath = "${logs}/wsproxy-tunnel.log";
        StandardErrorPath = "${logs}/wsproxy-tunnel.err.log";
      };
    };
  };
}

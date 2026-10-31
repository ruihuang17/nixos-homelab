# launchd user agents for lime. These replace the hand-written plists that
# used to live in ~/Library/LaunchAgents; labels are kept identical so the
# agent identity (and its TCC consent) does not change.
{
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
      command = "${pkgs.prometheus-node-exporter}/bin/node_exporter";
      serviceConfig = {
        Label = "sh.brew.node_exporter";
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
        ProgramArguments = [ "${home}/mautrix-imessage/mautrix-imessage" ];
        WorkingDirectory = "${home}/mautrix-imessage";
        EnvironmentVariables.DYLD_LIBRARY_PATH = "${home}/.local/libolm/lib:/opt/homebrew/lib";
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        StandardOutPath = "${home}/mautrix-imessage/logs/stdout.log";
        StandardErrorPath = "${home}/mautrix-imessage/logs/stderr.log";
      };
    };
  };
}

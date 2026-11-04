# iMessage group-chat digest: launchd agent, state directory, agenix secret.
#
# The service is a one-shot Python process every five minutes. It reads the
# mautrix-imessage portal rooms through the Matrix client API (no chat.db, no
# new TCC grant), runs Apple's on-device model via Homebrew apfel, and writes a
# node_exporter textfile heartbeat.
{ config, pkgs, ... }:
let
  home = "/Users/rhuang";
  stateDir = "${home}/Library/Application Support/imessage-digest";
  logs = "${home}/Library/Logs";
  python = pkgs.python3;

  # Immutable copy of the service. config.toml and prompts are not secrets.
  src = pkgs.runCommand "imessage-digest-src" { } ''
    mkdir -p $out
    cp -R ${./.}/. $out/
    rm -f $out/default.nix
    find $out -name __pycache__ -type d -prune -exec rm -rf {} +
    find $out -name '*.pyc' -delete
  '';
in
{
  age.secrets.imessage-digest = {
    file = ../secrets/imessage-digest.age;
    owner = "rhuang";
    group = "staff";
    mode = "0400";
  };

  system.activationScripts.imessageDigestStateDir.text = ''
    mkdir -p "${stateDir}" "${stateDir}/textfile"
    chown rhuang:staff "${stateDir}" "${stateDir}/textfile"
    chmod 700 "${stateDir}"
  '';

  launchd.user.agents.imessage-digest = {
    command = "${python}/bin/python3 ${src}/main.py --once --config ${src}/config.toml --secrets ${config.age.secrets.imessage-digest.path}";
    serviceConfig = {
      Label = "ca.estrogenuinely.imessage-digest";
      StartInterval = 300;
      RunAtLoad = true;
      LimitLoadToSessionType = "Aqua";
      ProcessType = "Background";
      WorkingDirectory = stateDir;
      StandardOutPath = "${logs}/imessage-digest.log";
      StandardErrorPath = "${logs}/imessage-digest.err.log";
      EnvironmentVariables = {
        PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        TZ = "America/Toronto";
      };
    };
  };
}

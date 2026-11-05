{
  pkgs,
  ...
}:
# Daily flake update plus the push that keeps origin/main in sync.
{
  system.autoUpgrade = {
    enable = true;
    flake = "/etc/nixos/#satsuma";
    flags = [
      "--print-build-logs"
      "--commit-lock-file"
    ];
    dates = "04:00";
    randomizedDelaySec = "45min";
    allowReboot = false; # Set to true if you want automatic reboots
  };

  # After autoUpgrade commits the flake.lock bump, push it back to origin
  # so the GitHub repo stays in sync with the live system. Non-fatal: a push
  # failure (e.g. transient network) must not fail the already-applied upgrade.
  systemd.services.nixos-upgrade.serviceConfig.ExecStartPost =
    "-${pkgs.writeShellScript "nixos-upgrade-push" ''
      set -u
      export HOME=/root
      export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i /root/.ssh/general -o IdentitiesOnly=yes"
      cd /etc/nixos || exit 0
      # Only push if the local branch is ahead of origin/main.
      ${pkgs.git}/bin/git fetch --quiet origin main || exit 0
      if [ "$(${pkgs.git}/bin/git rev-parse HEAD)" != "$(${pkgs.git}/bin/git rev-parse origin/main)" ]; then
        ${pkgs.git}/bin/git push origin HEAD:main
      fi
    ''}";
}

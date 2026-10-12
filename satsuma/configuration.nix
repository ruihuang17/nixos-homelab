{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
let
  zfsCompatibleKernelPackages = lib.filterAttrs (
    name: kernelPackages:
    (builtins.match "linux_[0-9]+_[0-9]+" name) != null
    && (builtins.tryEval kernelPackages).success
    && (!kernelPackages.${config.boot.zfs.package.kernelModuleAttribute}.meta.broken)
  ) pkgs.linuxKernel.packages;
  latestKernelPackage = lib.last (
    lib.sort (a: b: (lib.versionOlder a.kernel.version b.kernel.version)) (
      builtins.attrValues zfsCompatibleKernelPackages
    )
  );
in
{
  nixpkgs.config.allowUnfree = true;

  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./nginx.nix
    ./networking.nix
    ./kanidm.nix
    ./paperless.nix
    ./tailscale.nix
    ./mail.nix
    ./postgres.nix
    ./immich.nix
    ./vaultwarden.nix
    ./matrix.nix
    ./zfs-backup.nix
    ./boot-replication.nix
    ./postgres-backup.nix

    ./nextcloud
    ./arr-stack
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = latestKernelPackage;

  # Set your time zone.
  time.timeZone = "America/Toronto";

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  environment.systemPackages = with pkgs; [
    go
    hugo
    ffsubsync
  ];

  # Power Optimization
  powerManagement.cpuFreqGovernor = "powersave";
  powerManagement.powertop.enable = true;

  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC = "power";
      PCIE_ASPM_ON_AC = "powersupersave";
      RUNTIME_PM_ON_AC = "auto";
      # Leave SATA_LINKPWR alone if it fights ZFS I/O; test carefully
    };
  };
  services.power-profiles-daemon.enable = false;

  # Spin down HDDs only — target explicitly by wwn, skip NVMe entirely.
  # Longer idle timeout (30 min) reduces spin-up/down cycling.
  services.udev.extraRules = ''
    ACTION=="add", KERNEL=="sda", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sda"
    ACTION=="add", KERNEL=="sdb", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sdb"
    ACTION=="add", KERNEL=="sdc", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sdc"
    ACTION=="add", KERNEL=="sdd", SUBSYSTEM=="block", RUN+="${pkgs.hdparm}/bin/hdparm -S 240 /dev/sdd"
  '';
  # Reduce ZFS write frequency to disk (fewer wake-ups)
  boot.extraModprobeConfig = ''
    options zfs zfs_txg_timeout=30
  '';

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

  system.stateVersion = "26.05"; # Did you read the comment?
}

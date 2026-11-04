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

  # Disable password-based SSH authentication for all accounts.
  # Key-based authentication remains available for root, rhuang, and lena.
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };

  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./core/networking.nix
    ./core/nginx.nix
    ./core/tailscale.nix
    ./core/kanidm.nix
    ./core/mail.nix
    ./core/postgres.nix

    ./apps/paperless.nix
    ./apps/vaultwarden.nix
    ./apps/nextcloud

    ./media/immich.nix
    ./media/arr-stack

    ./matrix/matrix.nix

    ./backup/zfs-backup.nix
    ./backup/boot-replication.nix
    ./backup/postgres-backup.nix
    ./backup/restic-offsite.nix

    ./monitoring/monitoring.nix
    ./monitoring/monitoring-overview.nix
    ./monitoring/alerting.nix
    "${inputs.grove}/monitoring/grove-exporter.nix"

    ./ai/hermes.nix
    ./ai/kiro-gateway.nix
    ./ai/opencode.nix
  ];

  # Kiro API proxy used by the OpenCode provider. Bound to all interfaces;
  # the module only opens the port on the LAN interface (and tailscale0 is
  # already trusted), so this is not intentionally WAN-facing.
  services.kiro-gateway = {
    enable = true;
    address = "0.0.0.0";
  };

  # ZFS/SMART/media/database telemetry for the Grove dashboard.
  services.groveExporter = {
    enable = true;
    zfs.enable = true;
    smartctl.enable = true;
    sonarr.enable = true;
    radarr.enable = true;
    prowlarr.enable = true;
    qbittorrent.enable = true;
    unifi = {
      enable = true;
      url = "https://10.0.10.1";
      user = "grove";
      passwordFile = config.age.secrets.unifi-grove-password.path;
    };
  };

  # Password for the local UniFi account used by the unpoller exporter. The
  # exporter runs as the unpoller-exporter group, so keep the decrypted copy
  # readable by that group only.
  age.secrets.unifi-grove-password = {
    file = "/etc/nixos/satsuma/secrets/unifi-grove-password.age";
    owner = "root";
    group = "unpoller-exporter";
    mode = "0440";
  };

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
    nh
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

  # The exported datasets are separate fstab-generated mount units. `zfs share
  # -a` only exports datasets that are currently mounted, so ordering zfs-share
  # after them prevents it from regenerating an empty NFS export list during
  # `nixos-rebuild switch` (which can restart all of these units at once).
  systemd.services.zfs-share = {
    after = [
      "hdd-data.mount"
      "hdd-mediaSrv.mount"
      "hdd-backup.mount"
    ];
    wants = [
      "hdd-data.mount"
      "hdd-mediaSrv.mount"
      "hdd-backup.mount"
    ];
  };

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

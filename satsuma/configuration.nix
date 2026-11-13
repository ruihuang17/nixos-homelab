{
  inputs,
  pkgs,
  ...
}:
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./core/networking.nix
    ./core/nginx.nix
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
    ./monitoring/sms-bridge.nix
    ./monitoring/grove.nix
    "${inputs.grove}/monitoring/grove-exporter.nix"

    ./system/kernel.nix
    ./system/power.nix
    ./system/storage.nix
    ./system/auto-upgrade.nix

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

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Set your time zone.
  time.timeZone = "America/Toronto";

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  environment.systemPackages = with pkgs; [
    go
    hugo
    ffsubsync
    nh
    rbw
    pinentry-curses # headless host; rbw is configured with `pinentry = "pinentry-curses"`
  ];

  system.stateVersion = "26.05"; # Did you read the comment?
}

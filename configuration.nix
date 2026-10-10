# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

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

    ./nextcloud
    ./arr-stack
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = latestKernelPackage;

  networking.hostName = "satsuma"; # Define your hostname.
  networking.hostId = "af300f15";

  # Set your time zone.
  time.timeZone = "America/Toronto";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.rhuang = {
    uid = 1000;
    isNormalUser = true;
    shell = pkgs.fish;
    extraGroups = [
      "wheel"
      "media"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH"
    ];
  };

  users.users.lena = {
    uid = 1001;
    isNormalUser = true;
    shell = pkgs.fish;
    extraGroups = [
      "wheel"
      "media"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICw7CHZkiNoG7StuF3NBnCHRWvsujJdX4ZTDIhz6YonH"
    ];
  };

  users.users.root = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH"
    ];
    shell = pkgs.fish;
  };

  security.sudo.wheelNeedsPassword = false;

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  environment.systemPackages = with pkgs; [
    helix
    ripgrep
    kiro-cli
    vim
    git
    nixfmt
    ethtool
    kitty
    sourceHighlight
    btop
    smartmontools
    go
    hugo
    tree
    ffsubsync
    inputs.agenix.packages.${stdenv.hostPlatform.system}.default
  ];

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  programs.fish.enable = true;
  programs.nix-ld.enable = true;
  programs.bash = {
    interactiveShellInit = ''
      export LESSOPEN="| /run/current-system/sw/bin/src-hilite-lesspipe.sh %s"
      export LESS="-R"
    '';
  };

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
    flake = "/etc/nixos/";
    flags = [
      "--print-build-logs"
      "--commit-lock-file"
    ];
    dates = "04:00";
    randomizedDelaySec = "45min";
    allowReboot = false; # Set to true if you want automatic reboots
  };

  nix.optimise.automatic = true;
  nix.optimise.dates = [ "05:00" ]; # Optional; allows customizing optimisation schedule

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "26.05"; # Did you read the comment?

}

{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
# Baseline for every NixOS host (satsuma, bergamot, pomelo): nix settings,
# rhuang's account, sshd defaults, the interactive shell tooling, the shared
# CLI packages and the dotfiles.
#
# Server-only pieces (Lena, root's keys, subnet-router Tailscale, the node
# exporter) live in server.nix. A host opts in by importing the file; there is
# no option that switches behaviour on.
let
  homelab = import ./homelab.nix;

  # Link dotfiles into every known user that this host actually defines. root
  # always exists; rhuang and lena depend on what the host/config declares.
  dotUsers = builtins.filter (u: config.users.users ? ${u}) [
    "root"
    "rhuang"
    "lena"
  ];

  # ".config/a/b.toml" -> [ ".config" ".config/a" ]
  parentDirs =
    rel:
    let
      parts = lib.splitString "/" rel;
    in
    map (n: lib.concatStringsSep "/" (lib.take n parts)) (lib.range 1 (lib.length parts - 1));

  allDirs = lib.unique (lib.concatMap parentDirs (lib.attrNames homelab.dotfiles));

  githubSshConfig = ''
    Host github.com
        HostName github.com
        User git
        IdentityFile ~/.ssh/general
  '';
in
{
  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  # Deploys push store paths built on another host (scripts/deploy.sh), and no
  # host has a binary-cache signing key, so the receiving daemon must not apply
  # the signature check to a local push. `wheel` already has passwordless sudo
  # on every host, so this grants the daemon no power those users lack. Cache
  # substitution still requires signatures (`require-sigs` stays on). `root` is
  # already a trusted user by default.
  nix.settings.trusted-users = [ "@wheel" ];
  nix.optimise.automatic = true;
  nix.optimise.dates = [ "05:00" ];

  users.users.rhuang = {
    uid = homelab.users.rhuang.uid;
    isNormalUser = true;
    shell = pkgs.fish;
    extraGroups = [
      "wheel"
      "media"
    ];
    openssh.authorizedKeys.keys = homelab.users.rhuang.keys;
  };
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    kitty.terminfo # so SSH from kitty (TERM=xterm-kitty) works
    kiro-cli
    vim
    git
    nixfmt
    gh
    ethtool
    dig
    sourceHighlight
    btop
    smartmontools
    tree
    jq
    python3
    opencode
    inputs.agenix.packages.${stdenv.hostPlatform.system}.default
    starship
  ];

  # mkDefault so a host can opt out (pomelo sets PermitRootLogin = "no").
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = lib.mkDefault "prohibit-password";
  };

  # SSH aliases for every homelab machine, plus one shared control connection
  # per host. mkAfter keeps the postgres-backup `Host bergamot` block (which
  # must win: ssh uses the first value it finds) ahead of these.
  programs.ssh.extraConfig = lib.mkAfter (githubSshConfig + "\n" + homelab.sshConfig);

  programs.git = {
    enable = true;
    config = {
      user = {
        name = "Rui Huang";
        email = "rui@ruihuang.io";
      };
      # /etc/nixos is root-owned but used by rhuang and the OpenCode agent.
      safe.directory = "/etc/nixos";
    };
  };

  programs.fish.enable = true;
  programs.nix-ld.enable = true;
  programs.tmux.enable = true;

  programs.fish.interactiveShellInit = ''
    if test "$TERM" != "dumb"
      ${pkgs.starship}/bin/starship init fish | source
    end
  '';

  systemd.tmpfiles.rules = lib.concatMap (
    user:
    let
      u = config.users.users.${user};
    in
    (map (d: "d ${u.home}/${d} - ${user} ${u.group} -") allDirs)
    ++ (lib.mapAttrsToList (rel: src: "L+ ${u.home}/${rel} - - - - ${src}") homelab.dotfiles)
  ) dotUsers;
}

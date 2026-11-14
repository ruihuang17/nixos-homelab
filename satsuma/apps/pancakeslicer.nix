# PancakeSlicer: self-hosted non-planar 3D printer slicer
# (https://github.com/ZimengXiong/PancakeSlicer).
#
# Runs upstream's official Linux release payload directly — no Docker, no
# build from source. The desktop tarball for linux-x64 ships everything the
# Docker image ships: a static Go server (orca-webapp-server), the C++
# OrcaSlicer engine (nonplanar_slice_tool) with its bundled libraries, the
# prebuilt web UI, and engine qualification metadata. The engine's ELF
# interpreter resolves via programs.nix-ld (enabled in common-nixos.nix).
#
# Data lives in /var/lib/pancakeslicer (projects, profiles, printers,
# preferences, job scratch) and is covered by the restic offsite backup
# through its /var path. The service listens on 127.0.0.1:6868 only and is
# reachable over HTTPS at https://pancakeslicer.local.estrogenuinely.ca via
# core/nginx.nix.
#
# Upgrades: bump `version` (fetchurl hash is verified below) and rebuild;
# the store path swap is picked up on service restart. Keep this comment in
# sync with what the package actually does.
# https://github.com/ZimengXiong/PancakeSlicer/releases

{ pkgs, ... }:
let
  version = "0.4.8";
  # Engine source the release was built from (web/REVISION.txt in the tarball);
  # baked into the AGPL-3.0 corresponding-source offer below.
  revision = "dd523809f5783949877c3d48897d1e0f8e46818a";

  app = pkgs.runCommand "pancakeslicer-${version}"
    {
      inherit version;
      src = pkgs.fetchurl {
        url = "https://github.com/ZimengXiong/PancakeSlicer/releases/download/v${version}/PancakeSlicer-${version}-linux-x64.tar.gz";
        sha256 = "sha256-thTQSmMF747cT030TznfesUWpfeAZZoVRFvVHtyjo1s=";
      };
      # Binaries and libraries are already stripped and patchelf'd upstream;
      # don't let fixupPhase mangle them.
      dontStrip = true;
      dontFixup = true;
    }
    ''
      tar -xzf $src
      mkdir -p $out
      cp -a PancakeSlicer-${version}-linux-x64/resources/engine $out/engine
      cp -a PancakeSlicer-${version}-linux-x64/resources/web $out/web
    '';
in
{
  users.users.pancakeslicer = {
    isSystemUser = true;
    group = "pancakeslicer";
  };
  users.groups.pancakeslicer = { };

  systemd.services.pancakeslicer = {
    description = "PancakeSlicer self-hosted web slicer";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    environment = {
      ORCA_WEB_LISTEN = "127.0.0.1:6868";
      ORCA_WEB_DATA_DIR = "/var/lib/pancakeslicer/data";
      ORCA_WEB_JOB_ROOT = "/var/lib/pancakeslicer/jobs"; # finished slices kept 2h by default
      ORCA_WEB_STATIC = "${app}/web";
      ORCA_WEB_TOOL = "${app}/engine/nonplanar_slice_tool";
      ORCA_WEB_RESOURCES = "${app}/engine/resources";
      ORCA_WEB_SURFACE_MANIFEST = "${app}/engine/surface-manifest.json";
      ORCA_WEB_ARTIFACT_QUALIFICATION = "${app}/engine/artifact-qualification.ready";
      # AGPL-3.0 section 13: the web UI surfaces this as the source offer.
      ORCA_WEB_SOURCE_URL = "https://github.com/ZimengXiong/PancakeSlicer/archive/${revision}.tar.gz";
      ORCA_WEB_MAX_JOBS = "2"; # concurrent slices; extras queue (compose default)
      ORCA_WEB_PRINTER_NETWORK = "lan";
      HOME = "/var/lib/pancakeslicer";
      TZ = "UTC";
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = "${app}/engine/orca-webapp-server";
      User = "pancakeslicer";
      Group = "pancakeslicer";
      StateDirectory = "pancakeslicer";
      Restart = "on-failure";
      # Match the resource limits and sandboxing of the upstream compose file
      # (mem_limit 8g, no-new-privileges, cap_drop ALL), plus NixOS defaults.
      MemoryMax = "8G";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      # Mutations (adding printers, starting prints) are unauthenticated; to
      # require a token, add
      #   ORCA_WEB_BEARER_TOKEN = "...";
      # to the environment above. Anyone who can reach the nginx vhost can
      # mutate state, so the token is worth considering.
    };
  };
}

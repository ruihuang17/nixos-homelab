# Redundant /boot (EFI System Partition) replication.
#
# Background:
#   The root/data pool is a two-disk ZFS mirror (nvme0n1p2 + nvme1n1p2), so data
#   survives either NVMe failing. But ZFS cannot host /boot, so each NVMe carries
#   its own FAT EFI System Partition:
#
#     nvme1n1p1  UUID A3AB-7D38  label "boot"      -> mounted at /boot (PRIMARY)
#     nvme0n1p1  UUID 1BEB-C3B7  label "boot-bak"  -> BACKUP (unmounted)
#
#   systemd-boot only ever writes the primary ESP (it has no mirroredBoots like
#   GRUB). This module mirrors the primary ESP onto the backup ESP and registers
#   a UEFI boot entry for the backup disk so the firmware can boot it if nvme1
#   dies. The sync is triggered three ways for robustness:
#     1. a path unit watching /boot (fires right after `nixos-rebuild switch`)
#     2. a daily timer (safety net / random-seed drift)
#     3. manually via `systemctl start sync-backup-esp`
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Stable filesystem UUID of the backup EFI System Partition.
  backupEspUuid = "1BEB-C3B7"; # nvme0n1p1, the redundant copy

  # Backup disk + partition number, needed by efibootmgr to create a boot entry.
  backupDisk = "/dev/nvme0n1";
  backupPartNum = "1";

  espMountPoint = config.boot.loader.efi.efiSysMountPoint; # "/boot"

  syncScript = pkgs.writeShellApplication {
    name = "sync-backup-esp";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
      rsync
      dosfstools
      efibootmgr
      gawk
    ];
    text = ''
      set -euo pipefail

      PRIMARY_SRC="${espMountPoint}"
      BACKUP_DEV="/dev/disk/by-uuid/${backupEspUuid}"
      MNT="$(mktemp -d /tmp/esp-backup.XXXXXX)"

      cleanup() {
        if mountpoint -q "$MNT"; then
          umount "$MNT" || true
        fi
        rmdir "$MNT" 2>/dev/null || true
      }
      trap cleanup EXIT

      if [ ! -e "$BACKUP_DEV" ]; then
        echo "backup ESP $BACKUP_DEV not present; skipping" >&2
        exit 0
      fi

      # Make sure the primary ESP is actually mounted and populated.
      if [ ! -d "$PRIMARY_SRC/EFI" ]; then
        echo "primary ESP $PRIMARY_SRC looks unpopulated (no EFI dir); aborting" >&2
        exit 1
      fi

      echo "Mounting backup ESP $BACKUP_DEV at $MNT"
      mount -t vfat "$BACKUP_DEV" "$MNT"

      echo "Replicating $PRIMARY_SRC -> $MNT"
      # --no-owner/--no-group: vfat has no ownership. --modify-window=2 for FAT's
      # 2-second timestamp granularity. --delete to drop stale generations.
      rsync -rtv --delete --no-owner --no-group --modify-window=2 \
        "$PRIMARY_SRC"/ "$MNT"/

      sync
      echo "Backup ESP replication complete."

      # Register / refresh a UEFI boot entry for the backup disk if firmware
      # variables are writable. Idempotent: remove any existing identically
      # labelled entry first, then recreate it.
      if [ -d /sys/firmware/efi/efivars ]; then
        LABEL="NixOS (backup ESP)"
        LOADER='\EFI\systemd\systemd-bootx64.efi'

        # efibootmgr lines look like:  Boot0000* NixOS (backup ESP)<TAB>HD(...)
        # Match the label literally (it contains regex-special chars) by
        # splitting on the tab, stripping the "BootXXXX* " prefix, and comparing
        # the remaining text to $LABEL exactly.
        existing="$(efibootmgr | awk -F'\t' -v lbl="$LABEL" '
          /^Boot[0-9A-Fa-f]{4}/ {
            id = substr($1, 5, 4)
            name = $1
            sub(/^Boot[0-9A-Fa-f]{4}\*? /, "", name)
            if (name == lbl) print id
          }' || true)"
        for id in $existing; do
          echo "Removing stale boot entry Boot$id ($LABEL)"
          efibootmgr -q -b "$id" -B || true
        done

        echo "Creating UEFI boot entry: $LABEL -> ${backupDisk}p${backupPartNum} $LOADER"
        efibootmgr -q -c \
          -d "${backupDisk}" \
          -p "${backupPartNum}" \
          -L "$LABEL" \
          -l "$LOADER" || echo "efibootmgr entry creation failed (non-fatal)" >&2
      else
        echo "efivars not available; skipping UEFI boot entry registration" >&2
      fi
    '';
  };
in
{
  environment.systemPackages = [
    pkgs.efibootmgr
    syncScript
  ];

  systemd.services.sync-backup-esp = {
    description = "Replicate primary EFI System Partition to the backup ESP";
    after = [ "boot.mount" ];
    requires = [ "boot.mount" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${syncScript}/bin/sync-backup-esp";
    };
  };

  # Fire the sync whenever systemd-boot rewrites the primary ESP, which happens
  # during `nixos-rebuild switch/boot`. Watching the loader entries directory
  # catches new/removed generations without relying on activation-script order.
  systemd.paths.sync-backup-esp = {
    description = "Watch primary ESP for changes and trigger backup replication";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "${espMountPoint}/loader/entries";
      Unit = "sync-backup-esp.service";
    };
  };

  # Periodic safety-net sync (also covers random-seed / entry-token drift).
  systemd.timers.sync-backup-esp = {
    description = "Periodic backup ESP replication";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1d";
      Persistent = true;
      Unit = "sync-backup-esp.service";
    };
  };
}

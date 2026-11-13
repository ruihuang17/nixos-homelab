# Health of the Pixel 4XL SMS bridge, read over USB adb from satsuma.
# A timer runs the collector every minute; it writes a textfile metric that
# node_exporter exposes. Alert rules live in monitoring.nix.
# See docs/SMS Matrix Bridge.md -> Monitoring.
{
  pkgs,
  ...
}:
let
  serial = "99161FFBA00921";
  stateDir = "/var/lib/sms-bridge-monitor";
  textfileDir = "/var/lib/prometheus-node-exporter-text";

  collector = pkgs.writeShellApplication {
    name = "sms-bridge-monitor";
    runtimeInputs = with pkgs; [
      android-tools
      coreutils
      gawk
    ];
    text = ''
      serial=${serial}
      out=${textfileDir}/sms_bridge.prom
      tmp="$(mktemp ${textfileDir}/.sms_bridge.prom.XXXXXX)"
      trap 'rm -f "$tmp"; adb kill-server >/dev/null 2>&1 || true' EXIT

      on_phone() { timeout 15 adb -s "$serial" shell "$@" | tr -d '\r'; }

      adb_up=0
      if timeout 20 adb -s "$serial" wait-for-device >/dev/null 2>&1 \
        && [ "$(adb -s "$serial" get-state 2>/dev/null)" = device ]; then
        adb_up=1
      fi

      {
        echo "# HELP sms_bridge_adb_up Whether the Pixel answers over adb (1 = authorized and online)."
        echo "# TYPE sms_bridge_adb_up gauge"
        echo "sms_bridge_adb_up $adb_up"

        if [ "$adb_up" = 1 ]; then
          echo "# HELP sms_bridge_process_up Whether a bridge process is running on the phone."
          echo "# TYPE sms_bridge_process_up gauge"
          for proc in com.beeper.sms.app libmautrix.so; do
            if on_phone pidof "$proc" >/dev/null; then up=1; else up=0; fi
            echo "sms_bridge_process_up{process=\"$proc\"} $up"
          done

          battery="$(on_phone dumpsys battery || true)"
          level="$(awk -F': *' '$1 ~ /^ *level$/ {print $2; exit}' <<<"$battery")"
          temp="$(awk -F': *' '$1 ~ /^ *temperature$/ {print $2 / 10; exit}' <<<"$battery")"
          if [ -n "$level" ]; then
            echo "# HELP sms_bridge_battery_level_percent Phone battery level."
            echo "# TYPE sms_bridge_battery_level_percent gauge"
            echo "sms_bridge_battery_level_percent $level"
          fi
          if [ -n "$temp" ]; then
            echo "# HELP sms_bridge_battery_temperature_celsius Phone battery temperature."
            echo "# TYPE sms_bridge_battery_temperature_celsius gauge"
            echo "sms_bridge_battery_temperature_celsius $temp"
          fi
        fi

        echo "# HELP sms_bridge_last_run_timestamp_seconds When the collector last finished."
        echo "# TYPE sms_bridge_last_run_timestamp_seconds gauge"
        echo "sms_bridge_last_run_timestamp_seconds $(date +%s)"
      } >"$tmp"

      chmod 0644 "$tmp"
      mv "$tmp" "$out"
    '';
  };
in
{
  users.groups.sms-monitor = { };
  users.users.sms-monitor = {
    isSystemUser = true;
    group = "sms-monitor";
    home = stateDir;
  };

  # Give the collector (and only it) access to this one phone's USB device.
  # Also keep the port awake: a runtime-suspended port (powertop/TLP autosuspend)
  # stops supplying charge current, so the phone drains while plugged in.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{serial}=="${serial}", GROUP="sms-monitor", MODE="0660", ATTR{power/control}="on"
  '';

  # TLP's own udev hook would set the phone back to autosuspend on connect.
  # 4ee7 = adb, 4ee1 = no-debugging mode; the phone switches between them.
  services.tlp.settings.USB_DENYLIST = "18d1:4ee7 18d1:4ee1";

  # powertop --auto-tune at boot sets every USB device to autosuspend.
  powerManagement.powertop.postStart = ''
    for d in /sys/bus/usb/devices/*; do
      if [ "$(cat "$d/serial" 2>/dev/null)" = ${serial} ]; then
        echo on > "$d/power/control"
      fi
    done
  '';

  systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 sms-monitor sms-monitor -" ];

  services.prometheus.exporters.node.extraFlags = [
    "--collector.textfile.directory=${textfileDir}"
  ];

  systemd.services.sms-bridge-monitor = {
    description = "Collect SMS bridge phone health over adb";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${collector}/bin/sms-bridge-monitor";
      User = "sms-monitor";
      Group = "sms-monitor";
      # adb keeps its key in ~/.android; the phone authorizes this key once.
      Environment = [
        "HOME=${stateDir}"
        # Own adb server port, so it never shares a server with a root `adb`.
        "ANDROID_ADB_SERVER_PORT=5038"
      ];
      StateDirectory = "sms-bridge-monitor";
      StateDirectoryMode = "0700";
      ReadWritePaths = [ textfileDir ];
      TimeoutStartSec = "90s";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      DevicePolicy = "closed";
      DeviceAllow = [ "char-usb_device rw" ];
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
    };
  };

  systemd.timers.sms-bridge-monitor = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
    };
  };
}

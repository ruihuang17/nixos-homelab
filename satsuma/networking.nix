{ config, pkgs, ... }:
let
  # RTL8125B (2.5GbE) occasionally fails to re-establish carrier after the
  # upstream switch/gateway reboots. On 2026-11-01 the link stayed down for
  # 3h15m after the Cloud Gateway Fiber rebooted for a firmware update, and
  # only recovered when the host was physically power-cycled.
  #
  # This watchdog is deliberately cheap (no polling daemon, one short timer
  # wake per minute) and escalates only while carrier is missing:
  #   1. restart Ethernet autonegotiation (ethtool -r)
  #   2. bounce the interface
  #   3. reset the PCI function
  nic = "enp4s0";
  nicWatchdog = pkgs.writeShellApplication {
    name = "nic-carrier-watchdog";
    runtimeInputs = with pkgs; [
      coreutils
      ethtool
      iproute2
      util-linux
    ];
    text = ''
      set -uo pipefail

      STATE_DIR=/run/nic-carrier-watchdog
      mkdir -p "$STATE_DIR"

      carrier() {
        cat "/sys/class/net/${nic}/carrier" 2>/dev/null || echo 0
      }

      if [ "$(carrier)" = "1" ]; then
        rm -f "$STATE_DIR/failures"
        exit 0
      fi

      failures=$(( $(cat "$STATE_DIR/failures" 2>/dev/null || echo 0) + 1 ))
      echo "$failures" > "$STATE_DIR/failures"

      # Require two consecutive misses (~2 min) so a normal gateway reboot
      # does not trigger an immediate reset.
      [ "$failures" -ge 2 ] || exit 0

      logger -t nic-carrier-watchdog "no carrier on ${nic} for $failures checks; restarting autonegotiation"
      ethtool -r ${nic} || true
      sleep 10

      if [ "$(carrier)" = "0" ]; then
        logger -t nic-carrier-watchdog "still no carrier; bouncing ${nic}"
        ip link set ${nic} down || true
        sleep 2
        ip link set ${nic} up || true
        sleep 10
      fi

      if [ "$(carrier)" = "0" ]; then
        logger -t nic-carrier-watchdog "still no carrier; resetting PCI function 0000:04:00.0"
        echo 1 > /sys/bus/pci/devices/0000:04:00.0/reset || true
        sleep 10
      fi

      if [ "$(carrier)" = "1" ]; then
        logger -t nic-carrier-watchdog "${nic} carrier restored"
        rm -f "$STATE_DIR/failures"
      else
        logger -t nic-carrier-watchdog "${nic} still has no carrier; backing off"
        # Do not hammer a rebooting gateway: wait for two more checks before
        # escalating again.
        echo 0 > "$STATE_DIR/failures"
      fi
    '';
  };
in
{
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    nssmdns6 = true;
    openFirewall = true;
  };

  networking = {

    useNetworkd = true;
    nftables.enable = true;
    dhcpcd.enable = false;

    hostName = "satsuma";
    hostId = "af300f15";
    nameservers = [ "127.0.0.1" ];

    hosts = {
      "127.0.0.1" = [
        "nextcloud.estrogenuinely.ca"
        "collabora.estrogenuinely.ca"
        "idm.estrogenuinely.ca"
      ];
      "::1" = [
        "nextcloud.estrogenuinely.ca"
        "collabora.estrogenuinely.ca"
        "idm.estrogenuinely.ca"
      ];
    };

    firewall = {
      allowedTCPPorts = [
        25
        80
        111
        443
        1313
        2049
        20048
      ];
      trustedInterfaces = [ config.services.tailscale.interfaceName ];
      allowedUDPPorts = [ config.services.tailscale.port 111 20048 ];
      checkReversePath = "loose";
    };
  };

  systemd.services.nic-carrier-watchdog = {
    description = "Recover ${nic} when the 2.5GbE link gets stuck without carrier";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${nicWatchdog}/bin/nic-carrier-watchdog";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.nic-carrier-watchdog = {
    description = "Check ${nic} carrier every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "60s";
      AccuracySec = "5s";
    };
  };
}

{
  config,
  pkgs,
  lib,
  ...
}:
let
  vpnNamespace = "torrent-vpn";
  piaRegion = "ca_toronto";
  # piaUsername / piaPassword are no longer plain strings - see age.secrets below

  qbtWebUIUser = "admin"; # username isn't sensitive; keep as plain string if you like

  downloadDir = "/hdd/mediaSrv/torrent";

  vethHost = "veth-host";
  vethVpn = "veth-vpn";
  hostVethIP = "10.200.200.1";
  vpnVethIP = "10.200.200.2";
  vethPrefix = "24";

  qbtWebUIPort = 8080;
  qbtProfileDir = "/var/lib/qbittorrent";
  # With --profile=<dir>, qBittorrent's config lands here:
  qbtConfPath = "${qbtProfileDir}/qBittorrent/config/qBittorrent.conf";

  wgConfPath = "/etc/wireguard/pia.conf";

  piaCaCert = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt";
    sha256 = "sha256-Mumx0UM+qXYU8qFMbjWOP1fAVwzJ9rLugSaZumlsZqs="; # already pinned from before
  };
in
{
  # -----------------------------------------------------------------------
  # agenix secrets
  # -----------------------------------------------------------------------
  age.secrets = {
    pia-username.file = ../secrets/pia-username.age; 
    pia-password.file = ../secrets/pia-password.age;
    qbittorrent-password.file = ../secrets/qbittorrent-password.age;
  };

  environment.systemPackages = with pkgs; [
    iproute2
    wireguard-tools
    curl
    jq
    openssl
    python3
  ];

  # -----------------------------------------------------------------------
  # 1. Generate PIA's WireGuard config, reading creds from agenix secrets
  # -----------------------------------------------------------------------
  systemd.services.pia-wg-config = {
    description = "Generate PIA WireGuard configuration";
    before = [ "pia-vpn.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pia-wg-config-gen" ''
        set -euo pipefail
        umask 077

        PIA_USER=$(cat ${config.age.secrets.pia-username.path})
        PIA_PASS=$(cat ${config.age.secrets.pia-password.path})

        SERVERLIST=$(${pkgs.curl}/bin/curl -s \
          --connect-timeout 10 --max-time 30 \
          --retry 5 --retry-delay 3 --retry-all-errors \
          "https://serverlist.piaservers.net/vpninfo/servers/v6" | head -1)
        WG_SERVER_IP=$(echo "$SERVERLIST" | ${pkgs.jq}/bin/jq -r --arg region "${piaRegion}" \
          '.regions[] | select(.id == $region) | .servers.wg[0].ip')
        WG_SERVER_CN=$(echo "$SERVERLIST" | ${pkgs.jq}/bin/jq -r --arg region "${piaRegion}" \
          '.regions[] | select(.id == $region) | .servers.wg[0].cn')
        PORT_FORWARD=$(echo "$SERVERLIST" | ${pkgs.jq}/bin/jq -r --arg region "${piaRegion}" \
          '.regions[] | select(.id == $region) | .port_forward')

        if [ -z "$WG_SERVER_IP" ] || [ "$WG_SERVER_IP" == "null" ]; then
          echo "Could not find a WireGuard server for region ${piaRegion}" >&2
          exit 1
        fi
        if [ "$PORT_FORWARD" != "true" ]; then
          echo "WARNING: region ${piaRegion} does not support port forwarding" >&2
        fi

        TOKEN_JSON=$(${pkgs.curl}/bin/curl -s \
          --connect-timeout 10 --max-time 30 \
          --retry 5 --retry-delay 3 --retry-all-errors \
          --location --request POST \
          "https://www.privateinternetaccess.com/api/client/v2/token" \
          --form "username=$PIA_USER" \
          --form "password=$PIA_PASS")

        PIA_TOKEN=$(echo "$TOKEN_JSON" | ${pkgs.jq}/bin/jq -r '.token // empty' 2>/dev/null)

        if [ -z "$PIA_TOKEN" ] || [ "$PIA_TOKEN" == "null" ]; then
          echo "PIA token request failed. Raw response was:" >&2
          echo "$TOKEN_JSON" >&2
          exit 1
        fi

        PRIVATE_KEY=$(${pkgs.wireguard-tools}/bin/wg genkey)
        PUBLIC_KEY=$(echo "$PRIVATE_KEY" | ${pkgs.wireguard-tools}/bin/wg pubkey)

        WG_JSON=$(${pkgs.curl}/bin/curl -s -G \
          --connect-timeout 10 --max-time 30 \
          --retry 5 --retry-delay 3 --retry-all-errors \
          --connect-to "$WG_SERVER_CN::$WG_SERVER_IP:" \
          --cacert "${piaCaCert}" \
          --data-urlencode "pt=$PIA_TOKEN" \
          --data-urlencode "pubkey=$PUBLIC_KEY" \
          "https://$WG_SERVER_CN:1337/addKey")

        STATUS=$(echo "$WG_JSON" | ${pkgs.jq}/bin/jq -r '.status')
        if [ "$STATUS" != "OK" ]; then
          echo "PIA addKey failed: $WG_JSON" >&2
          exit 1
        fi

        SERVER_KEY=$(echo "$WG_JSON" | ${pkgs.jq}/bin/jq -r '.server_key')
        SERVER_PORT=$(echo "$WG_JSON" | ${pkgs.jq}/bin/jq -r '.server_port')
        PEER_IP=$(echo "$WG_JSON" | ${pkgs.jq}/bin/jq -r '.peer_ip')
        DNS_SERVER=$(echo "$WG_JSON" | ${pkgs.jq}/bin/jq -r '.dns_servers[0]')

        install -d -m 0700 /etc/wireguard
        cat > "${wgConfPath}" <<EOF
        [Interface]
        PrivateKey = $PRIVATE_KEY
        Address = $PEER_IP/32
        DNS = $DNS_SERVER

        [Peer]
        PublicKey = $SERVER_KEY
        Endpoint = $WG_SERVER_IP:$SERVER_PORT
        AllowedIPs = 0.0.0.0/0
        PersistentKeepalive = 25
        EOF
        chmod 0600 "${wgConfPath}"

        echo "$WG_SERVER_IP" > /etc/wireguard/pia_gateway.txt
        echo "$PIA_TOKEN"   > /etc/wireguard/pia_token.txt
        chmod 0600 /etc/wireguard/pia_gateway.txt /etc/wireguard/pia_token.txt
      '';
    };
  };

  # -----------------------------------------------------------------------
  # 2. VPN namespace + veth bridge
    # -----------------------------------------------------------------------
  systemd.services.pia-vpn = {
    description = "PIA WireGuard VPN Network Namespace";
    after = [
      "network-online.target"
      "pia-wg-config.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "pia-wg-config.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "pia-vpn-up" ''
        set -e

        ${pkgs.iproute2}/bin/ip netns del ${vpnNamespace} 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip link del ${vethHost} 2>/dev/null || true

        ${pkgs.iproute2}/bin/ip netns add ${vpnNamespace}
        ${pkgs.iproute2}/bin/ip -n ${vpnNamespace} link set lo up

        ${pkgs.iproute2}/bin/ip link add ${vethHost} type veth peer name ${vethVpn}
        ${pkgs.iproute2}/bin/ip link set ${vethVpn} netns ${vpnNamespace}

        ${pkgs.iproute2}/bin/ip addr add ${hostVethIP}/${vethPrefix} dev ${vethHost}
        ${pkgs.iproute2}/bin/ip link set ${vethHost} up

        ${pkgs.iproute2}/bin/ip -n ${vpnNamespace} addr add ${vpnVethIP}/${vethPrefix} dev ${vethVpn}
        ${pkgs.iproute2}/bin/ip -n ${vpnNamespace} link set ${vethVpn} up

        ${pkgs.iproute2}/bin/ip link add wg0 type wireguard
        ${pkgs.iproute2}/bin/ip link set wg0 netns ${vpnNamespace}

        ${pkgs.gnugrep}/bin/grep -vE '^(Address|DNS)\s*=' ${wgConfPath} \
          > /run/wireguard-pia-stripped.conf

        ${pkgs.iproute2}/bin/ip netns exec ${vpnNamespace} \
          ${pkgs.wireguard-tools}/bin/wg setconf wg0 /run/wireguard-pia-stripped.conf
        rm -f /run/wireguard-pia-stripped.conf

        WG_ADDR=$(${pkgs.gnugrep}/bin/grep -oP '(?<=Address = ).*' ${wgConfPath})
        ${pkgs.iproute2}/bin/ip -n ${vpnNamespace} addr add "$WG_ADDR" dev wg0
        ${pkgs.iproute2}/bin/ip -n ${vpnNamespace} link set wg0 up

        ${pkgs.iproute2}/bin/ip -n ${vpnNamespace} route add default dev wg0
      '';
      ExecStop = pkgs.writeShellScript "pia-vpn-down" ''
        ${pkgs.iproute2}/bin/ip netns del ${vpnNamespace} || true
        ${pkgs.iproute2}/bin/ip link del ${vethHost} 2>/dev/null || true
        rm -f ${wgConfPath}
      '';
    };
  };

  # -----------------------------------------------------------------------
  # 3. qBittorrent
  # -----------------------------------------------------------------------
  systemd.tmpfiles.rules = [
    "d ${downloadDir} 0770 qbittorrent qbittorrent -"
  ];

  systemd.services.qbittorrent = {
    description = "qBittorrent Client Confinement";
    after = [ "pia-vpn.service" ];
    requires = [ "pia-vpn.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      # The "+" prefix runs this ExecStartPre as root regardless of the
      # service's User=, so it can read the root-only agenix secret and
      # write into qBittorrent's config directory before dropping to the
      # qbittorrent user for the actual daemon.
      ExecStartPre = "+${pkgs.writeShellScript "qbt-set-password" ''
                set -euo pipefail
                install -d -m 0750 -o qbittorrent -g qbittorrent "$(dirname ${qbtConfPath})"

                ${pkgs.python3}/bin/python3 - <<'PYEOF'
        import base64, hashlib, os, re

        with open("${config.age.secrets.qbittorrent-password.path}") as f:
            password = f.read().strip()

        salt = os.urandom(16)
        dk = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, 100000)
        salt_b64 = base64.b64encode(salt).decode()
        hash_b64 = base64.b64encode(dk).decode()
        pbkdf2_line = f'WebUI\\Password_PBKDF2="@ByteArray({salt_b64}:{hash_b64})"'

        conf_path = "${qbtConfPath}"
        lines = []
        if os.path.exists(conf_path):
            with open(conf_path) as f:
                lines = f.readlines()

        lines = [l for l in lines if not l.startswith("WebUI\\Password_PBKDF2")
                                  and not l.startswith("WebUI\\Username")]
        if not any(l.strip() == "[Preferences]" for l in lines):
            lines.insert(0, "[Preferences]\n")

        insert_at = next(i for i, l in enumerate(lines) if l.strip() == "[Preferences]") + 1
        lines.insert(insert_at, f'WebUI\\Username={"${qbtWebUIUser}"}\n')
        lines.insert(insert_at + 1, pbkdf2_line + "\n")

        with open(conf_path, "w") as f:
            f.writelines(lines)
        PYEOF

                chown qbittorrent:qbittorrent ${qbtConfPath}
                chmod 0640 ${qbtConfPath}
      ''}";

      ExecStart = ''
        ${pkgs.qbittorrent-nox}/bin/qbittorrent-nox \
          --webui-port=${toString qbtWebUIPort} \
          --profile=${qbtProfileDir}
      '';
      User = "qbittorrent";
      Group = "qbittorrent";

      NetworkNamespacePath = "/var/run/netns/${vpnNamespace}";

      StateDirectory = "qbittorrent";
      WorkingDirectory = qbtProfileDir;

      ReadWritePaths = [ downloadDir ];
      UMask = "0002";
    };
  };

  users.users.qbittorrent = {
    isSystemUser = true;
    group = "qbittorrent";
    extraGroups = [ "media" ];
    home = qbtProfileDir;
    createHome = true;
  };
  users.groups.qbittorrent = { };

  # -----------------------------------------------------------------------
  # 4. Sync PIA's forwarded port
  # -----------------------------------------------------------------------
  systemd.services.pia-port-forwarder = {
    description = "Sync PIA dynamic port forwarding with qBittorrent Web API";
    after = [ "qbittorrent.service" ];
    requires = [ "qbittorrent.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      NetworkNamespacePath = "/var/run/netns/${vpnNamespace}";
      ExecStart = pkgs.writeShellScript "pia-sync-port" ''
        GATEWAY=$(cat /etc/wireguard/pia_gateway.txt)
        TOKEN=$(cat /etc/wireguard/pia_token.txt)

        while true; do
          SIG_PAYLOAD_RESP=$(${pkgs.curl}/bin/curl -s -m 5 -G \
            --connect-to "::$GATEWAY:" \
            --cacert "${piaCaCert}" \
            --data-urlencode "token=$TOKEN" \
            "https://$GATEWAY:19999/getSignature")

          PAYLOAD=$(echo "$SIG_PAYLOAD_RESP" | ${pkgs.jq}/bin/jq -r '.payload')
          SIGNATURE=$(echo "$SIG_PAYLOAD_RESP" | ${pkgs.jq}/bin/jq -r '.signature')
          PIA_PORT=$(echo "$PAYLOAD" | ${pkgs.coreutils}/bin/base64 -d | ${pkgs.jq}/bin/jq -r '.port')

          if [ -n "$PIA_PORT" ] && [ "$PIA_PORT" != "null" ]; then
            ${pkgs.curl}/bin/curl -s -m 5 -G \
              --connect-to "::$GATEWAY:" \
              --cacert "${piaCaCert}" \
              --data-urlencode "payload=$PAYLOAD" \
              --data-urlencode "signature=$SIGNATURE" \
              "https://$GATEWAY:19999/bindPort" >/dev/null

            ${pkgs.curl}/bin/curl -s -X POST "http://localhost:${toString qbtWebUIPort}/api/v2/app/setPreferences" \
              --data-urlencode "json={\"listen_port\": $PIA_PORT}"
          fi

          sleep 900
        done
      '';
    };
  };

  # -----------------------------------------------------------------------
  # 5. nginx reverse proxy
  # -----------------------------------------------------------------------
  services.nginx = {
    enable = true;
    virtualHosts."qbittorrent.local.ruihuang.io" = {
      useACMEHost = "ruihuang.io";
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://${vpnVethIP}:${toString qbtWebUIPort}";
        extraConfig = ''
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };
    };
  };

}

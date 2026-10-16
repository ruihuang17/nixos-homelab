{
  config,
  pkgs,
  lib,
  ...
}:
let
  # The homelab-alerts Matrix room (created with the homelab-alertbot user).
  # NB: this Synapse returns the room ID without a ":server" suffix; use the
  # exact value from `/_matrix/client/v3/joined_rooms`.
  alertRoomId = "!k9Y9GnXSOfor4J0h6PqDJWBfSyCw889EYbcbbXyUAVs";
  receiverPort = 9686;

  # Config for metio/matrix-alertmanager-receiver. The access token is read
  # from the environment (${MATRIX_ACCESS_TOKEN}) which systemd loads from an
  # agenix-decrypted EnvironmentFile, so it never lands in the Nix store.
  receiverConfig = pkgs.writeText "matrix-alertmanager-receiver.yaml" ''
    http:
      address: 127.0.0.1
      port: ${toString receiverPort}
      alerts-path-prefix: /alerts
      metrics-enabled: false
    matrix:
      homeserver-url: http://127.0.0.1:8008
      user-id: "@homelab-alertbot:estrogenuinely.ca"
      access-token: "''${MATRIX_ACCESS_TOKEN}"
      room-mapping:
        homelab: "${alertRoomId}"
    templating:
      generator-url-mapping:
        "http://127.0.0.1:9090": https://prometheus.local.estrogenuinely.ca
      firing-template: |
        🔥 FIRING: {{ .Alert.Labels.alertname }}{{ if .Alert.Labels.instance }} on {{ .Alert.Labels.instance }}{{ end }}
        {{ if .Alert.Annotations.summary }}{{ .Alert.Annotations.summary }}{{ end }}
        {{ if .Alert.Annotations.description }}{{ .Alert.Annotations.description }}{{ end }}
      resolved-template: |
        ✅ RESOLVED: {{ .Alert.Labels.alertname }}{{ if .Alert.Labels.instance }} on {{ .Alert.Labels.instance }}{{ end }}
  '';
in
{
  # Bot access token for the Matrix receiver, injected via EnvironmentFile.
  age.secrets.matrix_alertbot_token = {
    file = "/etc/nixos/satsuma/secrets/matrix_alertbot_token.age";
    mode = "400";
    # owned by the receiver's dynamic user is not possible; read as root in
    # the unit's EnvironmentFile before privileges drop. Keep 400 root.
  };

  systemd.services.matrix-alertmanager-receiver = {
    description = "Grafana/Alertmanager -> Matrix webhook receiver (homelab-alerts)";
    after = [
      "network-online.target"
      "matrix-synapse.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.matrix-alertmanager-receiver}/bin/matrix-alertmanager-receiver -config-path ${receiverConfig}";
      EnvironmentFile = config.age.secrets.matrix_alertbot_token.path;
      Restart = "on-failure";
      RestartSec = "5s";

      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
      ];
      SystemCallArchitectures = "native";
    };
  };
}

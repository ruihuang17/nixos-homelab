{
  config,
  pkgs,
  lib,
  ...
}:
let
  satsumaTsIp = "100.72.25.50"; # satsuma's Tailscale IPv4
  alertTo = "rui@estrogenuinely.ca";
  alertFrom = "alerts@estrogenuinely.ca";
  # How many consecutive failed probes before we declare satsuma down.
  failThreshold = 3;

  # Standalone mailer: reads subject/body/creds from the environment and sends
  # directly through AWS SES (STARTTLS + SASL), NOT through the local Stalwart.
  #
  # This is deliberate: Stalwart authenticates users against Kanidm, which runs
  # on satsuma. Using Stalwart as the relay created a circular dependency - when
  # satsuma was down, LDAP auth timed out and every watcher email failed with
  # "SMTPServerDisconnected" (observed 2026-10-29). SES has no dependency on
  # the homelab, so the dead-man's-switch can actually fire.
  mailer = pkgs.writers.writePython3 "satsuma-watcher-mailer" { } ''
    import os
    import smtplib
    import ssl
    from email.message import EmailMessage

    msg = EmailMessage()
    msg["Subject"] = os.environ["MAIL_SUBJECT"]
    msg["From"] = os.environ["MAIL_FROM"]
    msg["To"] = os.environ["MAIL_TO"]
    msg.set_content(os.environ["MAIL_BODY"])

    ctx = ssl.create_default_context()
    with smtplib.SMTP("email-smtp.us-east-2.amazonaws.com", 587, timeout=20) as s:
        s.starttls(context=ctx)
        s.login(os.environ["SMTP_USER"], os.environ["SMTP_PASS"])
        s.send_message(msg)
    print("mail sent")
  '';

  watcher = pkgs.writeShellApplication {
    name = "satsuma-watcher";
    runtimeInputs = [
      pkgs.tailscale
      pkgs.coreutils
    ];
    text = ''
      set -uo pipefail
      STATE_DIR=/var/lib/satsuma-watcher
      mkdir -p "$STATE_DIR"
      FAIL_FILE="$STATE_DIR/fail_count"
      DOWN_FILE="$STATE_DIR/is_down"
      [ -f "$FAIL_FILE" ] || echo 0 > "$FAIL_FILE"

      # SES SMTP credentials are injected by systemd as credentials, so they
      # never appear in the process environment or the Nix store.
      CRED_DIR="''${CREDENTIALS_DIRECTORY:-/run/credentials/satsuma-watcher.service}"

      # Liveness probe: tailscale ping (satsuma's node_exporter is loopback-only,
      # so we check host reachability over the tailnet instead).
      if tailscale ping -c 2 --timeout 5s ${satsumaTsIp} >/dev/null 2>&1; then
        OK=1
      else
        OK=0
      fi

      send_mail() {
        # $1 = subject, $2 = body
        SMTP_USER="$(cat "$CRED_DIR/ses_user")" \
        SMTP_PASS="$(cat "$CRED_DIR/ses_pass")" \
        MAIL_SUBJECT="$1" MAIL_BODY="$2" \
        MAIL_FROM="${alertFrom}" MAIL_TO="${alertTo}" \
          ${mailer}
      }

      NOW="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
      if [ "$OK" -eq 1 ]; then
        # Recovered?
        if [ -f "$DOWN_FILE" ]; then
          send_mail "[homelab] RESOLVED: satsuma is back up" \
            "satsuma is reachable again over the tailnet at $NOW." || true
          rm -f "$DOWN_FILE"
        fi
        echo 0 > "$FAIL_FILE"
      else
        C="$(cat "$FAIL_FILE" 2>/dev/null || echo 0)"
        C=$((C + 1))
        echo "$C" > "$FAIL_FILE"
        if [ "$C" -ge ${toString failThreshold} ] && [ ! -f "$DOWN_FILE" ]; then
          send_mail "[homelab] FIRING: satsuma is DOWN" \
            "The VPS watcher could not reach satsuma over the tailnet for $C consecutive checks (last at $NOW). satsuma hosts Grafana, Synapse and Postfix, so this email - sent directly through SES - is the only independent alert path when satsuma is down." && touch "$DOWN_FILE" || true
        fi
      fi
    '';
  };
in
{
  systemd.services.satsuma-watcher = {
    description = "Dead-man's-switch: alert by email when satsuma is unreachable";
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${watcher}/bin/satsuma-watcher";
      # SES credentials, exposed as systemd credentials rather than env vars.
      # The service still runs as root, but the secret values are only readable
      # from /run/credentials/satsuma-watcher.service/.
      LoadCredential = [
        "ses_user:${config.age.secrets.ses_smtp_user.path}"
        "ses_pass:${config.age.secrets.ses_smtp_pass.path}"
      ];
      StateDirectory = "satsuma-watcher";
      DynamicUser = false;
    };
  };

  systemd.timers.satsuma-watcher = {
    description = "Run the satsuma dead-man's-switch watcher every 2 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "2min";
      AccuracySec = "20s";
    };
  };
}

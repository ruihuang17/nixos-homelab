{ config, lib, ... }:

{
  # Kanidm OAuth2 client secret for the "nextcloud" client (decrypted at runtime,
  # never placed in the world-readable nix store).
  age.secrets.nextcloud_oidc_secret.file = "/etc/nixos/satsuma/secrets/nextcloud_oidc_secret.age";

  systemd.services.nextcloud-config-collabora =
    let
      inherit (config.services.nextcloud) occ;

      wopi_url = "http://[::1]:${toString config.services.collabora-online.port}";
      public_wopi_url = "https://collabora.estrogenuinely.ca";
      wopi_allowlist = lib.concatStringsSep "," [
        "127.0.0.1"
        "::1"
      ];
    in
    {
      wantedBy = [ "multi-user.target" ];
      after = [
        "nextcloud-setup.service"
        "coolwsd.service"
      ];
      requires = [ "coolwsd.service" ];
      script = ''
        ${occ}/bin/nextcloud-occ config:app:set richdocuments wopi_url --value ${lib.escapeShellArg wopi_url}
        ${occ}/bin/nextcloud-occ config:app:set richdocuments public_wopi_url --value ${lib.escapeShellArg public_wopi_url}
        ${occ}/bin/nextcloud-occ config:app:set richdocuments wopi_allowlist --value ${lib.escapeShellArg wopi_allowlist}
        ${occ}/bin/nextcloud-occ richdocuments:setup
        ${occ}/bin/nextcloud-occ user_oidc:provider Kanidm --clientid="nextcloud" --clientsecret="$(cat ${config.age.secrets.nextcloud_oidc_secret.path})" --discoveryuri="https://idm.estrogenuinely.ca/oauth2/openid/nextcloud/.well-known/openid-configuration" --mapping-email=email --mapping-uid=preferred_username --mapping-display-name=name 
      '';
      serviceConfig = {
        Type = "oneshot";
      };
    };
}

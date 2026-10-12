let
  satsuma = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMp74d/OCwnetejX24slNj+6kIiEmarYX8j8+Zuku8IF";
  rhuang = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH";
  common = [
    satsuma
    rhuang
  ];
in
{
  "cloudflare_api.age".publicKeys = common;
  "mail_pass.age".publicKeys = common;
  "nextcloud_admin_pass.age".publicKeys = common;
  "paperless_admin_pass.age".publicKeys = common;
  "postfix_sasl.age".publicKeys = common;
  "pia-username.age".publicKeys = common;
  "pia-password.age".publicKeys = common;
  "qbittorrent-password.age".publicKeys = common;
  "vaultwarden_token.age".publicKeys = common;
  "matrix_oidc.age".publicKeys = common;
  "nextcloud_oidc_secret.age".publicKeys = common;
  "restic_postgres_password.age".publicKeys = common;
}

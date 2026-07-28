let
  satsuma = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMp74d/OCwnetejX24slNj+6kIiEmarYX8j8+Zuku8IF root@smol-nix";
in
{
  "cloudflare_api.age".publicKeys = [ satsuma ];
  "mail_pass.age".publicKeys = [ satsuma ];
  "nextcloud_admin_pass.age".publicKeys = [ satsuma ];
  "paperless_admin_pass.age".publicKeys = [ satsuma ];
  "postfix_sasl.age".publicKeys = [ satsuma ];
  "pia-username.age".publicKeys = [ satsuma ];
  "pia-password.age".publicKeys = [ satsuma ];
  "qbittorrent-password.age".publicKeys = [ satsuma ];
}

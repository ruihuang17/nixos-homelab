let
  rhuang = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH";
  common = [ rhuang ];
in
{
  "cloudflare_api.age".publicKeys = common;
}

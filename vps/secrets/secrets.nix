let
  vps-host = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBGkF5aWM2D0nhzl0jYCzzb+ZQ3wKOWK+D4XzWv7Rl9L"; 
  rhuang = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH";
  common = [ vps-host rhuang ];
in
{
  "cloudflare_api.age".publicKeys = common;
}

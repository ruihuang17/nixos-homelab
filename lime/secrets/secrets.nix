let
  lime = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILaw3sOfI411ube2/935CyviZLe5Iril09jg/dHNnX9n";
  rhuang = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq4XsRorOLo7URBB1krIzhJi/ODqjUtD345D/DUrEkH";
in
{
  "imessage-config.age".publicKeys = [
    lime
    rhuang
  ];
}

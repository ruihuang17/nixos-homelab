{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:

{
  users.users.lena = {
    uid = 1001;
    isNormalUser = true;
    shell = pkgs.fish;
    extraGroups = [
      "wheel"
      "media"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICw7CHZkiNoG7StuF3NBnCHRWvsujJdX4ZTDIhz6YonH"
    ];
    home.packages = with pkgs; [
      helix
      ripgrep
  };

}

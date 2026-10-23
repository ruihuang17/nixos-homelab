{
  config,
  inputs,
  pkgs,
  ...
}:

{
  imports = [ inputs.hermes-agent.nixosModules.default ];

  age.secrets.hermes-env = {
    file = ./secrets/hermes-env.age;
    mode = "0400";
    owner = "hermes";
    group = "hermes";
  };

  services.hermes-agent = {
    enable = true;

    settings = {
      model.default = "deepseek/deepseek-v4.1-flash-1017";
      toolsets = [ "all" ];
      terminal = {
        backend = "local";
        timeout = 180;
      };
      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
      };
    };

    environmentFiles = [ config.age.secrets.hermes-env.path ];
    addToSystemPackages = true;
    extraPackages = [ pkgs.nix ];
  };

  users.users.rhuang.extraGroups = [ "hermes" ];
}

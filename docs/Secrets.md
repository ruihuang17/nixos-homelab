## agenix

Editing/creating age secrets
```bash
EDITOR=vim agenix -e secret.age -i /etc/ssh/ssh_host_ed25519_key
```

Add secret to a NixOS module config:

```nix
{
  age.secrets.secret1.file = ../secrets/secret1.age;
}
```

Reference the secrets' mount path in your config:

```nix
{
  users.users.user1 = {
    isNormalUser = true;
    hashedPasswordFile = config.age.secrets.secret1.path;
  };
}
```


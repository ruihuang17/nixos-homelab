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

## Matrix appservice secrets

The bridge tokens are never stored in plaintext. Each is decrypted to
`/run/agenix/<name>` at activation/boot:

| Secret (`satsuma/secrets/`) | Mount | Consumer |
| --- | --- | --- |
| `imessage-appservice.age` | `/run/agenix/imessage-appservice` | Synapse `app_service_config_files` |
| `sms-appservice.age` | `/run/agenix/sms-appservice` | Synapse `app_service_config_files` |
| `mautrix-wsproxy-config.age` | `/run/agenix/mautrix-wsproxy-config` | `mautrix-wsproxy -config` |

On **lime** (nix-darwin, `agenix.darwinModules.default`) the mautrix-imessage
config is `lime/secrets/imessage-config.age` → `/run/agenix/imessage-config`
(RAM disk, `rhuang:staff 0400`); see `docs/lime (macOS).md` for the edit/re-encrypt
workflow.


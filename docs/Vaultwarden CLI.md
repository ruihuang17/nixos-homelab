# Vaultwarden CLI (rbw)

`rbw` is the command-line client for our Vaultwarden
(`https://vaultwarden.estrogenuinely.ca`). It is installed on `pomelo`
(`pomelo/modules/packages.nix`, with `pinentry-qt`) and `satsuma`
(`satsuma/configuration.nix`, with `pinentry-curses`). It replaced the Bitwarden
MCP and the `bw` CLI; see [OpenCode](OpenCode.md).

## Setup

Per machine, once:

```bash
rbw config set base_url https://vaultwarden.estrogenuinely.ca
rbw config set email rui@estrogenuinely.ca
rbw config set pinentry pinentry-curses   # satsuma only; pomelo uses the default
rbw login                                 # master password via pinentry
```

`rbw` keeps its own agent, so it stays unlocked for `lock_timeout` (1 hour) and
re-prompts after that. `rbw sync` refreshes the local cache.

## Using it from an agent

Anything a tool returns is stored in the session transcript, so agents must not
print passwords, TOTP secrets, passkeys, notes, or custom fields. List with
non-secret fields only:

```bash
rbw list --fields name,user
rbw get --raw <item> | jq '{name, username: .data.username, uris: [.data.uris[]?.uri]}'
```

Never run `rbw get <item>` (it prints the password) or `rbw code` unless the
user asks for that specific value. This rule is also in `~/.claude/CLAUDE.md`.

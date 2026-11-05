# Refactor Plan (monoflake)

Drafted 2026-11-03, reshaped 2026-11-03 after a first attempt was reverted
(`1ca857f`, reverted in `f1f4ff1`). Applies to the `/etc/nixos` flake
(satsuma, bergamot, pomelo, lime).

> **Status: implemented 2026-11-04.** All nine phases landed. Root shared files
> went from 8 to 4 (`homelab.nix`, `common-nixos.nix`, `common-darwin.nix`,
> `server.nix`), `vps/` is now `bergamot/`, and kiro-gateway builds from our
> fork. `scripts/drvpaths.baseline` records the final state.
>
> Deviations from the plan as written:
>
> - Phase 4 changed satsuma's, bergamot's and lime's drvPaths after all: the
>   package list moved into `common-nixos.nix`, which reorders
>   `environment.systemPackages` and `systemd.tmpfiles.rules`. Every evaluated
>   option (users, groups, sshd, tailscale, node exporter, firewall, nix
>   settings, programs, package set, tmpfiles set, systemd unit names) is
>   identical; only the order inside those two lists moved.
> - Phase 9 uses three commits on the fork (the combined PR set, the 429 fix,
>   the fork README) rather than one commit per PR, because the combined patch
>   already carries the #288/#280 conflict resolution. The fork README maps
>   each commit to its PRs.
> - Phase 9 did not add an `envSecretFile` option: the module already declares
>   the secret, so the sync-creds script now reads
>   `config.age.secrets.kiro-gateway-env.path` directly. Same effect, no new
>   option.
>
> The first attempt moved hosts into `hosts/` and shared files into
> `modules/{shared,nixos,darwin}`, and added flake helpers (`overlays/`,
> `lib/mkNixos`, `nixosModules`, `checks`). Both were rejected: the layout churn
> and the flake abstraction were not worth it. This version keeps every
> directory where it is and keeps the shared files as plain, explicitly
> imported config files rather than composed role modules.

## Shape

- **One directory rename.** `vps/` becomes `bergamot/` (phase 3). `satsuma/`,
  `pomelo/`, `lime/` and the root-level shared files stay where they are.
- **Explicit imports.** If two hosts want the same settings, both list the same
  file in their own `imports`. No module arguments, no `mkIf`-switched role
  modules, no `_module.args`, no option re-exports.
- **Shared files are config, not framework.** A shared file is imported for its
  side effects; hosts override a value only when they must (e.g. `mkForce` for
  bergamot's sshd firewall).
- **No flake abstraction.** `flake.nix` keeps its three `nixosSystem` blocks
  plus darwin; no overlay, no `mkNixos`, no `nixosModules`, no `checks`.
  `scripts/drvpaths.sh` replaces `checks` for verification.

## Where things stood

- Four hosts: `satsuma` (server), `mail` (lives in `vps/`), `pomelo` (desktop),
  `lime` (nix-darwin). Plus `pkgs/`, `docs/`, `tofu/`.
- Eight shared files at the root: `common.nix`, `server-common.nix`, `lena.nix`,
  `dots.nix`, `dots-nixos.nix`, `dots-darwin.nix`, `starship.nix`,
  `ssh-hosts.nix`.

## Problems

1. **`common.nix` is not common.** It provisions Lena and turns Tailscale into a
   subnet router, so pomelo skips it and re-implements the rhuang user, SSH key,
   passwordless sudo, fish, nix-ld, `nix.optimise` and the git/gh/opencode
   packages.
2. **Settings defined more than once:**
   - `allowUnfree`: `nixosBase`, `common.nix`, `satsuma/configuration.nix`, lime.
   - `experimental-features`: `nixosBase` and lime.
   - the `storage` group / GID 3000: pomelo and lime.
   - rhuang's public key: `common.nix`, pomelo, and both `secrets.nix` files.
3. **IP addresses hardcoded in ~30 places** (nginx, monitoring, Hermes, lime's
   NFS map, pomelo's NFS mounts). `ssh-hosts.nix` already has a host table that
   nothing else uses.
4. **Secret paths inconsistent.** satsuma uses 21 absolute paths
   (`/etc/nixos/satsuma/secrets/*.age`); every other host uses `./secrets/...`.
   The absolute form reads the live working tree instead of the store and only
   works when the build runs on satsuma itself.
5. **`satsuma/configuration.nix` mixes** the ZFS kernel picker, power/TLP, HDD
   spin-down, `zfs-share` ordering, autoUpgrade + push hook, Grove and the
   gateway.
6. **pomelo's NFS mounts live in the generated `hardware-configuration.nix`.**
7. **Stale file:** `satsuma/core/tailscale.nix` is a comment-only no-op.

## Target layout

```
/etc/nixos
├── flake.nix          three nixosSystem blocks + darwin (unchanged shape)
├── homelab.nix   NEW  data only: addresses, ssh aliases, users + keys,
│                      storage GID, domain, dotfile map, starship path
├── common-nixos.nix  NEW  every NixOS host: nix settings, rhuang, sshd
│                      defaults, fish/starship/tmux/git, CLI packages,
│                      dotfile tmpfiles
├── common-darwin.nix NEW  lime: nix settings, starship, dotfile activation
│                      script, nerd font
├── server.nix    NEW  satsuma + bergamot only: Lena, root keys, subnet-router
│                      Tailscale, sshd openFirewall, node_exporter
├── dots/starship/starship.toml
├── pkgs/
├── docs/  tofu/
├── scripts/            deploy.sh, drvpaths.sh (+ baseline)
├── satsuma/            unchanged subtrees, plus
│   ├── system/{kernel,power,storage,auto-upgrade}.nix
│   └── monitoring/grove.nix
├── bergamot/           renamed from vps/ (networking.hostName stays "mail")
├── pomelo/             plus nfs.nix (the three NFS mounts)
└── lime/               configuration.nix only sets host identity + secrets
```

Deleted: `lena.nix`, `server-common.nix`, `ssh-hosts.nix`, `starship.nix`,
`dots.nix`, `dots-nixos.nix`, `dots-darwin.nix`. `common.nix` is renamed to
`common-nixos.nix`; `common-darwin.nix` is its macOS counterpart, so both
platforms have one shared entry point with the same shape.

Per-host imports:

| Host | Shared files |
| --- | --- |
| satsuma | `common-nixos.nix`, `server.nix` |
| bergamot (host `mail`) | `common-nixos.nix`, `server.nix` |
| pomelo | `common-nixos.nix` |
| lime | `common-darwin.nix` (which imports `homelab.nix`) |

`homelab.nix` is a plain attrset imported with `import ./homelab.nix`, not a
module: `nginx.nix`, `monitoring.nix`, `monitoring-overview.nix`, `hermes.nix`,
the ssh aliases in `common-nixos.nix`, lime's `auto_nas` and `pomelo/nfs.nix`
all read the same table.

## Phases

Each phase is one commit, verified before the next.

**Phase 1 — satsuma secret paths.** The 21 absolute paths become
`../secrets/...` (path literals, not strings: agenix requires an absolute path
and a path literal resolves correctly). Expected diff: only the `agenixInstall`
activation text for satsuma; `age.secrets.*.path` is unchanged.

**Phase 2 — `homelab.nix`.** Move `ssh-hosts.nix`'s host table, rhuang's and
Lena's uids/keys, the domain, the storage GID and the starship file path into
`homelab.nix`; keep generating the ssh alias block from it. Replace the
hardcoded addresses in `nginx.nix`, `monitoring.nix`,
`monitoring-overview.nix`, `hermes.nix`, lime's `auto_nas`, `pomelo/nfs.nix`
(phase 7) and the grove gateway URL. DrvPaths must not change.

**Phase 3 — rename `vps/` to `bergamot/`.** The repo name for the OVH VPS
becomes `bergamot`, after the other citrus hosts. `networking.hostName` stays
`"mail"` because the provider's reverse DNS fixes it, with a comment saying so;
`mail.estrogenuinely.ca`, the Stalwart config and the Tailscale device name do
not change. Steps:

- `git mv vps bergamot`, and update the path in `flake.nix`.
- `nixosConfigurations.mail` becomes `nixosConfigurations.bergamot`.
- The alias in `homelab.nix` becomes `bergamot`, and the generated ssh config
  follows. `satsuma/backup/postgres-backup.nix` (`knownHosts.mail`, `Host mail`)
  and the three `host = "mail"` entries in `monitoring-overview.nix` read the
  alias from `homelab.nix`.
- `labels.instance = "mail"` in `monitoring.nix` becomes `bergamot`. This starts
  a new Prometheus series, so the old `instance="mail"` history is no longer
  continuous. Decision: rename it, since the history is not worth a stale name.
- `scripts/drvpaths.sh`, `scripts/drvpaths.baseline` (labels only) and
  `scripts/deploy.sh` (host list; map `bergamot` to hostname `mail` for the
  "am I deploying myself" check).
- `README.md` and the docs that call the host `mail`.

Expected diff: the ssh config on every host (new alias), satsuma's Prometheus
config and the postgres-backup ssh stanza. The bergamot toplevel changes only
through the ssh alias. Gotcha: running `nixos-rebuild --flake .` on the VPS
itself would look for `#mail`, so use `--flake .#bergamot` there. Deploying from
satsuma is unaffected.

**Phase 4 — `common-nixos.nix` and `common-darwin.nix`.** Rename `common.nix`
to `common-nixos.nix`, remove Lena, root's keys, Tailscale and `openFirewall`,
move the CLI package list, git identity, tmux and the starship bits in, and emit
the dotfile tmpfiles rules directly from `homelab.dots` (drop the `dots`
option). Add `common-darwin.nix` with lime's half: Nix settings, starship, the
activation-script dotfile linking, the nerd font. Delete `dots.nix`,
`dots-nixos.nix`, `dots-darwin.nix`, `starship.nix`, `ssh-hosts.nix`. pomelo
imports `common-nixos.nix` and drops its duplicate user/sudo/fish/nix-ld blocks;
lime imports `common-darwin.nix` and drops its inline copies. DrvPaths must not
change.

**Phase 5 — `server.nix`.** `server-common.nix` + `lena.nix` + root's keys +
the Tailscale subnet-router block + `openFirewall = true`. Delete both old
files. satsuma and bergamot add it to their module lists in `flake.nix`. bergamot keeps
its `mkForce false`. DrvPaths must not change.

**Phase 6 — satsuma split.** `system/{kernel,power,storage,auto-upgrade}.nix`,
`monitoring/grove.nix`, and delete `satsuma/core/tailscale.nix`. DrvPaths must
not change.

**Phase 7 — pomelo.** Move the three NFS mounts from
`hardware-configuration.nix` to `pomelo/nfs.nix`, using `homelab.nix`. Then
`pomelo/configuration.nix` drops the duplicated rhuang/sudo/fish/ssh block and
the storage GID comes from `homelab.nix`.

**Phase 8 — dedupe and docs.** `allowUnfree` and `experimental-features` once
per platform (`common-nixos.nix`, `common-darwin.nix`); remove the duplicate
`allowUnfree` from `nixosBase`, `satsuma/configuration.nix` and lime's config.
Update `docs/*.md` and the layout section of `README.md` for the new file
names.

**Phase 9 — kiro-gateway fork.** Independent of phases 1–8; it can land before
or after them. Upstream (`jwadow/kiro-gateway`) is unmaintained and the package
carries 14 unmerged PRs as one combined diff plus a local 429 fix, which is hard
to review and refresh.

1. Fork `jwadow/kiro-gateway` to `ruihuang17/kiro-gateway`, branch `homelab`,
   based on upstream `a5292ca`.
2. Merge the 14 PRs listed in `pkgs/kiro-gateway/README.md` as individual
   commits. Reuse the existing resolution of the #288/#280 conflict in
   `kiro/streaming_openai.py`.
3. Add the `INSUFFICIENT_MODEL_CAPACITY` fix (`account-capacity-429.patch`) as
   its own commit.
4. Write the fork's README: purpose, branch policy, the carried PRs, the local
   commit, and that it stays AGPL-3.0.
5. In `pkgs/kiro-gateway/default.nix`, point `fetchFromGitHub` at the fork's
   commit, delete `patches = [ ... ]`, and delete `pkgs/kiro-gateway/patches/`.
   The Python environment, the tiktoken cache and the wrapper stay.
   `pkgs/kiro-gateway/README.md` shrinks to a pointer at the fork.
6. Remove `packages.kiro-gateway` from `flake.nix`. Nothing reads it; the
   module's `package` default is the only consumer.
7. In `satsuma/ai/kiro-gateway.nix`, add `services.kiro-gateway.envSecretFile`
   (default `null`) and use it in `kiro-gateway-sync-creds` instead of the
   hardcoded `/run/agenix/kiro-gateway-env`. `satsuma/configuration.nix`
   declares the agenix secret and passes its path in. The module stays in
   place and is not exported from the flake.

Checks: `nixos-rebuild build` for satsuma, `nvd diff` shows only the
kiro-gateway package and the sync script changing, then after the switch
`systemctl status kiro-gateway`, `sudo kiro-gateway-sync-creds`, and an
OpenCode request through the gateway. Refreshing later is
`git fetch upstream && git rebase upstream/main && git push`, then bump `rev` and
`hash` (`nix-prefetch-github ruihuang17 kiro-gateway --rev <sha>`).

## Verification

- `scripts/drvpaths.sh` before/after each phase. Phases 2 and 4–7 must leave
  every drvPath unchanged. Phase 1 changes only satsuma's activation text;
  phase 3 changes the ssh alias block and the satsuma monitoring/backup config
  (listed in phase 3).
- `nvd diff` between the old and new toplevel per host for the phases that
  legitimately change something (1: activation text only; 3: the renamed
  alias and Prometheus label only).
- `scripts/deploy.sh --build all` builds satsuma, bergamot and pomelo;
  `darwin-rebuild build` on lime (it cannot be built from satsuma).
- `nixfmt --check` on the changed files (the flake defines no `formatter`, so
  `nix fmt` is not available).

## Behaviour deltas to accept

- **pomelo** gains the shared CLI set (`kiro-cli`, `tmux`, `vim`, `nixfmt`,
  `tree`, `smartmontools`, `source-highlight`, `kitty.terminfo`, `agenix`).
- **bergamot** loses password and keyboard-interactive SSH auth; key auth unchanged.
- `time.timeZone` stays per host: bergamot runs UTC and its timers are relative.

## Out of scope

flake-parts, Home Manager, deploy-rs/colmena, overlays, `checks`, renaming
and any change to `tofu/`, including the `ovh_vps.mail` data source name. Package derivations are untouched except
`kiro-gateway` (phase 9). `scripts/deploy.sh` is plain `nixos-rebuild` and is
not part of the refactor.

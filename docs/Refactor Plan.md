# Refactor Plan (monoflake)

Drafted 2026-11-03. Applies to the `/etc/nixos` flake (satsuma, mail, pomelo, lime).

> **Status: reverted, under review.** A first attempt implemented phases 0–6 as
> committed in `1ca857f` and was reverted in `f1f4ff1` because the shape of the
> result was rejected. The tree is back to the pre-refactor state; every host's
> toplevel derivation matches `scripts/drvpaths.baseline` again. Nothing has been
> rebuilt or switched.
>
> What that attempt actually did, for the record:
> - Moved hosts to `hosts/` and shared modules to `modules/{shared,nixos,darwin}`,
>   plus `dots/` to `modules/shared/dots/`.
> - Split `common.nix` into `base.nix` (all NixOS hosts) and `server.nix`
>   (satsuma + mail). This disabled password SSH auth on `mail` and added the
>   shared CLI packages to pomelo.
> - Replaced hardcoded IPs with `inventory.nix` + a `homelab` module argument.
> - Made satsuma's agenix paths relative (decrypt from the store), which changed
>   its `agenixInstall` activation text but not `age.secrets.*.path`.
> - Added `overlays/`, `lib/mkNixos|mkDarwin`, `nixosModules.kiro-gateway` and
>   `checks`.
> - DrvPaths were byte-identical for all four hosts across every phase except
>   the agenix change above, so the mechanics were proven; the design is what
>   needs another pass.

The goal is to remove duplication, make the host entry points read as host
config only, and give the shared pieces (users, inventory, packages) one home.
No new framework: plain flake helpers, no flake-parts, no Home Manager.

## Where things stood

- Four hosts: `satsuma` (server), `mail` (lived in `vps/`), `pomelo` (desktop),
  `lime` (nix-darwin). Plus `pkgs/`, `docs/`, `tofu/`.
- The shared modules sat loose at the repo root: `common.nix`, `server-common.nix`,
  `lena.nix`, `dots.nix`, `dots-nixos.nix`, `dots-darwin.nix`, `starship.nix`,
  `ssh-hosts.nix`.

## Problems

1. **`common.nix` was not common.** It provisioned Lena and turned Tailscale into
   a subnet router, so pomelo skipped it and re-implemented the rhuang user, SSH
   key, passwordless sudo, fish, nix-ld, `nix.optimise` and the git/gh/opencode
   packages.
2. **Settings defined more than once:**
   - `allowUnfree`: `nixosBase`, `common.nix`, `satsuma/configuration.nix`, lime.
   - `experimental-features`: `nixosBase` and lime.
   - `time.timeZone`: three hosts.
   - the `storage` group / GID 3000: pomelo and lime.
   - rhuang's public key: `common.nix`, pomelo, and both `secrets.nix` files.
3. **IP addresses hardcoded in ~30 places** (nginx, monitoring, Hermes, lime's
   NFS map, pomelo's NFS mounts). `ssh-hosts.nix` already had a host table that
   nothing else used.
4. **Secret paths inconsistent.** satsuma used 22 absolute paths
   (`/etc/nixos/satsuma/secrets/*.age`); every other host used `./secrets/...`.
   The absolute form reads the live working tree instead of the store and only
   works when the build runs on satsuma itself.
5. **Packages reached three ways:** `inputs.self.packages` (opencode.nix),
   `callPackage ../../pkgs/...` inside the kiro-gateway module, and an inline
   overlay in `flake.nix`. The three `nixosSystem` blocks were near-identical.
   No `checks`, no `formatter`.
6. **Reusable modules buried in host config.** `satsuma/ai/kiro-gateway.nix`
   declares `options.services.kiro-gateway`, and `server-common.nix` declares
   `homelab.nodeExporter`, but neither is exposed as a module.
7. **`satsuma/configuration.nix` mixed** the ZFS kernel picker, power/TLP, HDD
   spin-down, `zfs-share` ordering, autoUpgrade + push hook, Grove and gateway.
8. **Directory names did not match host names** (`vps/` built `mail`).

## Target layout

```
flake.nix
inventory.nix   hosts: LAN/tailnet IPs, ssh user/port; users + keys; storage GID
lib/            mkNixos / mkDarwin helpers, inventory loader
overlays/       default.nix (pkgs/* + the opencode completion fix)
pkgs/           unchanged
modules/
  shared/       works on NixOS and darwin: nix settings, dots, starship, ssh-hosts
  nixos/
    base.nix      every NixOS host: users, sshd, nix settings, shared CLI
    server.nix    Lena, subnet-router Tailscale, sshd openFirewall, node_exporter
    dots.nix      tmpfiles backend for dots
    services/kiro-gateway.nix
  darwin/
    dots.nix      activation-script backend for dots
hosts/
  satsuma/      existing subtrees + system/{power,storage,auto-upgrade,kernel}.nix
  mail/         was vps/
  pomelo/
  lime/
secrets/        optional: one shared keys.nix imported by each secrets.nix
docs/  tofu/    unchanged
```

## Phases

Each phase is one commit and is verified before the next starts.

**Phase 0 — baseline.** `scripts/drvpaths.sh` prints the toplevel derivation of
every host. Add `formatter`. Record the baseline in `scripts/drvpaths.baseline`.

**Phase 1 — pure moves.** Files into `hosts/` and `modules/`, `vps/` → `hosts/mail/`,
import paths fixed. Store paths depend on file content and name, not location,
so the drvPaths must not change; a change means something else was edited.
Absolute satsuma secret paths move with the tree in the same commit.

**Phase 2 — secret paths.** The 22 absolute satsuma paths become `./secrets/...`,
optionally with a shared `secrets/keys.nix`. Expected diff: only the agenix
units' source paths. Re-run `agenix -r`; it must be a no-op.

**Phase 3 — split `common.nix`.** `modules/nixos/base.nix` (rhuang, fish, nix-ld,
sudo, git identity, nix settings, allowUnfree, timezone, shared CLI) and
`modules/nixos/server.nix` (Lena, subnet-router Tailscale, sshd `openFirewall`,
node_exporter). pomelo imports base; satsuma and mail import base + server.
Remove the duplicate definitions. Verify with `nvd diff` per host: no package or
unit changes, or a short reviewed diff.

**Phase 4 — inventory.** Host table into `inventory.nix`, exposed as
`homelab.hosts`. Generate ssh-hosts, Prometheus scrape targets, blackbox probes,
nginx upstreams, lime's `auto_nas` line and pomelo's NFS devices from it. If the
rendered strings are identical the drvPaths stay the same, which makes this
phase self-checking.

**Phase 5 — flake cleanup.** `overlays.default` exposes `mindroom-nio`,
`matrix-mcp`, `kiro-gateway` and the opencode fix; base applies it. The
kiro-gateway module defaults to `pkgs.kiro-gateway`, opencode.nix uses
`pkgs.matrix-mcp`, `lib/` holds `mkNixos`/`mkDarwin`, the module is exported as
`nixosModules.kiro-gateway`, and `checks.<system>` builds each host so
`nix flake check` catches evaluation failures before the 04:00 autoUpgrade.

**Phase 6 — split `satsuma/configuration.nix`.** Sections into
`hosts/satsuma/system/*.nix`, gateway settings next to the other AI config.
DrvPaths unchanged.

## Verification

- `nix flake check` (after phase 5).
- drvPath comparison against `scripts/drvpaths.baseline` (phases 1, 4, 6).
- `nvd diff` between the old and new toplevels (phases 2, 3, 5).
- `nixos-rebuild build` on all three NixOS hosts, then `switch` on satsuma first.
  lime: `darwin-rebuild build` on the Mac. `users.knownUsers` means dropping the
  rhuang block deletes the account on the next activation.

## Decisions taken

1. Hosts moved under `hosts/`, `vps/` renamed to `mail/`.
2. Lena stays on mail (it imports the server module).
3. Inventory as a typed `homelab.hosts` module option, so it is validated and
   shows up in the option docs.

## Out of scope

flake-parts, Home Manager, deploy-rs/colmena, and any change to `tofu/` or the
package derivations.

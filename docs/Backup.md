# Backups (satsuma)

Config repo: `/etc/nixos` on satsuma → `github.com:ruihuang17/nixos-homelab` (branch `main`).

| What                      | Method                                   | Where it lands                                | Schedule                     | Offsite |
| ------------------------- | ---------------------------------------- | --------------------------------------------- | ---------------------------- | ------- |
| `/var` (all service data) | sanoid snapshots + syncoid replication   | `hdd/backup/var` (HDD pool, same box)         | snapshots hourly, sync daily | no      |
| PostgreSQL (all DBs)      | `pg_dump` + restic over SFTP via tailnet | `mail` VPS `/var/lib/satsuma-backup/postgres` | dump 03:00, push 03:20       | yes     |
| Boot / ESP                | rsync-style mirror to second NVMe ESP    | `nvme0n1p1` (`boot-bak`)                      | on ESP change + timer        | no      |

```
satsuma
 ├─ zpool/var (NVMe) ──sanoid hourly snaps──► syncoid daily ──► hdd/backup/var (HDD)
 │
 └─ postgresql ──pg_dump (zstd)──► /var/backup/postgresql
                                      │  restic (encrypted, dedup)
                                      ▼  SFTP over Tailscale (100.91.236.114)
                                  mail VPS: backup@mail:/var/lib/satsuma-backup/postgres
```

---

## 1. ZFS backup of /var

Module: `satsuma/zfs-backup.nix`

### How it works

- `zpool/var` is the live `/var` dataset (zstd, on the NVMe pool `zpool`).
- **sanoid** takes and prunes snapshots of `zpool/var` (recursive) with the `var` template:
  36 hourly, 14 daily, 4 weekly, 3 monthly. Timer: `sanoid.timer` (top of every hour).
- **syncoid** (`syncoid-var-to-hdd.service`, timer daily at 00:00) replicates those snapshots
  incrementally to `hdd/backup/var` on the HDD pool (lz4). It runs with `--no-sync-snap`, so it
  reuses sanoid's snapshots instead of creating its own.
- Replication is local root→root, no SSH.
- `hdd/backup/var` is created out-of-band with `canmount=off`, so the copy never mounts over the
  live `/var`.
- sanoid also prunes `hdd/backup/var` with the `backup` template (same retention, `autosnap = false`,
  since snapshots arrive via syncoid).

### Limits

- Same machine, different pool: protects against NVMe failure, accidental deletion and bad
  upgrades. It does **not** protect against fire, theft or whole-machine loss.
- Snapshots of live databases are crash-consistent only. That is why Postgres also gets proper `pg_dump` backups (section 2).
- Snapshot counts seen on 2026-10-11: 41 on `zpool/var`, 19 on `hdd/backup/var`.

### Check status

```bash
systemctl list-timers 'sanoid*' 'syncoid*'
journalctl -u syncoid-var-to-hdd.service -n 20
zfs list -t snapshot -r zpool/var | tail
zfs list -t snapshot -r hdd/backup/var | tail
zfs list -o name,used,avail hdd/backup/var zpool/var
```

### Run manually

```bash
systemctl start sanoid.service
systemctl start syncoid-var-to-hdd.service
```

### Restore (not tested; read before running)

Single files: clone a snapshot to a scratch dataset and copy out of it.

```bash
zfs list -t snapshot -r hdd/backup/var | grep daily
zfs clone -o canmount=on -o mountpoint=/mnt/var-restore hdd/backup/var@<snapshot> hdd/restore-tmp
cp -a /mnt/var-restore/<path> /var/<path>
zfs destroy hdd/restore-tmp
```

Whole `/var` loss: boot a rescue/installer, import both pools, then `zfs send`/`zfs recv` the
latest `hdd/backup/var` snapshot back into a new `zpool/var`.

---

## 2. PostgreSQL backup (local dump + offsite to VPS over tailnet)

`kiro-cli --resume-id 688209e0-9a02-4113-a1da-15bd64dcde5c`

Modules: `satsuma/postgres-backup.nix` (source), `vps/backup-target.nix` (destination).
Commit: `d36bc5d`.

### Databases covered

Everything in `services.postgresql.ensureDatabases` plus `matrix-synapse`:
nextcloud, paperless, immich, sonarr-main/log, radarr-main/log, prowlarr-main/log, vaultwarden,
matrix-synapse. Postgres 17, data dir `/var/lib/psql`.

### Satsuma side

- `services.postgresqlBackup`: one `pg_dump` per database, zstd, to `/var/backup/postgresql/<db>.sql.zstd`
  (owner `postgres`, mode 600). Runs at 03:00 (units `postgresqlBackup-<db>.service`).
  Files are overwritten each night; history lives in restic.
- `services.restic.backups.postgres-vps` (`restic-backups-postgres-vps.service`): backs up
  `/var/backup/postgresql` at 03:20 to
  `sftp:backup@mail:/var/lib/satsuma-backup/postgres`.
  Retention: 14 daily, 8 weekly, 12 monthly.
- Restic encrypts client-side; the VPS never sees the password.
- Repo password: agenix secret `satsuma/secrets/restic_postgres_password.age`
  (decrypts to `/run/agenix/restic_postgres_password`; recipients are satsuma's host key and
  the `rhuang` key). **If the rhuang key and satsuma are both lost, the backups are unrecoverable.**
- SSH to the VPS: `Host mail` in `programs.ssh.extraConfig` (user `backup`, identity
  `/etc/ssh/ssh_host_ed25519_key`). The VPS host key is pinned in `programs.ssh.knownHosts`.
- Satsuma auto-upgrades at 04:00, after these jobs.

### VPS (`mail`) side

- User `backup`, home `/var/lib/satsuma-backup` (mode 700), no shell.
- `Match User backup` → `ForceCommand internal-sftp`, no forwarding, no PTY.
- Authorized key = satsuma's SSH host public key, prefixed
  `restrict,from="100.72.25.50"` (satsuma's tailnet IP).
- sshd on the VPS is reachable only on `tailscale0` (port 22 is not open publicly).

### Check status

```bash
# on satsuma
systemctl list-timers 'postgresqlBackup-*' 'restic-backups-*'
journalctl -u restic-backups-postgres-vps.service -n 30
ls -la /var/backup/postgresql

# list snapshots / verify repo (restic is not on PATH; use nix shell)
nix shell nixpkgs#restic -c env RESTIC_PASSWORD_FILE=/run/agenix/restic_postgres_password \
  restic -r sftp:backup@mail:/var/lib/satsuma-backup/postgres snapshots
```

### Run manually

```bash
systemctl start postgresqlBackup-immich.service   # one DB; repeat per DB
systemctl start restic-backups-postgres-vps.service
```

### Restore

```bash
export RESTIC_PASSWORD_FILE=/run/agenix/restic_postgres_password   # on satsuma
export RESTIC_REPOSITORY=sftp:backup@mail:/var/lib/satsuma-backup/postgres
nix shell nixpkgs#restic -c restic restore latest --target /tmp/pgrestore
# then, per database (stop the owning service first, recreate empty DB if needed):
zstd -dc /tmp/pgrestore/var/backup/postgresql/<db>.sql.zstd | sudo -u postgres psql <db>
```

If satsuma is gone: get the password by decrypting the `.age` file from the git repo with the
`rhuang` key (`agenix -d` / `age -d -i <key>`), then run restic from any machine on the tailnet
that has an SSH key the VPS accepts (the `backup` user only accepts satsuma's host key from
satsuma's IP, so add a temporary key in `vps/backup-target.nix` or use root on the VPS to
read `/var/lib/satsuma-backup/postgres` directly).

### Status / caveats

- First run succeeded 2026-10-11: snapshot `5a1d3529`, 96.7 MiB, 11 files.
- Restore and `restic check` have **not** been tested yet.
- Roles/globals are not dumped (they come from `ensureUsers`); add `pg_dumpall --globals-only` if needed.
- SFTP can't enforce append-only: a compromised satsuma could delete the offsite backups.
  Option: restic `rest-server --append-only` on the VPS bound to the tailnet.
- Deploying `mail` from satsuma:
  ```bash
  NIX_SSHOPTS="-i /root/.ssh/general -o IdentitiesOnly=yes" \
    nixos-rebuild switch --flake /etc/nixos#mail --target-host root@100.91.236.114
  ```

---

## 3. Boot disk (ESP) replication

Module: `satsuma/boot-replication.nix`. Mirrors the primary EFI System Partition onto the backup
ESP (`nvme0n1p1`, UUID `1BEB-C3B7`, label `boot-bak`, normally unmounted) and registers a UEFI
boot entry so firmware can boot from the second disk. Triggered by a path watcher on the primary
ESP and a periodic timer; manual: `systemctl start sync-backup-esp`.

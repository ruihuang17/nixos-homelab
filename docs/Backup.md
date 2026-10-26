# Backups (satsuma)

Config repo: `/etc/nixos` on satsuma → `github.com:ruihuang17/nixos-homelab` (branch `main`).

| What                      | Method                                   | Where it lands                                | Schedule                     | Offsite |
| ------------------------- | ---------------------------------------- | --------------------------------------------- | ---------------------------- | ------- |
| `/var` (all service data) | sanoid snapshots + syncoid replication   | `hdd/backup/var` (HDD pool, same box)         | snapshots hourly, sync daily | no      |
| `/var` + `/etc`           | restic to OVHcloud Object Storage        | `satsuma-backup` (Toronto, `ca-east-tor`)      | daily 04:30                  | yes     |
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

---

## 4. Offsite backup to OVHcloud (Toronto)

Module: `satsuma/restic-offsite.nix`.
Repo: `s3:https://s3.ca-east-tor.io.cloud.ovh.net/satsuma-backup`.

### What is backed up

- `/var` — all service data, except:
  - `/var/lib/jellyfin` (re-downloadable media metadata/cache)
  - `/var/lib/immich/thumbs` and `/var/lib/immich/encoded-video` (regenerable)
  - live database directories `/var/lib/psql`, `/var/lib/mysql`, `/var/lib/redis-immich`
    (Postgres dumps are in `/var/backup/postgresql` and are also shipped to the mail VPS)
  - `/var/cache`, `/var/tmp`, `/var/log`, `/var/lib/docker`, `/var/lib/containers`
- `/etc` — host keys, network config, and the NixOS tree.
- `/home` is intentionally **not** included.

Approximate size: ~210 GB (Immich originals are ~201 GB; Nextcloud ~8 GB).

### Bucket / encryption

- OVHcloud Object Storage, region `ca-east-tor` (Toronto), bucket `satsuma-backup`.
- Standard class; **versioning on**; **Object Lock off** (it would block prune).
- Lifecycle rule: noncurrent object versions expire after **30 days**, incomplete multipart
  uploads after **7 days**. Without this, restic prune would only add delete markers and storage
  would grow forever.
- OVH **SSE-OMK** server-side encryption is enabled as defence in depth.
- Restic encrypts client-side. OVH only ever sees restic ciphertext; the restic password is the
  real protection. SSE-OMK does not let OVH read the data.

### Schedule / retention

- `restic-backups-ovh.timer`: daily at **04:30** (persistent, 10 min random delay).
- Retention: **14 daily, 8 weekly, 12 monthly**; `forget --prune` runs after each backup.
- `restic-backups-ovh-check.timer`: **quarterly** (Jan/Apr/Jul/Oct 1 at 12:00) runs
  `restic check --read-data-subset=1/20` (5% of pack data).
- Initial upload is throttled to **8 MB/s** (`--limit-upload 8000`). Remove or raise it after the
  first backup if the WAN can take more.

### Secrets

- `satsuma/secrets/restic_offsite_password.age` — new, independent restic repo password.
- `satsuma/secrets/restic_s3_env.age` — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `AWS_DEFAULT_REGION=ca-east-tor` for the bucket-scoped S3 user.
- Both are encrypted to the satsuma host key and the `rhuang` key. They decrypt to
  `/run/agenix/restic_offsite_password` and `/run/agenix/restic_s3_env` (root, 0400).
- **Store a copy of the restic password in your password manager.** If satsuma and the
  `rhuang` key are both lost, the repository is unrecoverable. To read it on satsuma:

  ```bash
  sudo age -d -i /etc/ssh/ssh_host_ed25519_key \
    /etc/nixos/satsuma/secrets/restic_offsite_password.age
  ```

### Check status

```bash
systemctl list-timers 'restic-backups-ovh*'
journalctl -u restic-backups-ovh.service -n 50
restic-ovh snapshots
restic-ovh stats
```

`restic-ovh` is the generated wrapper; it already has the repository, password file, and S3
credentials in its environment. `restic-ovh-check` is the same for the quarterly check.

### Run manually

```bash
systemctl start restic-backups-ovh.service
systemctl start restic-backups-ovh-check.service
```

### Restore

```bash
# List snapshots.
restic-ovh snapshots

# Restore everything to /tmp (needs ~210 GB free).
restic-ovh restore latest --target /tmp/restore

# Restore only one path.
restic-ovh restore latest --target /tmp/restore --include /var/lib/nextcloud

# Restore a specific snapshot.
restic-ovh restore <snapshot-id> --target /tmp/restore
```

If satsuma is gone, decrypt the two `.age` files from the git repo with the `rhuang` key, then
run restic from any machine with the S3 credentials:

```bash
export RESTIC_REPOSITORY=s3:https://s3.ca-east-tor.io.cloud.ovh.net/satsuma-backup
export RESTIC_PASSWORD_FILE=/path/to/decrypted/restic_offsite_password
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=ca-east-tor
restic restore latest --target /tmp/restore
```

### Caveats

- OVHcloud Canada is **single-AZ**; there is no multi-AZ Canadian region. This is still an
  offsite copy, separate from the local HDD pool and the mail VPS.
- `/home` is excluded by design.
- Live SQLite/other databases (e.g. Vaultwarden) are captured crash-consistently, not with a
  database-aware dump. Postgres is covered separately by `pg_dump`.
- Versioning plus the 30-day noncurrent lifecycle gives a 30-day undelete window, but there is no
  Object Lock, so a compromised satsuma could still delete the bucket contents with its S3 key
  (and an attacker with the bucket key could remove versions).
- The first full backup takes roughly 7–8 hours at 8 MB/s. Incremental daily backups are much
  smaller.
- Status: repository created and smoke-restore tested **2026-10-26**; initial full backup started
  **2026-10-26 03:48 EDT**. Check `restic-ovh snapshots` for completion.

### Monitoring

Grafana alert rules (provisioned from `satsuma/monitoring.nix`):

- `homelab-restic-offsite-failed` — `restic-backups-ovh*` unit in `failed` state.
- `homelab-restic-offsite-stale` — timer has not fired for >48 h.

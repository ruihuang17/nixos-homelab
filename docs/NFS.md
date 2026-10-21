# NFS (satsuma)

Documented 2026-10-20.

satsuma runs the kernel NFS server (`services.nfs.server.enable = true` in
`satsuma/hardware-configuration.nix`) and exports three ZFS datasets with the
ZFS `sharenfs` property. `/etc/exports` is empty; ZFS generates the exports and
registers them with `exportfs`.

## Exports

| Dataset | Mountpoint | Allowed clients | `sharenfs` |
| --- | --- | --- | --- |
| `hdd/mediaSrv` | `/hdd/mediaSrv` | LAN `10.0.10.0/24` | `rw=@10.0.10.0/24,no_root_squash,insecure` |
| `hdd/data` | `/hdd/data` | `pomelo` `10.0.10.40/32` | `rw=10.0.10.40/32,no_root_squash,no_all_squash` |
| `hdd/backup` | `/hdd/backup` | `pomelo` `10.0.10.40/32` | `rw=10.0.10.40/32,no_root_squash` |

`hdd/backup/var` inherits its parent's `sharenfs`, but it is `canmount=off` and
is not separately exported. It is syncoid's replication target, not a client
mount.

`hdd/data` and `hdd/backup` were previously exported to `10.0.40.20/32`, which
is not on the LAN and was unreachable. They were changed to pomelo's address on
2026-10-20.

## Changing an export

```bash
# Example: allow the whole LAN
sudo zfs set sharenfs='rw=10.0.10.0/24,no_root_squash' hdd/data

# Inspect
zfs get sharenfs hdd/data hdd/backup hdd/mediaSrv
exportfs -v
showmount -e localhost
```

Setting the property re-shares the dataset immediately if it was already shared.
`zfs share -a` applies every `sharenfs` property; `zfs unshare -a` removes them
all.

> `/proc/fs/nfsd/exports` can show only the header on this host even while
> exports work (nfs-utils 2.8.7 uses the nfsdctl/netlink interface). Use
> `exportfs -v` and an actual mount as the source of truth.

## Clients

### pomelo (desktop, 10.0.10.40)

`/etc/fstab` mounts all three datasets under `~/NAS`:

```
10.0.10.72:/hdd/backup   /home/rhuang/NAS/backup  nfs4  rw,noatime,hard,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=10min,x-systemd.mount-timeout=30s  0 0
10.0.10.72:/hdd/data     /home/rhuang/NAS/data    nfs4  rw,noatime,hard,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=10min,x-systemd.mount-timeout=30s  0 0
10.0.10.72:/hdd/mediaSrv /home/rhuang/NAS/media   nfs4  rw,noatime,hard,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=10min,x-systemd.mount-timeout=30s  0 0
```

On pomelo, the previous fstab is backed up at `/etc/fstab.bak-20261020-nfs`.
`x-systemd.automount` mounts on first access and unmounts after 10 minutes idle,
so a satsuma outage does not block boot.

**Tailscale caveat:** satsuma advertises `10.0.10.0/24` as a Tailscale subnet
route. pomelo is on that subnet, so it must not accept routes:

```bash
sudo tailscale set --accept-routes=false
ip route get 10.0.10.72   # must be: dev enp9s0 ... src 10.0.10.40
```

If pomelo accepts the route, NFS traffic goes over `tailscale0` with source
`100.127.87.100`, which no export allows, and mounts fail with
`access denied by server`.

### mac-mini

`~/NAS/mediaSrv` is an autofs mount of `/hdd/mediaSrv`.

## Permissions

- `rhuang` is uid 1000 on both satsuma and pomelo.
- satsuma group `media` and pomelo group `storage` are both GID 3000, so numeric
  GID mapping works without idmapd configuration.
- The dataset roots are `root:media` mode `770` (`2770` on shared subdirectories); `rhuang` has group access.
- `no_root_squash` is set on all three exports.

## Verification

From pomelo:

```bash
showmount -e 10.0.10.72
findmnt -T ~/NAS/backup
findmnt -T ~/NAS/data
findmnt -T ~/NAS/media
touch ~/NAS/data/.write-test && rm ~/NAS/data/.write-test
```

From satsuma:

```bash
exportfs -v
zfs get sharenfs hdd/data hdd/backup hdd/mediaSrv
systemctl status nfs-server
```

## Troubleshooting

- `access denied by server`: the client's source IP is not in the dataset's
  `sharenfs` ACL. Check `ip route get 10.0.10.72` on the client.
- `No such file or directory` from `mount.nfs`: the export exists but is hidden
  from that client (exportfs returns ENOENT for unauthorized clients).
- `nfsdctl: Error: Invalid argument` in `nfs-server` logs on start is currently
  benign; NFS still works.
- If exports are empty after a reboot, run `sudo zfs share -a`.
  `zfs-share.service` runs before `nfs-server.service`; this was seen once but
  did not reproduce on an `nfs-server` restart.

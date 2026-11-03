# OVH infrastructure (OpenTofu)

Manages the OVH side of the homelab. Nix configures what runs on the hosts;
this directory creates the OVH resources they depend on.

| File | Purpose |
| --- | --- |
| `storage.tf` | Buckets `satsuma-backup` and `satsuma-tofu-state`, each with its own S3 user, credential and bucket-scoped policy |
| `vps.tf` | Reads the existing mail VPS (data source only) |
| `outputs.tf` | Sensitive `KEY=value` blocks in the format `restic_s3_env.age` uses |
| `backend.tf.example` | S3 remote state on OVH with native locking |

`ovh_vps` places a paid order on create and is slated for a rework upstream,
so the VPS is read-only here. `satsuma-backup` already exists and is imported
by the `import` block in `storage.tf`. It has `prevent_destroy` set.

## Credentials

Create an application at https://ca.api.ovh.com/createToken/ with rights on
`/cloud/project/<project_id>/*` only. Keep them in an agenix secret and load
them into the shell:

```bash
agenix -e tofu_ovh_env.age -i /etc/ssh/ssh_host_ed25519_key   # add the entry to a secrets.nix first
set -a; source <(agenix -d tofu_ovh_env.age -i ~/.ssh/id_ed25519); set +a
```

The file holds `OVH_ENDPOINT=ovh-ca`, `OVH_APPLICATION_KEY`,
`OVH_APPLICATION_SECRET` and `OVH_CONSUMER_KEY`.

## Usage

```bash
cd /etc/nixos/tofu
cp terraform.tfvars.example terraform.tfvars   # fill in project_id and VPS name
nix shell nixpkgs#opentofu
tofu init
tofu plan        # review: the backup bucket should show as an import, not a replace
tofu apply
```

Moving state to the bucket after the first apply:

```bash
tofu output -raw s3_env_state          # AWS_* keys for the state user
cp backend.tf.example backend.tf
tofu init -migrate-state
```

Credentials created here can feed back into agenix, for example
`tofu output -raw s3_env_backup | agenix -e restic_s3_env.age`.
The first apply creates new S3 users, so the existing restic keys keep
working until `restic_s3_env.age` is replaced.

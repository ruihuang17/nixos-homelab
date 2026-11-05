#!/usr/bin/env bash
# Deploy this flake to one or more hosts.
#
#   scripts/deploy.sh                 # all NixOS hosts
#   scripts/deploy.sh satsuma         # just one
#   scripts/deploy.sh bergamot pomelo  # several
#   scripts/deploy.sh --build all     # build only, no switch
#
# Hosts are reached through the ssh aliases the flake installs on every
# NixOS host (`programs.ssh.extraConfig`), so there are no addresses to keep
# in sync here. `lime` is nix-darwin and has to be deployed on the Mac.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [options] [host...]

Hosts: satsuma, bergamot, pomelo, all (default: all)

Options:
  -b, --build       build instead of switching
  -n, --dry-run     print the commands without running them
  -k, --keep-going  continue after a host fails
  -h, --help        show this help

lime is a nix-darwin host; the script prints the command to run on the Mac
instead of trying to deploy it remotely.
EOF
}

action=switch
dry_run=0
keep_going=0
targets=()

while (($#)); do
  case "$1" in
    -b | --build) action=build ;;
    -n | --dry-run) dry_run=1 ;;
    -k | --keep-going) keep_going=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    all)
      targets+=(satsuma bergamot pomelo)
      ;;
    satsuma | bergamot | pomelo | lime)
      targets+=("$1")
      ;;
    *)
      echo "deploy: unknown host or option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

((${#targets[@]})) || targets=(satsuma bergamot pomelo)

# Dedupe while preserving order (`all satsuma` should deploy satsuma once).
mapfile -t targets < <(printf '%s\n' "${targets[@]}" | awk '!seen[$0]++')

run() {
  printf '==>'
  printf ' %q' "$@"
  printf '\n'
  ((dry_run)) || "$@"
}

# The flake name is not always the hostname: `bergamot` runs as hostname `mail`
# (the provider's reverse DNS fixes it). Used only to detect the local machine.
hostname_of() {
  case "$1" in
    bergamot) echo mail ;;
    *) echo "$1" ;;
  esac
}

deploy_lime() {
  cat <<'EOF'
==> lime is nix-darwin, so it is deployed on the Mac:

    ssh lime
    cd ~/nixos-homelab && git pull
    sudo darwin-rebuild switch --flake .#lime
EOF
}

failed=()
deployed=0

for host in "${targets[@]}"; do
  if [[ $host == lime ]]; then
    deploy_lime
    continue
  fi

  if [[ $action == build ]]; then
    # `build` never activates, so it is always a local evaluation/build of the
    # host's configuration. No target-host, no elevation.
    cmd=(nixos-rebuild build --flake "$repo_root#$host")
  elif [[ $(hostname -s) == "$(hostname_of "$host")" ]]; then
    # Deploying the machine we are on: switch needs privileges.
    cmd=(nixos-rebuild switch --flake "$repo_root#$host")
    [[ $EUID -ne 0 ]] && cmd+=(--elevate=sudo)
  else
    case "$host" in
      pomelo)
        # rhuang has passwordless sudo; root has no key on the desktop.
        cmd=(nixos-rebuild switch --flake "$repo_root#$host" --target-host rhuang@pomelo --elevate=sudo)
        ;;
      *)
        cmd=(nixos-rebuild switch --flake "$repo_root#$host" --target-host "root@$host")
        ;;
    esac
  fi

  if run "${cmd[@]}"; then
    deployed=$((deployed + 1))
  else
    failed+=("$host")
    ((keep_going)) || break
  fi
done

if ((deployed)); then
  verb=deployed
  [[ $action == build ]] && verb=built
  echo "$verb: $deployed host(s)"
fi
if ((${#failed[@]})); then
  echo "failed: ${failed[*]}" >&2
  exit 1
fi

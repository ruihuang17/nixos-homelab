{ ... }:

{
  # Tailscale configuration has moved to the shared ../common.nix so that it
  # is applied uniformly across all hosts (satsuma and the mail VPS).
  # This file is intentionally left as a no-op to avoid duplicate option
  # definitions; the import is kept for backwards compatibility.
}

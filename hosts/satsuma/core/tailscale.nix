{ ... }:

{
  # Tailscale configuration has moved to modules/nixos/server.nix so that it is
  # applied uniformly across the server hosts (satsuma and the mail VPS).
  # This file is intentionally left as a no-op to avoid duplicate option
  # definitions; the import is kept for backwards compatibility.
}

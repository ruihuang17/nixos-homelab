{ lib, ... }:
# Typed view of inventory.nix plus the `homelab` module argument. Imported by
# base.nix (NixOS) and the lime configuration (nix-darwin), so modules never
# hardcode an address.
{
  options.homelab = {
    domain = lib.mkOption {
      type = lib.types.str;
      default = (import ../../inventory.nix).domain;
      readOnly = true;
      description = "Public DNS domain, used for TLS names and probes.";
    };

    lanCidr = lib.mkOption {
      type = lib.types.str;
      default = (import ../../inventory.nix).lanCidr;
      readOnly = true;
      description = "LAN subnet, used in firewall rules and nginx allow lists.";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      default = (import ../../inventory.nix).gateway;
      readOnly = true;
      description = "LAN default gateway / UniFi controller.";
    };

    storageGid = lib.mkOption {
      type = lib.types.int;
      default = (import ../../inventory.nix).storageGid;
      readOnly = true;
      description = "GID of the NFS media group, identical on every client.";
    };

    hosts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = lib.types.str;
              description = "Address other hosts should use (LAN, or the tailnet address).";
            };
            sshUser = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Default ssh user for this host.";
            };
            sshPort = lib.mkOption {
              type = lib.types.port;
              default = 22;
              description = "sshd port.";
            };
            tailnet = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Reachable only over Tailscale.";
            };
            description = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "One-line role summary.";
            };
          };
        }
      );
      default = (import ../../inventory.nix).hosts;
      description = "Every machine in the homelab, keyed by name.";
    };
  };

  config._module.args.homelab = import ../../lib/homelab.nix { inherit lib; };
}

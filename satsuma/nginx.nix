{ pkgs, config, ... }:
{
  age.secrets.cloudflare_api.file = "/etc/nixos/satsuma/secrets/cloudflare_api.age";

  security.acme = {
    acceptTerms = true;
    defaults.email = "rui.huang17@protonmail.com";
    certs."ruihuang.io" = {
      domain = "ruihuang.io";
      extraDomainNames = [
        "*.ruihuang.io"
        "*.local.ruihuang.io"
      ];
      group = config.services.nginx.group;
      dnsProvider = "cloudflare";
      environmentFile = config.age.secrets.cloudflare_api.path;
      dnsResolver = "1.1.1.1:53";
      extraLegoRunFlags = [ "--ari-disable" ];
    };
    certs."estrogenuinely.ca" = {
      domain = "estrogenuinely.ca";
      extraDomainNames = [
        "*.estrogenuinely.ca"
        "*.local.estrogenuinely.ca"
      ];
      group = config.services.nginx.group;
      dnsProvider = "cloudflare";
      # Same Cloudflare API token manages both the ruihuang.io and
      # estrogenuinely.ca zones, so the existing credentials file is reused.
      environmentFile = config.age.secrets.cloudflare_api.path;
      dnsResolver = "1.1.1.1:53";
      extraLegoRunFlags = [ "--ari-disable" ];
    };
  };

  services.nginx = {
    enable = true;
    # I recommend these, but it's up to you
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;

    virtualHosts = {
      "ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        root = "/srv/www/main/public";
        locations."/countdown/" = {
          alias = "/srv/www/countdown/";
          index = "index.html";
        };
      };

      "www.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        globalRedirect = "ruihuang.io";
      };

      # Apex vhost: only serves Matrix delegation, since server_name is
      # estrogenuinely.ca but Synapse lives at matrix.estrogenuinely.ca.
      "estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."= /.well-known/matrix/server" = {
          extraConfig = ''
            default_type application/json;
            return 200 '{"m.server": "matrix.estrogenuinely.ca:443"}';
          '';
        };
        locations."= /.well-known/matrix/client" = {
          extraConfig = ''
            default_type application/json;
            add_header Access-Control-Allow-Origin "*";
            return 200 '{"m.homeserver": {"base_url": "https://matrix.estrogenuinely.ca"}}';
          '';
        };
      };

      "nextcloud.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
      };

      "collabora.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://[::1]:${toString config.services.collabora-online.port}";
          proxyWebsockets = true; # collabora uses websockets
        };
      };

      "homeassistant.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://10.0.10.74:8123";
          proxyWebsockets = true;
        };
      };

      "idm.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "https://127.0.0.1:8443";
          extraConfig = ''
            proxy_ssl_server_name on;
          '';
        };
      };

      "paperless.local.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:28981";
        };
      };

      "immich.local.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        extraConfig = ''
          client_max_body_size 50000M;
          client_body_buffer_size 1024k;
        '';
        locations."/" = {
          proxyPass = "http://[::1]:2283";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_request_buffering off;
            proxy_redirect off;
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
            send_timeout 600s;
          '';
        };
      };

      "jellyfin.local.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:8096";
        };
      };

      "sonarr.local.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:8989";
        };
      };

      "radarr.local.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:7878";
        };
      };

      "prowlarr.local.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:9696";
        };
      };

      "vaultwarden.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
      };

      "dns.local.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://10.0.10.23:5380";
        };
      };

      # LAN-only Synapse endpoint for the air-gapped SMS bridge phone.
      # Resolves to 10.0.10.72 via internal DNS (*.local.* wildcard cert),
      # so the phone never hairpins out to the public WAN IP.
      "matrix.local.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:8008";
          proxyWebsockets = true;
        };
      };

      "matrix.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:8008";
        };
      };

      "mautrix-wsproxy.local.estrogenuinely.ca" = {
        useACMEHost = "estrogenuinely.ca";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:29331";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
          '';
        };
      };

    };
  };
}

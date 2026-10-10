{ pkgs, config, ... }:
{
  age.secrets.cloudflare_api.file = "/etc/nixos/secrets/cloudflare_api.age";

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

      "nextcloud.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
      };

      "collabora.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://[::1]:${toString config.services.collabora-online.port}";
          proxyWebsockets = true; # collabora uses websockets
        };
      };

      "homeassistant.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://10.0.10.74:8123";
          proxyWebsockets = true;
        };
      };

      "idm.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        locations."/" = {
          proxyPass = "https://127.0.0.1:8443";
          extraConfig = ''
            proxy_ssl_server_name on;
          '';
        };
      };

      "paperless.local.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:28981";
        };
      };

      "immich.local.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
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

      "jellyfin.local.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:8096";
        };
      };

      "sonarr.local.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:8989";
        };
      };

      "radarr.local.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:7878";
        };
      };

      "prowlarr.local.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:9696";
        };
      };

      "vaultwarden.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
      };

      "dns.local.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://10.0.10.23:5380";
        };
      };

      "matrix.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:8008";
        };
      };

      "mautrix-wsproxy.local.ruihuang.io" = {
        useACMEHost = "ruihuang.io";
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

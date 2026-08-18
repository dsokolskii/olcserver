# Olc Server

Olc Server is a web control panel for managing `olcrtc` rooms on Linux.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/dsokolskii/olcserver/master/install.sh | sudo bash
```

The installer keeps the application bound to `127.0.0.1:8080` and configures
nginx as the public reverse proxy. Requests to port 80 are redirected to HTTPS
on port 443. Ports 80 and 443 must be reachable from the Internet for
certificate issuance and renewal. If either port belongs to a service other
than nginx, installation stops instead of exposing the admin panel over plain
HTTP.

Without additional settings, the installer requests a short-lived Let's
Encrypt certificate for the server IP address. Certbot renews it twice daily.
To use a DNS name instead, point its A or AAAA record at the server and run:

```sh
curl -fsSL https://raw.githubusercontent.com/dsokolskii/olcserver/master/install.sh \
  | sudo OLCSERVER_DOMAIN=panel.example.com \
    LETSENCRYPT_EMAIL=admin@example.com bash
```

The packaged nginx welcome site is removed automatically. Existing custom
nginx sites are left in place.

### Low-memory servers

The installer checks available RAM and free swap, including cgroup v2 limits when available, before compilation. A host with substantially less than 4 GiB of usable RAM must have at least 4 GiB of active swap, as recommended by the [`olcrtc` manual](https://github.com/openlibrecommunity/olcrtc/blob/master/docs/manual.md); a 256 MiB tolerance prevents nominal 4 GiB VPSes from being mistaken for smaller plans because of kernel-reserved memory. On supported hosts the installer attempts to create the missing swap at `/swapfile`; if that path already exists, it uses `/olcserver.swap` without modifying the existing file. Successfully registered swap remains enabled after installation and continues to occupy disk space.

If the required memory cannot be provided, installation stops before compilation instead of continuing into an out-of-memory failure. Swap must be enabled on the host for containers and chroots. Builds use one Go job and a more memory-efficient garbage-collection setting by default.

Automatic swap is enabled by default. On a low-memory server, use the standard installation command above without setting `OLCSERVER_AUTO_SWAP=false`. If the installer reports that automatic swap creation is disabled, rerun the standard command.

For advanced configuration, `OLCSERVER_MIN_BUILD_MEMORY_MB` and `OLCSERVER_MIN_BUILD_SWAP_MB` change the default 4096 MB thresholds, while `OLCSERVER_BUILD_GOGC` defaults to `20`. `OLCSERVER_AUTO_SWAP=false` is intended only for hosts where memory has already been provisioned; it does not bypass the memory check. `OLCSERVER_ALLOW_LOW_MEMORY_BUILD=true` explicitly attempts a build below the requirement and may still be killed by the kernel.

If an earlier build failed and the installer reports insufficient disk space, check for old caches with `sudo du -sh /root/.cache/go-build /root/go/pkg/mod /var/cache/apt/archives 2>/dev/null`. Go caches contain reproducible build data and can be removed with `sudo -H /usr/local/go/bin/go clean -cache -modcache`; on Debian and Ubuntu, downloaded package archives can be removed with `sudo apt-get clean`. Current installer runs keep their Go caches inside the temporary work directory and remove them on normal exit. At least 6144 MiB must be free to create the default 4096 MiB swap while retaining the 2048 MiB build reserve. If cleanup cannot provide that space, expand the disk instead of lowering the memory safeguards.

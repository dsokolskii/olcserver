# Olc Server

Olc Server is a web control panel for managing `olcrtc` rooms on Linux.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/dsokolskii/olcserver/master/install.sh | sudo bash
```

### Low-memory servers

The installer checks available RAM and free swap, including cgroup v2 limits when available, before compilation. A host with substantially less than 4 GiB of usable RAM must have at least 4 GiB of active swap, as recommended by the [`olcrtc` manual](https://github.com/openlibrecommunity/olcrtc/blob/master/docs/manual.md); a 256 MiB tolerance prevents nominal 4 GiB VPSes from being mistaken for smaller plans because of kernel-reserved memory. On supported hosts the installer attempts to create the missing swap at `/swapfile`; if that path already exists, it uses `/olcserver.swap` without modifying the existing file. Successfully registered swap remains enabled after installation and continues to occupy disk space.

If the required memory cannot be provided, installation stops before compilation instead of continuing into an out-of-memory failure. Swap must be enabled on the host for containers and chroots. Builds use one Go job and a more memory-efficient garbage-collection setting by default.

Automatic swap is enabled by default. On a low-memory server, use the standard installation command above without setting `OLCSERVER_AUTO_SWAP=false`. If the installer reports that automatic swap creation is disabled, rerun the standard command.

For advanced configuration, `OLCSERVER_MIN_BUILD_MEMORY_MB` and `OLCSERVER_MIN_BUILD_SWAP_MB` change the default 4096 MB thresholds, while `OLCSERVER_BUILD_GOGC` defaults to `20`. `OLCSERVER_AUTO_SWAP=false` is intended only for hosts where memory has already been provisioned; it does not bypass the memory check. `OLCSERVER_ALLOW_LOW_MEMORY_BUILD=true` explicitly attempts a build below the requirement and may still be killed by the kernel.

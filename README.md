# Olc Server

Olc Server is a web control panel for managing `olcrtc` rooms on Linux.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/dsokolskii/olcserver/master/install.sh | sudo bash
```

### Low-memory servers

The installer checks total RAM and active swap before compilation. If their combined size is below 4 GB, it attempts to create enough swap at `/swapfile` to reach that threshold. On success the swap remains enabled after installation, is registered in `/etc/fstab`, and continues to occupy disk space. Existing swap and an existing `/swapfile` are left untouched. Builds use one Go job by default to limit peak memory usage.

Inside containers and chroots, or on unsupported filesystems, the installer continues with a single build job and prints a warning. Automatic swap and build limits can be configured through environment variables:

```sh
curl -fsSL https://raw.githubusercontent.com/dsokolskii/olcserver/master/install.sh \
  | sudo env OLCSERVER_AUTO_SWAP=false OLCSERVER_BUILD_JOBS=1 bash
```

`OLCSERVER_MIN_BUILD_MEMORY_MB` changes the default 4096 MB threshold.

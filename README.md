# Olc Server

Olc Server is a web control panel for managing `olcrtc` rooms on Ubuntu.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/dsokolskii/olcserver/master/install.sh | sudo bash
```

The installer supports Linux distributions with systemd and one of `apt`, `dnf`, `yum`, or `pacman`. It builds and starts the server. On a clean server with free ports `80` and `443`, it also configures HTTPS automatically. If those ports are already occupied, the panel remains available over HTTP on port `8080`.

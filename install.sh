#!/usr/bin/env bash
set -Eeuo pipefail

OLCSERVER_REPOSITORY="${OLCSERVER_REPOSITORY:-https://github.com/dsokolskii/olcserver.git}"
OLCRTC_REPOSITORY="${OLCRTC_REPOSITORY:-https://github.com/openlibrecommunity/olcrtc.git}"
OLCSERVER_REF="${OLCSERVER_REF:-master}"
OLCRTC_REF="${OLCRTC_REF:-master}"
GO_VERSION="${GO_VERSION:-1.26.5}"
INSTALL_ROOT="/opt/olcserver"
DATA_ROOT="/var/lib/olcserver"
SERVICE_USER="olcserver"
PANEL_PORT="${OLCSERVER_PORT:-8080}"
DOMAIN="${OLCSERVER_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
LISTEN_ADDRESS="0.0.0.0"
HTTPS_ENABLED="false"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer as root: sudo bash install.sh"
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "Unsupported Linux distribution"
  exit 1
fi

source /etc/os-release
if ! command -v systemctl >/dev/null 2>&1; then
  echo "This installer requires a Linux distribution with systemd"
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  PKG_UPDATE=(apt-get update)
  PKG_INSTALL=(apt-get install -y --no-install-recommends)
  BASE_PACKAGES=(ca-certificates curl git tar iproute2)
  WEB_PACKAGES=(nginx certbot python3-certbot-nginx)
elif command -v dnf >/dev/null 2>&1; then
  PKG_UPDATE=(dnf makecache)
  PKG_INSTALL=(dnf install -y)
  BASE_PACKAGES=(ca-certificates curl git tar iproute)
  WEB_PACKAGES=(nginx certbot python3-certbot-nginx)
elif command -v yum >/dev/null 2>&1; then
  PKG_UPDATE=(yum makecache)
  PKG_INSTALL=(yum install -y)
  BASE_PACKAGES=(ca-certificates curl git tar iproute)
  WEB_PACKAGES=(nginx certbot python3-certbot-nginx)
elif command -v pacman >/dev/null 2>&1; then
  PKG_UPDATE=(pacman -Sy --noconfirm)
  PKG_INSTALL=(pacman -S --noconfirm --needed)
  BASE_PACKAGES=(ca-certificates curl git tar iproute2)
  WEB_PACKAGES=(nginx certbot certbot-nginx)
else
  echo "Unsupported Linux distribution: no supported package manager found"
  exit 1
fi

case "$(uname -m)" in
  x86_64) GO_ARCH="amd64" ;;
  aarch64|arm64) GO_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
"${PKG_UPDATE[@]}"
"${PKG_INSTALL[@]}" "${BASE_PACKAGES[@]}"
PORTS_BUSY="false"
if ss -ltn 2>/dev/null | grep -Eq ':[[:digit:]]+ (LISTEN|[0-9]+)' ; then
  if ss -ltn 2>/dev/null | grep -Eq '(^|:)80[[:space:]]|(^|:)443[[:space:]]'; then
    PORTS_BUSY="true"
  fi
fi

if [[ "${PORTS_BUSY}" == "false" ]]; then
  "${PKG_INSTALL[@]}" "${WEB_PACKAGES[@]}"
  LISTEN_ADDRESS="127.0.0.1"
  HTTPS_ENABLED="true"
elif [[ -n "${DOMAIN}" ]]; then
  echo "Ports 80/443 are already in use; leaving existing proxy untouched and using HTTP on :${PANEL_PORT}"
fi

WORK_DIR="$(mktemp -d /tmp/olcserver-install.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "[1/6] Installing Go ${GO_VERSION}"
curl --fail --location --retry 3 "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o "${WORK_DIR}/go.tar.gz"
rm -rf /usr/local/go
tar -C /usr/local -xzf "${WORK_DIR}/go.tar.gz"

echo "[2/6] Building olcrtc"
git clone --depth 1 --recurse-submodules --shallow-submodules --branch "${OLCRTC_REF}" "${OLCRTC_REPOSITORY}" "${WORK_DIR}/olcrtc"
(
  cd "${WORK_DIR}/olcrtc"
  /usr/local/go/bin/go build -trimpath -ldflags="-s -w" -o "${WORK_DIR}/olcrtc-bin" ./cmd/olcrtc
)

echo "[3/6] Building Olc Server"
if [[ -f "$(dirname "$0")/go.mod" ]]; then
  cp -R "$(dirname "$0")/." "${WORK_DIR}/olcserver"
else
  git clone --depth 1 --branch "${OLCSERVER_REF}" "${OLCSERVER_REPOSITORY}" "${WORK_DIR}/olcserver"
fi
(
  cd "${WORK_DIR}/olcserver"
  /usr/local/go/bin/go build -trimpath -ldflags="-s -w" -o "${WORK_DIR}/olcserver-bin" .
)

echo "[4/6] Installing services"
if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
  useradd --system --home-dir "${DATA_ROOT}" --shell /usr/sbin/nologin "${SERVICE_USER}"
fi
install -d -m 0755 "${INSTALL_ROOT}"
install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0700 "${DATA_ROOT}"
install -m 0755 "${WORK_DIR}/olcrtc-bin" /usr/local/bin/olcrtc
install -m 0755 "${WORK_DIR}/olcserver-bin" /usr/local/bin/olcserver

PASSWORD="$(runuser -u "${SERVICE_USER}" -- /usr/local/bin/olcserver init --data "${DATA_ROOT}" 2>/dev/null || true)"
if [[ -z "${PASSWORD}" ]]; then
  PASSWORD="$(cat "${DATA_ROOT}/admin-password")"
fi

cat >/etc/systemd/system/olcserver.service <<EOF
[Unit]
Description=Olc Server control panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=/usr/local/bin/olcserver serve --listen ${LISTEN_ADDRESS}:${PANEL_PORT} --data ${DATA_ROOT} --olcrtc /usr/local/bin/olcrtc
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DATA_ROOT}
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

echo "[5/6] Starting Olc Server"
systemctl daemon-reload
systemctl enable --now olcserver.service
sleep 2
systemctl is-active --quiet olcserver.service

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SERVER_IP="${SERVER_IP:-YOUR_SERVER_IP}"

if [[ "${PORTS_BUSY}" == "false" ]]; then
  CERT_NAME="${DOMAIN:-${SERVER_IP}}"
fi

if [[ "${HTTPS_ENABLED}" == "true" ]]; then
  cat >/etc/nginx/sites-available/olcserver <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${CERT_NAME};

    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  ln -sfn /etc/nginx/sites-available/olcserver /etc/nginx/sites-enabled/olcserver
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  CERTBOT_EMAIL_ARGS=(--register-unsafely-without-email)
  if [[ -n "${LETSENCRYPT_EMAIL}" ]]; then
    CERTBOT_EMAIL_ARGS=(--email "${LETSENCRYPT_EMAIL}")
  fi
  certbot --nginx --non-interactive --agree-tos "${CERTBOT_EMAIL_ARGS[@]}" --redirect -d "${CERT_NAME}"
  PANEL_URL="https://${CERT_NAME}"
else
  PANEL_URL="http://${SERVER_IP}:${PANEL_PORT}"
fi

echo "[6/6] Installation complete"
echo
echo "============================================================"
echo "  OLC SERVER IS READY"
echo "============================================================"
echo
echo "Open the panel in your browser:"
echo
echo "  ${PANEL_URL}"
echo
echo "Admin password:"
echo
echo "  ${PASSWORD}"
echo
echo "The password is also stored at ${DATA_ROOT}/admin-password"
if [[ "${HTTPS_ENABLED}" == "true" ]]; then
  echo "HTTPS certificate renewals are handled by certbot's systemd timer"
fi
echo "Service logs: journalctl -u olcserver -f"
echo "============================================================"

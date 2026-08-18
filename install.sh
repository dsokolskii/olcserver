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
AUTO_SWAP="${OLCSERVER_AUTO_SWAP:-true}"
MIN_BUILD_MEMORY_MB="${OLCSERVER_MIN_BUILD_MEMORY_MB:-4096}"
BUILD_JOBS="${OLCSERVER_BUILD_JOBS:-1}"
SWAP_FILE="/swapfile"
INSTALL_LOCK_FILE="/run/olcserver-install.lock"
LISTEN_ADDRESS="0.0.0.0"
HTTPS_ENABLED="false"
MANAGED_SWAP_PATH=""
SWAP_SETUP_PENDING="false"
WORK_DIR=""

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

case "${AUTO_SWAP}" in
  true|false) ;;
  *) echo "OLCSERVER_AUTO_SWAP must be true or false"; exit 1 ;;
esac
if [[ ! "${MIN_BUILD_MEMORY_MB}" =~ ^[1-9][0-9]*$ ]] || (( MIN_BUILD_MEMORY_MB > 65536 )); then
  echo "OLCSERVER_MIN_BUILD_MEMORY_MB must be an integer between 1 and 65536"
  exit 1
fi
if [[ ! "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] || (( BUILD_JOBS > 256 )); then
  echo "OLCSERVER_BUILD_JOBS must be an integer between 1 and 256"
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  PKG_UPDATE=(apt-get update)
  PKG_INSTALL=(apt-get install -y --no-install-recommends)
  BASE_PACKAGES=(ca-certificates curl git tar iproute2 util-linux)
  WEB_PACKAGES=(nginx certbot python3-certbot-nginx)
elif command -v dnf >/dev/null 2>&1; then
  PKG_UPDATE=(dnf makecache)
  PKG_INSTALL=(dnf install -y)
  BASE_PACKAGES=(ca-certificates curl git tar iproute util-linux)
  WEB_PACKAGES=(nginx certbot python3-certbot-nginx)
elif command -v yum >/dev/null 2>&1; then
  PKG_UPDATE=(yum makecache)
  PKG_INSTALL=(yum install -y)
  BASE_PACKAGES=(ca-certificates curl git tar iproute util-linux)
  WEB_PACKAGES=(nginx certbot python3-certbot-nginx)
elif command -v pacman >/dev/null 2>&1; then
  PKG_UPDATE=(pacman -Sy --noconfirm)
  PKG_INSTALL=(pacman -S --noconfirm --needed)
  BASE_PACKAGES=(ca-certificates curl git tar iproute2 util-linux)
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

swap_file_is_active() {
  local swap_path="${1:-${SWAP_FILE}}"
  awk -v swap_file="${swap_path}" '
    NR > 1 && $1 == swap_file { found = 1 }
    END { exit(found ? 0 : 1) }
  ' /proc/swaps 2>/dev/null
}

cleanup_pending_swap() {
  if [[ "${SWAP_SETUP_PENDING}" != "true" || -z "${MANAGED_SWAP_PATH}" ]]; then
    return 0
  fi

  if swap_file_is_active "${MANAGED_SWAP_PATH}"; then
    if ! swapoff "${MANAGED_SWAP_PATH}"; then
      echo "Warning: could not disable ${MANAGED_SWAP_PATH}; it remains active and was not removed"
      return 0
    fi
  fi
  if rm -f -- "${MANAGED_SWAP_PATH}"; then
    SWAP_SETUP_PENDING="false"
    MANAGED_SWAP_PATH=""
  else
    echo "Warning: could not remove incomplete swap file ${MANAGED_SWAP_PATH}"
  fi
  return 0
}

cleanup() {
  local exit_code=$?
  trap - EXIT
  set +e
  cleanup_pending_swap
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
  exit "${exit_code}"
}

register_swap_in_fstab() {
  local entry_type="" entry_options="" entry fstab_temp findmnt_help
  if [[ -L /etc/fstab || ( -e /etc/fstab && ! -f /etc/fstab ) ]]; then
    echo "Warning: /etc/fstab is not a regular file; it was left unchanged"
    return 1
  fi
  entry="$(awk -v swap_file="${SWAP_FILE}" '
    $1 == swap_file { print $3, $4; exit }
  ' /etc/fstab 2>/dev/null || true)"
  read -r entry_type entry_options <<<"${entry}" || true

  if [[ -n "${entry_type:-}" ]]; then
    if [[ "${entry_type}" != "swap" ]]; then
      echo "Warning: ${SWAP_FILE} already has a non-swap entry in /etc/fstab; it was left unchanged"
      return 1
    fi
    if [[ -z "${entry_options:-}" ]]; then
      echo "Warning: the existing ${SWAP_FILE} entry in /etc/fstab is incomplete; it was left unchanged"
      return 1
    fi
    case ",${entry_options:-}," in
      *,noauto,*)
        echo "Warning: the existing ${SWAP_FILE} entry in /etc/fstab contains noauto; it was left unchanged"
        return 1
        ;;
    esac
    return 0
  fi

  if ! fstab_temp="$(mktemp /etc/fstab.olcserver.XXXXXX)"; then
    return 1
  fi
  if [[ -e /etc/fstab ]]; then
    if ! cp --preserve=mode,ownership,timestamps /etc/fstab "${fstab_temp}"; then
      rm -f -- "${fstab_temp}"
      return 1
    fi
  elif ! install -m 0644 /dev/null "${fstab_temp}"; then
    rm -f -- "${fstab_temp}"
    return 1
  fi

  if ! printf '\n%s none swap sw,nofail 0 0\n' "${SWAP_FILE}" >>"${fstab_temp}"; then
    rm -f -- "${fstab_temp}"
    return 1
  fi
  findmnt_help="$(findmnt --help 2>&1 || true)"
  if [[ "${findmnt_help}" == *"--verify"* ]]; then
    if ! findmnt --verify --tab-file "${fstab_temp}" >/dev/null; then
      echo "Warning: the updated /etc/fstab did not pass validation"
      rm -f -- "${fstab_temp}"
      return 1
    fi
  elif ! findmnt --fstab --tab-file "${fstab_temp}" >/dev/null; then
    echo "Warning: the updated /etc/fstab did not pass validation"
    rm -f -- "${fstab_temp}"
    return 1
  fi
  if ! mv -f -- "${fstab_temp}" /etc/fstab; then
    rm -f -- "${fstab_temp}"
    return 1
  fi
  return 0
}

ensure_build_swap() {
  local memory_kib swap_kib minimum_kib missing_kib swap_size_mb disk_available_kib filesystem_type orphaned_swap

  orphaned_swap="$(find / -maxdepth 1 -type f -name 'swapfile.olcserver.*' -print -quit 2>/dev/null || true)"
  if [[ -n "${orphaned_swap}" ]]; then
    echo "Warning: found a swap file from an interrupted installer run: ${orphaned_swap}"
    echo "Inspect it before removal with: swapon --show; ls -lh ${orphaned_swap}"
  fi
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    if systemd-detect-virt --container --quiet 2>/dev/null || systemd-detect-virt --chroot --quiet 2>/dev/null; then
      if [[ "${AUTO_SWAP}" == "true" ]]; then
        echo "Warning: automatic swap is unavailable inside a container or chroot"
      else
        echo "Automatic swap is disabled"
      fi
      echo "Using ${BUILD_JOBS} Go build job(s); increase the host memory limit if the build is killed"
      return
    fi
  fi
  if [[ ! -r /proc/meminfo || ! -r /proc/swaps ]]; then
    echo "Warning: cannot inspect system memory; continuing without automatic swap"
    return
  fi

  memory_kib="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
  swap_kib="$(awk '/^SwapTotal:/ { print $2; exit }' /proc/meminfo)"
  if [[ ! "${memory_kib}" =~ ^[0-9]+$ || ! "${swap_kib}" =~ ^[0-9]+$ ]]; then
    echo "Warning: cannot determine system memory; continuing without automatic swap"
    return
  fi

  minimum_kib=$((MIN_BUILD_MEMORY_MB * 1024))
  if (( memory_kib + swap_kib >= minimum_kib )); then
    return
  fi

  echo "Detected less than ${MIN_BUILD_MEMORY_MB} MB of RAM and swap"
  if [[ "${AUTO_SWAP}" != "true" ]]; then
    echo "Automatic swap is disabled; using ${BUILD_JOBS} Go build job(s)"
    return
  fi
  if swap_file_is_active; then
    echo "Warning: ${SWAP_FILE} is active but total build memory is still below the target"
    return
  fi
  if [[ -e "${SWAP_FILE}" || -L "${SWAP_FILE}" ]]; then
    echo "Warning: ${SWAP_FILE} already exists and was left untouched"
    echo "Using ${BUILD_JOBS} Go build job(s)"
    return
  fi

  filesystem_type="$(findmnt -nro FSTYPE -T / 2>/dev/null || true)"
  case "${filesystem_type}" in
    ext2|ext3|ext4|xfs) ;;
    *)
      echo "Warning: automatic swap is not supported on ${filesystem_type:-this filesystem}"
      echo "Using ${BUILD_JOBS} Go build job(s)"
      return
      ;;
  esac

  missing_kib=$((minimum_kib - memory_kib - swap_kib))
  swap_size_mb=$(((missing_kib + 1023) / 1024))
  swap_size_mb=$((((swap_size_mb + 1023) / 1024) * 1024))
  disk_available_kib="$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  if [[ ! "${disk_available_kib}" =~ ^[0-9]+$ ]]; then
    echo "Warning: cannot determine free disk space; continuing without automatic swap"
    return
  fi
  if (( disk_available_kib < swap_size_mb * 1024 + 2 * 1024 * 1024 )); then
    echo "Warning: not enough disk space to create ${swap_size_mb} MB of swap"
    echo "Using ${BUILD_JOBS} Go build job(s)"
    return
  fi

  echo "Creating ${swap_size_mb} MB of swap at ${SWAP_FILE}"
  if ! MANAGED_SWAP_PATH="$(mktemp /swapfile.olcserver.XXXXXX)"; then
    echo "Warning: could not create a temporary swap file; continuing without automatic swap"
    return
  fi
  SWAP_SETUP_PENDING="true"
  if ! chmod 0600 "${MANAGED_SWAP_PATH}"; then
    echo "Warning: could not secure swap; using ${BUILD_JOBS} Go build job(s)"
    cleanup_pending_swap
    return
  fi
  if ! dd if=/dev/zero of="${MANAGED_SWAP_PATH}" bs=1M count="${swap_size_mb}"; then
    echo "Warning: could not allocate swap; using ${BUILD_JOBS} Go build job(s)"
    cleanup_pending_swap
    return
  fi
  if ! mkswap "${MANAGED_SWAP_PATH}" >/dev/null; then
    echo "Warning: could not format swap; using ${BUILD_JOBS} Go build job(s)"
    cleanup_pending_swap
    return
  fi
  if ! ln -- "${MANAGED_SWAP_PATH}" "${SWAP_FILE}"; then
    echo "Warning: ${SWAP_FILE} appeared during setup and was left untouched"
    cleanup_pending_swap
    return
  fi
  local temporary_swap_path="${MANAGED_SWAP_PATH}"
  MANAGED_SWAP_PATH="${SWAP_FILE}"
  if ! rm -f -- "${temporary_swap_path}"; then
    echo "Warning: could not finalize the swap file; using ${BUILD_JOBS} Go build job(s)"
    cleanup_pending_swap
    rm -f -- "${temporary_swap_path}" || true
    return
  fi
  if ! swapon "${SWAP_FILE}"; then
    echo "Warning: could not enable swap; using ${BUILD_JOBS} Go build job(s)"
    cleanup_pending_swap
    return
  fi

  if register_swap_in_fstab; then
    SWAP_SETUP_PENDING="false"
    MANAGED_SWAP_PATH=""
    echo "Swap enabled and registered in /etc/fstab"
  else
    echo "Warning: swap will be used for this installation only because /etc/fstab was not updated"
  fi
}

go_build() {
  GOMAXPROCS="${BUILD_JOBS}" /usr/local/go/bin/go build -p "${BUILD_JOBS}" "$@"
}

trap cleanup EXIT

export DEBIAN_FRONTEND=noninteractive
"${PKG_UPDATE[@]}"
"${PKG_INSTALL[@]}" "${BASE_PACKAGES[@]}"
if ! exec 9>"${INSTALL_LOCK_FILE}"; then
  echo "Could not create the installer lock at ${INSTALL_LOCK_FILE}"
  exit 1
fi
if ! flock -n 9; then
  echo "Another Olc Server installation is already running"
  exit 1
fi
ensure_build_swap

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

echo "[1/6] Installing Go ${GO_VERSION}"
curl --fail --location --retry 3 "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o "${WORK_DIR}/go.tar.gz"
rm -rf /usr/local/go
tar -C /usr/local -xzf "${WORK_DIR}/go.tar.gz"

echo "[2/6] Building olcrtc"
git clone --depth 1 --recurse-submodules --shallow-submodules --branch "${OLCRTC_REF}" "${OLCRTC_REPOSITORY}" "${WORK_DIR}/olcrtc"
(
  cd "${WORK_DIR}/olcrtc"
  go_build -trimpath -ldflags="-s -w" -o "${WORK_DIR}/olcrtc-bin" ./cmd/olcrtc
)

echo "[3/6] Building Olc Server"
if [[ -f "$(dirname "$0")/go.mod" ]]; then
  cp -R "$(dirname "$0")/." "${WORK_DIR}/olcserver"
else
  git clone --depth 1 --branch "${OLCSERVER_REF}" "${OLCSERVER_REPOSITORY}" "${WORK_DIR}/olcserver"
fi
(
  cd "${WORK_DIR}/olcserver"
  go_build -trimpath -ldflags="-s -w" -o "${WORK_DIR}/olcserver-bin" .
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

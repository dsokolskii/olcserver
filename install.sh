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
CERTBOT_VERSION="${OLCSERVER_CERTBOT_VERSION:-5.4.0}"
AUTO_SWAP="${OLCSERVER_AUTO_SWAP:-true}"
MIN_BUILD_MEMORY_MB="${OLCSERVER_MIN_BUILD_MEMORY_MB:-4096}"
MIN_BUILD_SWAP_MB="${OLCSERVER_MIN_BUILD_SWAP_MB:-4096}"
BUILD_JOBS="${OLCSERVER_BUILD_JOBS:-1}"
BUILD_GOGC="${OLCSERVER_BUILD_GOGC:-20}"
ALLOW_LOW_MEMORY="${OLCSERVER_ALLOW_LOW_MEMORY_BUILD:-false}"
BUILD_MEMORY_MARGIN_MB=512
SWAP_ACCOUNTING_TOLERANCE_KIB=64
RAM_CAPACITY_TOLERANCE_MB=0
PRIMARY_SWAP_FILE="/swapfile"
SUPPLEMENTAL_SWAP_FILE="/olcserver.swap"
SWAP_FILE="${PRIMARY_SWAP_FILE}"
INSTALL_LOCK_FILE="/run/olcserver-install.lock"
LISTEN_ADDRESS="127.0.0.1"
CERTBOT_ROOT="${INSTALL_ROOT}/certbot"
CERTBOT_BIN="${CERTBOT_ROOT}/bin/certbot"
ACME_WEBROOT="/var/www/olcserver-acme"
NGINX_SITE_PATH="/etc/nginx/conf.d/olcserver.conf"
REMOVE_DEFAULT_NGINX_SITE="false"
EXISTING_CERT_NAME=""
MANAGED_SWAP_PATH=""
SWAP_SETUP_PENDING="false"
WORK_DIR=""
MEMORY_TOTAL_KIB=0
MEMORY_AVAILABLE_KIB=0
SWAP_TOTAL_KIB=0
SWAP_FREE_KIB=0
EFFECTIVE_MEMORY_TOTAL_KIB=0
EFFECTIVE_MEMORY_AVAILABLE_KIB=0
EFFECTIVE_SWAP_TOTAL_KIB=0
EFFECTIVE_SWAP_FREE_KIB=0
EFFECTIVE_HEADROOM_KIB=0
CGROUP_SWAP_LIMIT_KIB=-1
CGROUP_SWAP_REMAINING_KIB=-1
CGROUP_V2_PATH=""
CGROUP_LIMITS_FOUND="false"

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
SYSTEMCTL_BIN="$(command -v systemctl)"

case "${AUTO_SWAP}" in
  true|false) ;;
  *) echo "OLCSERVER_AUTO_SWAP must be true or false"; exit 1 ;;
esac
case "${ALLOW_LOW_MEMORY}" in
  true|false) ;;
  *) echo "OLCSERVER_ALLOW_LOW_MEMORY_BUILD must be true or false"; exit 1 ;;
esac
if [[ ! "${MIN_BUILD_MEMORY_MB}" =~ ^[1-9][0-9]*$ ]] || (( MIN_BUILD_MEMORY_MB > 65536 )); then
  echo "OLCSERVER_MIN_BUILD_MEMORY_MB must be an integer between 1 and 65536"
  exit 1
fi
if [[ ! "${MIN_BUILD_SWAP_MB}" =~ ^[1-9][0-9]*$ ]] || (( MIN_BUILD_SWAP_MB > 65536 )); then
  echo "OLCSERVER_MIN_BUILD_SWAP_MB must be an integer between 1 and 65536"
  exit 1
fi
if [[ ! "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] || (( BUILD_JOBS > 256 )); then
  echo "OLCSERVER_BUILD_JOBS must be an integer between 1 and 256"
  exit 1
fi
if [[ ! "${BUILD_GOGC}" =~ ^[1-9][0-9]*$ ]] || (( BUILD_GOGC > 100 )); then
  echo "OLCSERVER_BUILD_GOGC must be an integer between 1 and 100"
  exit 1
fi
if [[ ! "${CERTBOT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "OLCSERVER_CERTBOT_VERSION must be a semantic version such as 5.4.0"
  exit 1
fi
if (( MIN_BUILD_MEMORY_MB == 4096 )); then
  RAM_CAPACITY_TOLERANCE_MB=256
fi
if (( MIN_BUILD_SWAP_MB == 4096 )); then
  SWAP_ACCOUNTING_TOLERANCE_KIB=16384
fi

if command -v apt-get >/dev/null 2>&1; then
  PKG_UPDATE=(apt-get update)
  PKG_INSTALL=(apt-get install -y --no-install-recommends)
  BASE_PACKAGES=(ca-certificates curl git tar iproute2 util-linux)
  WEB_PACKAGES=(nginx python3 python3-dev python3-venv gcc)
elif command -v dnf >/dev/null 2>&1; then
  PKG_UPDATE=(dnf makecache)
  PKG_INSTALL=(dnf install -y)
  BASE_PACKAGES=(ca-certificates curl git tar iproute util-linux)
  WEB_PACKAGES=(nginx python3 python3-devel gcc)
elif command -v yum >/dev/null 2>&1; then
  PKG_UPDATE=(yum makecache)
  PKG_INSTALL=(yum install -y)
  BASE_PACKAGES=(ca-certificates curl git tar iproute util-linux)
  WEB_PACKAGES=(nginx python3 python3-devel gcc)
elif command -v pacman >/dev/null 2>&1; then
  PKG_UPDATE=(pacman -Sy --noconfirm)
  PKG_INSTALL=(pacman -S --noconfirm --needed)
  BASE_PACKAGES=(ca-certificates curl git tar iproute2 util-linux)
  WEB_PACKAGES=(nginx python python-pip gcc)
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

read_build_memory_state() {
  local memory_values cgroup_relative cgroup_dir limit_bytes current_bytes
  local limit_kib current_kib remaining_kib
  local unlimited_threshold=1152921504606846976

  if [[ ! -r /proc/meminfo || ! -r /proc/swaps ]]; then
    return 1
  fi
  memory_values="$(awk '
    /^MemTotal:/ { memory_total = $2 }
    /^MemAvailable:/ { memory_available = $2; memory_available_seen = 1 }
    /^MemFree:/ { memory_free = $2 }
    /^Buffers:/ { buffers = $2 }
    /^Cached:/ { cached = $2 }
    /^SwapTotal:/ { swap_total = $2 }
    /^SwapFree:/ { swap_free = $2 }
    END {
      if (!memory_available_seen) memory_available = memory_free + buffers + cached
      print memory_total + 0, memory_available + 0, swap_total + 0, swap_free + 0
    }
  ' /proc/meminfo 2>/dev/null || true)"
  if ! read -r MEMORY_TOTAL_KIB MEMORY_AVAILABLE_KIB SWAP_TOTAL_KIB SWAP_FREE_KIB <<<"${memory_values}"; then
    return 1
  fi
  if [[ ! "${MEMORY_TOTAL_KIB}" =~ ^[0-9]+$ || ! "${MEMORY_AVAILABLE_KIB}" =~ ^[0-9]+$ \
    || ! "${SWAP_TOTAL_KIB}" =~ ^[0-9]+$ || ! "${SWAP_FREE_KIB}" =~ ^[0-9]+$ \
    || "${MEMORY_TOTAL_KIB}" == "0" ]]; then
    return 1
  fi

  EFFECTIVE_MEMORY_TOTAL_KIB="${MEMORY_TOTAL_KIB}"
  EFFECTIVE_MEMORY_AVAILABLE_KIB="${MEMORY_AVAILABLE_KIB}"
  EFFECTIVE_SWAP_TOTAL_KIB="${SWAP_TOTAL_KIB}"
  EFFECTIVE_SWAP_FREE_KIB="${SWAP_FREE_KIB}"
  CGROUP_SWAP_LIMIT_KIB=-1
  CGROUP_SWAP_REMAINING_KIB=-1
  CGROUP_V2_PATH=""
  CGROUP_LIMITS_FOUND="false"

  cgroup_relative="$(awk -F: '$1 == "0" && $2 == "" { print $3; exit }' /proc/self/cgroup 2>/dev/null || true)"
  if [[ "${cgroup_relative}" == /* ]]; then
    cgroup_dir="/sys/fs/cgroup${cgroup_relative}"
    cgroup_dir="${cgroup_dir%/}"
    [[ -n "${cgroup_dir}" ]] || cgroup_dir="/sys/fs/cgroup"
    if [[ ( "${cgroup_dir}" == "/sys/fs/cgroup" || "${cgroup_dir}" == /sys/fs/cgroup/* ) \
      && -r "${cgroup_dir}/memory.max" ]]; then
      CGROUP_V2_PATH="${cgroup_dir}"
      CGROUP_LIMITS_FOUND="true"
      while [[ "${cgroup_dir}" == "/sys/fs/cgroup" || "${cgroup_dir}" == /sys/fs/cgroup/* ]]; do
        limit_bytes="$(head -n 1 "${cgroup_dir}/memory.max" 2>/dev/null || true)"
        current_bytes="$(head -n 1 "${cgroup_dir}/memory.current" 2>/dev/null || true)"
        if [[ "${limit_bytes}" =~ ^[0-9]+$ ]] && (( limit_bytes < unlimited_threshold )); then
          [[ "${current_bytes}" =~ ^[0-9]+$ ]] || return 1
          limit_kib=$((limit_bytes / 1024))
          if (( limit_kib < EFFECTIVE_MEMORY_TOTAL_KIB )); then
            EFFECTIVE_MEMORY_TOTAL_KIB="${limit_kib}"
          fi
          current_kib=$((current_bytes / 1024))
          remaining_kib=$((limit_kib > current_kib ? limit_kib - current_kib : 0))
          if (( remaining_kib < EFFECTIVE_MEMORY_AVAILABLE_KIB )); then
            EFFECTIVE_MEMORY_AVAILABLE_KIB="${remaining_kib}"
          fi
        fi

        limit_bytes="$(head -n 1 "${cgroup_dir}/memory.swap.max" 2>/dev/null || true)"
        current_bytes="$(head -n 1 "${cgroup_dir}/memory.swap.current" 2>/dev/null || true)"
        if [[ "${limit_bytes}" =~ ^[0-9]+$ ]] && (( limit_bytes < unlimited_threshold )); then
          [[ "${current_bytes}" =~ ^[0-9]+$ ]] || return 1
          limit_kib=$((limit_bytes / 1024))
          if (( limit_kib < EFFECTIVE_SWAP_TOTAL_KIB )); then
            EFFECTIVE_SWAP_TOTAL_KIB="${limit_kib}"
          fi
          if (( CGROUP_SWAP_LIMIT_KIB < 0 || limit_kib < CGROUP_SWAP_LIMIT_KIB )); then
            CGROUP_SWAP_LIMIT_KIB="${limit_kib}"
          fi
          current_kib=$((current_bytes / 1024))
          remaining_kib=$((limit_kib > current_kib ? limit_kib - current_kib : 0))
          if (( remaining_kib < EFFECTIVE_SWAP_FREE_KIB )); then
            EFFECTIVE_SWAP_FREE_KIB="${remaining_kib}"
          fi
          if (( CGROUP_SWAP_REMAINING_KIB < 0 || remaining_kib < CGROUP_SWAP_REMAINING_KIB )); then
            CGROUP_SWAP_REMAINING_KIB="${remaining_kib}"
          fi
        fi

        [[ "${cgroup_dir}" == "/sys/fs/cgroup" ]] && break
        cgroup_dir="${cgroup_dir%/*}"
      done
    fi
  fi

  EFFECTIVE_HEADROOM_KIB=$((EFFECTIVE_MEMORY_AVAILABLE_KIB + EFFECTIVE_SWAP_FREE_KIB))
  return 0
}

build_memory_is_sufficient() {
  local required_memory_kib=$((MIN_BUILD_MEMORY_MB * 1024))
  local required_swap_kib=$((MIN_BUILD_SWAP_MB * 1024))
  local swap_tolerance_kib="${SWAP_ACCOUNTING_TOLERANCE_KIB}"
  local ram_tolerance_kib=$((RAM_CAPACITY_TOLERANCE_MB * 1024))

  (( EFFECTIVE_HEADROOM_KIB >= required_memory_kib )) || return 1
  if (( EFFECTIVE_MEMORY_TOTAL_KIB + ram_tolerance_kib < required_memory_kib \
    && EFFECTIVE_SWAP_TOTAL_KIB + swap_tolerance_kib < required_swap_kib )); then
    return 1
  fi
  return 0
}

print_build_memory_state() {
  echo "Build memory: $((EFFECTIVE_MEMORY_AVAILABLE_KIB / 1024)) MB RAM available + $((EFFECTIVE_SWAP_FREE_KIB / 1024)) MB usable swap free = $((EFFECTIVE_HEADROOM_KIB / 1024)) MB (required ${MIN_BUILD_MEMORY_MB} MB)"
  if (( EFFECTIVE_MEMORY_TOTAL_KIB + RAM_CAPACITY_TOLERANCE_MB * 1024 < MIN_BUILD_MEMORY_MB * 1024 )); then
    echo "Low-RAM build: $((EFFECTIVE_SWAP_TOTAL_KIB / 1024)) MB usable active swap detected (required ${MIN_BUILD_SWAP_MB} MB)"
  fi
}

low_memory_failure() {
  local reason="$1"

  read_build_memory_state || true
  echo "ERROR: insufficient memory for compiling the Go components"
  print_build_memory_state
  echo "Reason: ${reason}"
  if [[ "${ALLOW_LOW_MEMORY}" == "true" ]]; then
    echo "Warning: OLCSERVER_ALLOW_LOW_MEMORY_BUILD=true; attempting the build anyway"
    return 0
  fi
  echo "Installation stopped before compilation. Add RAM or usable swap, then rerun it."
  echo "Diagnostics: free -h; swapon --show; cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max 2>/dev/null"
  echo "Override at your own risk with OLCSERVER_ALLOW_LOW_MEMORY_BUILD=true"
  return 1
}

verify_build_memory() {
  local reason="${1:-the available build memory fell below the required level}"

  if ! read_build_memory_state; then
    low_memory_failure "could not read /proc/meminfo"
    return
  fi
  if build_memory_is_sufficient; then
    return 0
  fi
  low_memory_failure "${reason}"
}

prepare_work_dir() {
  local candidate filesystem_type disk_available_kib

  for candidate in /var/tmp /var/lib; do
    [[ -d "${candidate}" && -w "${candidate}" ]] || continue
    filesystem_type="$(findmnt -nro FSTYPE -T "${candidate}" 2>/dev/null || true)"
    case "${filesystem_type}" in
      ""|tmpfs|ramfs) continue ;;
    esac
    disk_available_kib="$(df -Pk "${candidate}" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
    if [[ ! "${disk_available_kib}" =~ ^[0-9]+$ || "${disk_available_kib}" -lt 2097152 ]]; then
      continue
    fi
    if WORK_DIR="$(mktemp -d "${candidate}/olcserver-install.XXXXXX")"; then
      if ! install -d -m 0700 \
        "${WORK_DIR}/go-tmp" \
        "${WORK_DIR}/go-build-cache" \
        "${WORK_DIR}/go-mod-cache"; then
        rm -rf -- "${WORK_DIR}"
        WORK_DIR=""
        continue
      fi
      export GOTMPDIR="${WORK_DIR}/go-tmp"
      export GOCACHE="${WORK_DIR}/go-build-cache"
      export GOMODCACHE="${WORK_DIR}/go-mod-cache"
      export GOTOOLCHAIN=local
      return 0
    fi
  done

  echo "ERROR: no disk-backed temporary directory with at least 2048 MB free was found"
  return 1
}

ensure_build_swap() {
  local required_memory_kib=$((MIN_BUILD_MEMORY_MB * 1024))
  local required_swap_kib=$((MIN_BUILD_SWAP_MB * 1024))
  local swap_tolerance_kib="${SWAP_ACCOUNTING_TOLERANCE_KIB}"
  local ram_tolerance_kib=$((RAM_CAPACITY_TOLERANCE_MB * 1024))
  local margin_kib=$((BUILD_MEMORY_MARGIN_MB * 1024))
  local missing_headroom_kib missing_swap_kib missing_kib swap_size_mb
  local cgroup_new_swap_kib cgroup_new_swap_mb
  local disk_available_kib disk_required_kib disk_shortfall_kib
  local filesystem_type orphaned_swap temporary_swap_path
  local container_detected="false" chroot_detected="false"

  orphaned_swap="$(find / -maxdepth 1 -type f \
    \( -name 'swapfile.olcserver.*' -o -name 'olcserver.swap.olcserver.*' \) \
    -print -quit 2>/dev/null || true)"
  if [[ -n "${orphaned_swap}" ]]; then
    echo "Warning: found a swap file from an interrupted installer run: ${orphaned_swap}"
    echo "Inspect it before removal with: swapon --show; ls -lh ${orphaned_swap}"
  fi

  if ! read_build_memory_state; then
    low_memory_failure "could not inspect /proc/meminfo"
    return
  fi
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt --container --quiet 2>/dev/null && container_detected="true"
    systemd-detect-virt --chroot --quiet 2>/dev/null && chroot_detected="true"
  fi
  print_build_memory_state

  if [[ "${container_detected}" == "true" && "${CGROUP_LIMITS_FOUND}" != "true" ]]; then
    low_memory_failure "container memory limits could not be read reliably"
    return
  fi
  if build_memory_is_sufficient; then
    return 0
  fi
  if [[ "${AUTO_SWAP}" != "true" ]]; then
    low_memory_failure "automatic swap creation is disabled"
    return
  fi
  if [[ "${container_detected}" == "true" || "${chroot_detected}" == "true" ]]; then
    low_memory_failure "swap must be enabled on the host for a container or chroot"
    return
  fi
  if (( CGROUP_SWAP_LIMIT_KIB >= 0 )); then
    if (( EFFECTIVE_MEMORY_TOTAL_KIB + ram_tolerance_kib < required_memory_kib \
      && CGROUP_SWAP_LIMIT_KIB + swap_tolerance_kib < required_swap_kib )); then
      low_memory_failure "the cgroup swap limit is below ${MIN_BUILD_SWAP_MB} MB"
      return
    fi
    if (( CGROUP_SWAP_REMAINING_KIB >= 0 \
      && EFFECTIVE_MEMORY_AVAILABLE_KIB + CGROUP_SWAP_REMAINING_KIB < required_memory_kib )); then
      low_memory_failure "the cgroup memory and swap limits cannot provide ${MIN_BUILD_MEMORY_MB} MB"
      return
    fi
  fi

  SWAP_FILE="${PRIMARY_SWAP_FILE}"
  if swap_file_is_active "${SWAP_FILE}" || [[ -e "${SWAP_FILE}" || -L "${SWAP_FILE}" ]]; then
    echo "${SWAP_FILE} already exists and will be left untouched"
    SWAP_FILE="${SUPPLEMENTAL_SWAP_FILE}"
  fi
  if swap_file_is_active "${SWAP_FILE}" || [[ -e "${SWAP_FILE}" || -L "${SWAP_FILE}" ]]; then
    low_memory_failure "both ${PRIMARY_SWAP_FILE} and ${SUPPLEMENTAL_SWAP_FILE} already exist, but usable memory is still insufficient"
    return
  fi

  filesystem_type="$(findmnt -nro FSTYPE -T / 2>/dev/null || true)"
  case "${filesystem_type}" in
    ext2|ext3|ext4|xfs) ;;
    *)
      low_memory_failure "automatic swap is not supported on ${filesystem_type:-this filesystem}"
      return
      ;;
  esac

  missing_headroom_kib=$((required_memory_kib + margin_kib - EFFECTIVE_HEADROOM_KIB))
  (( missing_headroom_kib > 0 )) || missing_headroom_kib=0
  missing_swap_kib=0
  if (( EFFECTIVE_MEMORY_TOTAL_KIB + ram_tolerance_kib < required_memory_kib \
    && EFFECTIVE_SWAP_TOTAL_KIB + swap_tolerance_kib < required_swap_kib )); then
    missing_swap_kib=$((required_swap_kib - swap_tolerance_kib - EFFECTIVE_SWAP_TOTAL_KIB))
  fi
  missing_kib="${missing_headroom_kib}"
  (( missing_swap_kib <= missing_kib )) || missing_kib="${missing_swap_kib}"
  swap_size_mb=$(((missing_kib + 1023) / 1024))
  swap_size_mb=$((((swap_size_mb + 1023) / 1024) * 1024))
  (( swap_size_mb > 0 )) || swap_size_mb=1024
  if (( CGROUP_SWAP_REMAINING_KIB >= 0 )); then
    cgroup_new_swap_kib=$((CGROUP_SWAP_REMAINING_KIB - EFFECTIVE_SWAP_FREE_KIB))
    if (( cgroup_new_swap_kib <= 0 )); then
      low_memory_failure "the cgroup has no usable swap allowance left"
      return
    fi
    cgroup_new_swap_mb=$(((cgroup_new_swap_kib + 1023) / 1024 + 1))
    if (( swap_size_mb > cgroup_new_swap_mb )); then
      swap_size_mb="${cgroup_new_swap_mb}"
    fi
  fi

  disk_available_kib="$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  if [[ ! "${disk_available_kib}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: free disk space on / could not be determined"
    return 1
  fi
  disk_required_kib=$((swap_size_mb * 1024 + 2 * 1024 * 1024))
  if (( disk_available_kib < disk_required_kib )); then
    disk_shortfall_kib=$((disk_required_kib - disk_available_kib))
    echo "ERROR: insufficient disk space for swap and compilation"
    echo "Disk space on /: $((disk_available_kib / 1024)) MB available, $((disk_required_kib / 1024)) MB required, $(((disk_shortfall_kib + 1023) / 1024)) MB short"
    echo "Current Go caches from earlier attempts, if present:"
    du -sh /root/.cache/go-build /root/go/pkg/mod 2>/dev/null || true
    if [[ -x /usr/local/go/bin/go ]]; then
      echo "They can be recreated and removed with: /usr/local/go/bin/go clean -cache -modcache"
    fi
    echo "Package-manager caches may also be cleaned before retrying"
    return 1
  fi

  echo "Creating ${swap_size_mb} MB of swap at ${SWAP_FILE}"
  if ! MANAGED_SWAP_PATH="$(mktemp "${SWAP_FILE}.olcserver.XXXXXX")"; then
    low_memory_failure "a temporary swap file could not be created"
    return
  fi
  SWAP_SETUP_PENDING="true"
  if ! chmod 0600 "${MANAGED_SWAP_PATH}"; then
    cleanup_pending_swap
    low_memory_failure "the swap file could not be secured"
    return
  fi
  if ! dd if=/dev/zero of="${MANAGED_SWAP_PATH}" bs=1M count="${swap_size_mb}"; then
    cleanup_pending_swap
    low_memory_failure "the swap file could not be allocated"
    return
  fi
  if ! mkswap "${MANAGED_SWAP_PATH}" >/dev/null; then
    cleanup_pending_swap
    low_memory_failure "the swap file could not be formatted"
    return
  fi
  if ! ln -- "${MANAGED_SWAP_PATH}" "${SWAP_FILE}"; then
    cleanup_pending_swap
    low_memory_failure "${SWAP_FILE} appeared during setup and was left untouched"
    return
  fi
  temporary_swap_path="${MANAGED_SWAP_PATH}"
  MANAGED_SWAP_PATH="${SWAP_FILE}"
  if ! rm -f -- "${temporary_swap_path}"; then
    cleanup_pending_swap
    rm -f -- "${temporary_swap_path}" || true
    low_memory_failure "the swap file could not be finalized"
    return
  fi
  if ! swapon "${SWAP_FILE}"; then
    cleanup_pending_swap
    low_memory_failure "the kernel or VPS provider rejected swapon"
    return
  fi

  if ! read_build_memory_state || ! build_memory_is_sufficient; then
    low_memory_failure "swap was enabled, but the effective memory target was not reached"
    return
  fi
  print_build_memory_state
  if register_swap_in_fstab; then
    SWAP_SETUP_PENDING="false"
    MANAGED_SWAP_PATH=""
    echo "Swap enabled and registered in /etc/fstab"
  else
    echo "Warning: swap will be used for this installation only because /etc/fstab was not updated"
  fi
}

go_build() {
  local build_status

  if CGO_ENABLED=0 GOMAXPROCS="${BUILD_JOBS}" GOGC="${BUILD_GOGC}" \
    /usr/local/go/bin/go build -p "${BUILD_JOBS}" "$@"; then
    return 0
  else
    build_status=$?
  fi

  echo "Go build failed (exit ${build_status}). Current memory diagnostics:"
  if read_build_memory_state; then
    print_build_memory_state
  fi
  if [[ -n "${CGROUP_V2_PATH}" && -r "${CGROUP_V2_PATH}/memory.events" ]]; then
    echo "Cgroup memory events:"
    awk '/^(oom|oom_kill|oom_group_kill) / { print }' "${CGROUP_V2_PATH}/memory.events" || true
  fi
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -k -b --no-pager 2>/dev/null \
      | grep -Ei 'out of memory|oom-kill|killed process' \
      | tail -n 20 || true
  fi
  return "${build_status}"
}

web_ports_are_owned_by_nginx() {
  awk '
    /:(80|443)[[:space:]]/ {
      found = 1
      if ($0 !~ /nginx/) external = 1
    }
    END { exit(found && !external ? 0 : 1) }
  ' <<<"${LISTENING_SOCKETS}"
}

nginx_packaged_default_site_is_enabled() {
  local default_site="/etc/nginx/sites-enabled/default"

  [[ -e "${default_site}" ]] || return 1
  grep -Eq '^[[:space:]]*listen[[:space:]]+80[[:space:]]+default_server;' \
    "${default_site}" || return 1
  grep -Eq '^[[:space:]]*root[[:space:]]+/var/www/html;' \
    "${default_site}" || return 1
  grep -Eq '^[[:space:]]*server_name[[:space:]]+_;' \
    "${default_site}" || return 1
  ! grep -Eq '^[[:space:]]*proxy_pass[[:space:]]' "${default_site}"
}

write_http_challenge_proxy() {
  cat >"${NGINX_SITE_PATH}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${CERT_NAME};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
        default_type text/plain;
    }

    location / {
        return 503;
    }
}
EOF
}

write_https_proxy() {
  cat >"${NGINX_SITE_PATH}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${CERT_NAME};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${CERT_NAME};

    ssl_certificate /etc/letsencrypt/live/${CERT_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CERT_NAME}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
}

install_certificate_renewal_timer() {
  cat >/etc/systemd/system/olcserver-certbot-renew.service <<EOF
[Unit]
Description=Renew the Olc Server TLS certificate
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CERTBOT_BIN} renew --quiet --deploy-hook "${SYSTEMCTL_BIN} reload nginx"
EOF

  cat >/etc/systemd/system/olcserver-certbot-renew.timer <<EOF
[Unit]
Description=Renew the Olc Server TLS certificate twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
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
if ! ensure_build_swap; then
  exit 1
fi

PORTS_BUSY="false"
LISTENING_SOCKETS="$(ss -ltnp 2>/dev/null || true)"
if grep -Eq '(^|:)80[[:space:]]|(^|:)443[[:space:]]' <<<"${LISTENING_SOCKETS}"; then
  PORTS_BUSY="true"
fi

if [[ -f "${NGINX_SITE_PATH}" ]]; then
  EXISTING_CERT_NAME="$(awk '
    $1 == "server_name" {
      gsub(/;/, "", $2)
      print $2
      exit
    }
  ' "${NGINX_SITE_PATH}" 2>/dev/null || true)"
elif [[ -f /etc/nginx/sites-available/olcserver ]]; then
  EXISTING_CERT_NAME="$(awk '
    $1 == "server_name" {
      gsub(/;/, "", $2)
      print $2
      exit
    }
  ' /etc/nginx/sites-available/olcserver 2>/dev/null || true)"
fi

if [[ "${PORTS_BUSY}" == "true" ]]; then
  if systemctl is-active --quiet nginx 2>/dev/null && web_ports_are_owned_by_nginx; then
    echo "Existing nginx listener detected; Olc Server will be added as an HTTPS reverse proxy"
    if nginx_packaged_default_site_is_enabled; then
      REMOVE_DEFAULT_NGINX_SITE="true"
      echo "The packaged nginx welcome site will be removed"
    fi
  else
    echo "ERROR: port 80 or 443 is occupied by a service other than nginx"
    echo "Olc Server will not expose the admin panel over plain HTTP on :${PANEL_PORT}"
    awk '/:(80|443)[[:space:]]/' <<<"${LISTENING_SOCKETS}"
    exit 1
  fi
fi

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "${SERVER_IP}" ]]; then
  echo "ERROR: could not determine the server IP address"
  exit 1
fi
CERT_NAME="${DOMAIN:-${EXISTING_CERT_NAME:-${SERVER_IP}}}"
if [[ ! "${CERT_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*[A-Za-z0-9]$ ]]; then
  echo "ERROR: invalid certificate name: ${CERT_NAME}"
  exit 1
fi
CERT_IS_IP="false"
if [[ "${CERT_NAME}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "${CERT_NAME}" == *:* ]]; then
  CERT_IS_IP="true"
fi

if ! prepare_work_dir; then
  exit 1
fi

echo "[1/6] Installing Go ${GO_VERSION}"
curl --fail --location --retry 3 "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o "${WORK_DIR}/go.tar.gz"
rm -rf /usr/local/go
tar -C /usr/local -xzf "${WORK_DIR}/go.tar.gz"

echo "[2/6] Building olcrtc"
git clone --depth 1 --recurse-submodules --shallow-submodules --branch "${OLCRTC_REF}" "${OLCRTC_REPOSITORY}" "${WORK_DIR}/olcrtc"
if ! verify_build_memory "available memory dropped below the build requirement before compiling olcrtc"; then
  exit 1
fi
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
if ! verify_build_memory "available memory dropped below the build requirement before compiling Olc Server"; then
  exit 1
fi
(
  cd "${WORK_DIR}/olcserver"
  go_build -trimpath -ldflags="-s -w" -o "${WORK_DIR}/olcserver-bin" .
)

echo "[4/6] Installing services"
"${PKG_INSTALL[@]}" "${WEB_PACKAGES[@]}"
if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
  useradd --system --home-dir "${DATA_ROOT}" --shell /usr/sbin/nologin "${SERVICE_USER}"
fi
install -d -m 0755 "${INSTALL_ROOT}"
install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0700 "${DATA_ROOT}"
install -d -m 0755 "${ACME_WEBROOT}/.well-known/acme-challenge"
install -m 0755 "${WORK_DIR}/olcrtc-bin" /usr/local/bin/olcrtc
install -m 0755 "${WORK_DIR}/olcserver-bin" /usr/local/bin/olcserver
if ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo "ERROR: Certbot ${CERTBOT_VERSION} requires Python 3.10 or newer"
  exit 1
fi
python3 -m venv "${CERTBOT_ROOT}"
"${CERTBOT_ROOT}/bin/pip" install --disable-pip-version-check --upgrade pip
"${CERTBOT_ROOT}/bin/pip" install --disable-pip-version-check --upgrade \
  "certbot==${CERTBOT_VERSION}"

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
systemctl enable olcserver.service
systemctl restart olcserver.service
sleep 2
systemctl is-active --quiet olcserver.service

install -d -m 0755 /etc/nginx/conf.d
if nginx_packaged_default_site_is_enabled; then
  REMOVE_DEFAULT_NGINX_SITE="true"
fi
if [[ "${REMOVE_DEFAULT_NGINX_SITE}" == "true" ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi
rm -f /etc/nginx/sites-enabled/olcserver /etc/nginx/sites-available/olcserver
write_http_challenge_proxy
nginx -t
systemctl enable --now nginx
systemctl reload nginx

CERTBOT_EMAIL_ARGS=(--register-unsafely-without-email)
if [[ -n "${LETSENCRYPT_EMAIL}" ]]; then
  CERTBOT_EMAIL_ARGS=(--email "${LETSENCRYPT_EMAIL}")
fi
CERTBOT_NAME_ARGS=(-d "${CERT_NAME}")
CERTBOT_PROFILE_ARGS=()
if [[ "${CERT_IS_IP}" == "true" ]]; then
  CERTBOT_NAME_ARGS=(--ip-address "${CERT_NAME}")
  CERTBOT_PROFILE_ARGS=(--preferred-profile shortlived)
fi
"${CERTBOT_BIN}" certonly \
  --webroot \
  --webroot-path "${ACME_WEBROOT}" \
  --cert-name "${CERT_NAME}" \
  --non-interactive \
  --agree-tos \
  "${CERTBOT_EMAIL_ARGS[@]}" \
  "${CERTBOT_PROFILE_ARGS[@]}" \
  "${CERTBOT_NAME_ARGS[@]}"

write_https_proxy
nginx -t
systemctl reload nginx
install_certificate_renewal_timer
systemctl daemon-reload
systemctl enable --now olcserver-certbot-renew.timer

if [[ "${CERT_NAME}" == *:* ]]; then
  PANEL_URL="https://[${CERT_NAME}]"
else
  PANEL_URL="https://${CERT_NAME}"
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
echo "HTTP on port 80 redirects to HTTPS on port 443"
echo "HTTPS certificate renewals are handled by olcserver-certbot-renew.timer"
echo "Service logs: journalctl -u olcserver -f"
echo "============================================================"

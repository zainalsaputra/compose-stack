#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ROUTE_DIR="${SCRIPT_DIR}/runtime/nginx/apps"
NGINX_CONTAINER="jenkins-nginx"

log() { printf '[compose-stack] %s\n' "$*"; }
die() { printf '[compose-stack] ERROR: %s\n' "$*" >&2; exit 1; }

read_env_value() {
  local key="$1" fallback="$2" value
  value="$(awk -F= -v wanted="${key}" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "${ENV_FILE}" 2>/dev/null || true)"
  value="${value%$'\r'}"; value="${value%\"}"; value="${value#\"}"
  printf '%s' "${value:-${fallback}}"
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash app-route.sh register --host <hostname> --upstream <service:port>
  sudo bash app-route.sh remove --host <hostname>
  bash app-route.sh list

Examples:
  sudo bash app-route.sh register \
    --host orders.apps.example.com \
    --upstream orders:3000

  sudo bash app-route.sh remove --host orders.apps.example.com
EOF
}

validate_host() {
  local host="$1" suffix
  [[ "${host}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Invalid hostname: ${host}"
  suffix="$(read_env_value APP_DOMAIN_SUFFIX '')"
  if [[ -n "${suffix}" && "${suffix}" != "apps.example.com" ]]; then
    [[ "${host}" == *."${suffix}" ]] || die "Hostname must be under APP_DOMAIN_SUFFIX=${suffix}."
  fi
}

validate_upstream() {
  local upstream="$1"
  [[ "${upstream}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*:[0-9]{1,5}$ ]] || die "Upstream must use service:port format, for example app:3000."
  local port="${upstream##*:}"
  ((port >= 1 && port <= 65535)) || die "Upstream port must be between 1 and 65535."
}

safe_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '-'
}

reload_nginx() {
  docker exec "${NGINX_CONTAINER}" nginx -t >/dev/null || die "Generated Nginx configuration is invalid."
  docker exec "${NGINX_CONTAINER}" nginx -s reload >/dev/null
  log "Nginx configuration reloaded."
}

register_route() {
  local host="$1" upstream="$2" file temp
  validate_host "${host}"
  validate_upstream "${upstream}"
  install -d -m 0755 "${ROUTE_DIR}"
  file="${ROUTE_DIR}/$(safe_name "${host}").conf"
  temp="$(mktemp "${file}.XXXXXX")"

  cat > "${temp}" <<EOF
server {
    listen 80;
    server_name ${host};

    location / {
        proxy_pass http://${upstream};
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  chmod 0644 "${temp}"
  mv "${temp}" "${file}"

  if ! reload_nginx; then
    rm -f "${file}"
    die "Route registration failed."
  fi
  log "Registered ${host} -> http://${upstream}."
}

remove_route() {
  local host="$1" file
  validate_host "${host}"
  file="${ROUTE_DIR}/$(safe_name "${host}").conf"
  [[ -f "${file}" ]] || die "No route found for ${host}."
  rm -f "${file}"
  reload_nginx
  log "Removed route for ${host}."
}

list_routes() {
  if [[ ! -d "${ROUTE_DIR}" ]] || ! compgen -G "${ROUTE_DIR}/*.conf" >/dev/null; then
    log "No application routes registered."
    return 0
  fi
  grep -hE '^[[:space:]]*(server_name|proxy_pass)' "${ROUTE_DIR}"/*.conf | sed 's/^[[:space:]]*//'
}

[[ $# -ge 1 ]] || { usage; exit 1; }
command="$1"; shift

case "${command}" in
  register)
    host=""; upstream=""
    while (($# > 0)); do
      case "$1" in
        --host) host="${2:-}"; shift 2 ;;
        --upstream) upstream="${2:-}"; shift 2 ;;
        *) die "Unknown option: $1" ;;
      esac
    done
    [[ -n "${host}" && -n "${upstream}" ]] || die "register requires --host and --upstream."
    [[ "${EUID}" -eq 0 ]] || die "register requires root privileges."
    register_route "${host}" "${upstream}"
    ;;
  remove)
    host=""
    while (($# > 0)); do
      case "$1" in
        --host) host="${2:-}"; shift 2 ;;
        *) die "Unknown option: $1" ;;
      esac
    done
    [[ -n "${host}" ]] || die "remove requires --host."
    [[ "${EUID}" -eq 0 ]] || die "remove requires root privileges."
    remove_route "${host}"
    ;;
  list) list_routes ;;
  -h|--help|help) usage ;;
  *) usage; die "Unknown command: ${command}" ;;
esac

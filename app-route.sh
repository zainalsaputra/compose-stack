#!/usr/bin/env bash

set -Eeuo pipefail

NGINX_CONTAINER="${NGINX_CONTAINER:-jenkins-nginx}"
ROUTE_MOUNT_DEST="/etc/nginx/app-routes"

log() { printf '[compose-stack] %s\n' "$*"; }
die() { printf '[compose-stack] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  app-route.sh register --host <hostname> --upstream <service:port>
  app-route.sh remove --host <hostname>
  app-route.sh list

Examples:
  app-route.sh register \
    --host orders.apps.example.com \
    --upstream orders:3000

  app-route.sh remove --host orders.apps.example.com
EOF
}

validate_host() {
  local host="$1" suffix="${APP_DOMAIN_SUFFIX:-}"
  [[ "${host}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Invalid hostname: ${host}"
  if [[ -n "${suffix}" && "${suffix}" != "apps.example.com" ]]; then
    [[ "${host}" == *."${suffix}" ]] || die "Hostname must be under APP_DOMAIN_SUFFIX=${suffix}."
  fi
}

validate_upstream() {
  local upstream="$1" port
  [[ "${upstream}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*:[0-9]{1,5}$ ]] || die "Upstream must use service:port format, for example app:3000."
  port="${upstream##*:}"
  ((port >= 1 && port <= 65535)) || die "Upstream port must be between 1 and 65535."
}

safe_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '-'
}

route_source_dir() {
  docker inspect "${NGINX_CONTAINER}" \
    --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/app-routes"}}{{.Source}}{{end}}{{end}}'
}

require_route_source() {
  local route_source
  route_source="$(route_source_dir)"
  [[ -n "${route_source}" ]] || die "Cannot find ${ROUTE_MOUNT_DEST} bind mount on ${NGINX_CONTAINER}."
  printf '%s' "${route_source}"
}

nginx_config_valid() {
  docker exec "${NGINX_CONTAINER}" nginx -t >/dev/null 2>&1
}

reload_nginx() {
  nginx_config_valid || return 1
  docker exec "${NGINX_CONTAINER}" nginx -s reload >/dev/null
  log "Nginx configuration reloaded."
}

write_route_file() {
  local route_source="$1" filename="$2" content="$3"
  printf '%s' "${content}" | docker run --rm -i \
    -v "${route_source}:/routes" \
    alpine:3.20 \
    sh -c 'cat > "/routes/$1.new" && chmod 0644 "/routes/$1.new" && if [ -f "/routes/$1" ]; then cp "/routes/$1" "/routes/$1.backup"; fi && mv "/routes/$1.new" "/routes/$1"' \
    sh "${filename}"
}

rollback_route_file() {
  local route_source="$1" filename="$2"
  docker run --rm \
    -v "${route_source}:/routes" \
    alpine:3.20 \
    sh -c 'if [ -f "/routes/$1.backup" ]; then mv "/routes/$1.backup" "/routes/$1"; else rm -f "/routes/$1"; fi' \
    sh "${filename}"
}

cleanup_backup() {
  local route_source="$1" filename="$2"
  docker run --rm \
    -v "${route_source}:/routes" \
    alpine:3.20 \
    rm -f "/routes/${filename}.backup"
}

register_route() {
  local host="$1" upstream="$2" route_source filename config
  validate_host "${host}"
  validate_upstream "${upstream}"
  route_source="$(require_route_source)"
  filename="$(safe_name "${host}").conf"

  config="$(cat <<EOF
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
)"

  write_route_file "${route_source}" "${filename}" "${config}"

  if ! reload_nginx; then
    rollback_route_file "${route_source}" "${filename}"
    nginx_config_valid || true
    die "Route registration failed; previous Nginx configuration was restored."
  fi

  cleanup_backup "${route_source}" "${filename}"
  log "Registered ${host} -> http://${upstream}."
}

remove_route() {
  local host="$1" route_source filename
  validate_host "${host}"
  route_source="$(require_route_source)"
  filename="$(safe_name "${host}").conf"

  docker run --rm \
    -v "${route_source}:/routes" \
    alpine:3.20 \
    sh -c '[ -f "/routes/$1" ] || exit 2; cp "/routes/$1" "/routes/$1.backup"; rm -f "/routes/$1"' \
    sh "${filename}" || die "No route found for ${host}."

  if ! reload_nginx; then
    rollback_route_file "${route_source}" "${filename}"
    die "Route removal failed; previous Nginx configuration was restored."
  fi

  cleanup_backup "${route_source}" "${filename}"
  log "Removed route for ${host}."
}

list_routes() {
  local route_source
  route_source="$(require_route_source)"
  docker run --rm \
    -v "${route_source}:/routes:ro" \
    alpine:3.20 \
    sh -c 'files=$(find /routes -maxdepth 1 -type f -name "*.conf" -print); [ -n "$files" ] || exit 0; grep -hE "^[[:space:]]*(server_name|proxy_pass)" $files | sed "s/^[[:space:]]*//"'
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
    remove_route "${host}"
    ;;
  list) list_routes ;;
  -h|--help|help) usage ;;
  *) usage; die "Unknown command: ${command}" ;;
esac

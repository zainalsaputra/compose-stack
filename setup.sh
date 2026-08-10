#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
RUNTIME_DIR="${SCRIPT_DIR}/runtime"
NGINX_RUNTIME_DIR="${RUNTIME_DIR}/nginx"

STACK_MODE="core"
ACCESS_MODE="local"
ACTION="setup"
ALLOW_DOCKER_INSTALL="true"

log() { printf '[compose-stack] %s\n' "$*"; }
warn() { printf '[compose-stack] WARNING: %s\n' "$*" >&2; }
die() { printf '[compose-stack] ERROR: %s\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '[compose-stack] ERROR: command failed on line %s (exit %s).\n' "${BASH_LINENO[0]}" "${exit_code}" >&2
  exit "${exit_code}"
}
trap on_error ERR

usage() {
  cat <<'EOF'
Usage:
  bash setup.sh [options]

Setup and update operations require root privileges. --check can run without
root when the current user can access Docker.

Options:
  --with-observability  Start Prometheus, Grafana, node-exporter, and cAdvisor.
  --with-https          Use DNS + HTTPS ingress on ports 80/443 (Ubuntu server).
  --check               Validate configuration and check an existing deployment.
  --update              Pull service images, rebuild Jenkins, and apply the stack.
  --skip-docker-install Fail instead of installing Docker when unavailable.
  -h, --help            Show this help message.

Examples:
  sudo bash setup.sh
  sudo bash setup.sh --with-observability
  sudo bash setup.sh --with-https
  sudo bash setup.sh --with-observability --with-https
  bash setup.sh --with-observability --check
  sudo bash setup.sh --with-observability --with-https --update
EOF
}

while (($# > 0)); do
  case "$1" in
    --with-observability) STACK_MODE="observability" ;;
    --with-https) ACCESS_MODE="https" ;;
    --check) ACTION="check" ;;
    --update) ACTION="update" ;;
    --skip-docker-install) ALLOW_DOCKER_INSTALL="false" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

if [[ "${ACTION}" != "check" && "${EUID}" -ne 0 ]]; then
  die "Setup and update operations require root privileges. Use: sudo bash setup.sh"
fi

require_ubuntu() {
  [[ -r /etc/os-release ]] || die "Cannot determine the operating system."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Unsupported operating system '${ID:-unknown}'. This script supports Ubuntu."
  [[ -n "${VERSION_CODENAME:-}" ]] || die "Ubuntu VERSION_CODENAME is unavailable."
}

install_docker() {
  require_ubuntu
  log "Installing Docker Engine and Docker Compose plugin."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg openssl
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
    local key_file
    key_file="$(mktemp)"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "${key_file}"
    gpg --dearmor --yes --output /etc/apt/keyrings/docker.gpg "${key_file}"
    rm -f "${key_file}"
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "${VERSION_CODENAME}" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    [[ "${ACTION}" != "check" ]] || die "Docker Engine and Docker Compose are required for --check."
    [[ "${ALLOW_DOCKER_INSTALL}" == "true" ]] || die "Docker is unavailable and automatic installation was disabled."
    install_docker
  fi
  if [[ "${ACTION}" != "check" ]]; then systemctl enable --now docker; fi
  docker info >/dev/null 2>&1 || die "Docker daemon is unavailable or inaccessible."
}

ensure_host_tools() {
  local missing=()
  for command_name in curl openssl getent; do
    command -v "${command_name}" >/dev/null 2>&1 || missing+=("${command_name}")
  done
  ((${#missing[@]} == 0)) && return 0
  [[ "${ACTION}" != "check" ]] || die "Missing required host utilities: ${missing[*]}"
  require_ubuntu
  apt-get update
  apt-get install -y ca-certificates curl openssl libc-bin
}

read_env_value() {
  local key="$1" fallback="$2" value
  value="$(awk -F= -v wanted="${key}" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "${ENV_FILE}" 2>/dev/null || true)"
  value="${value%$'\r'}"; value="${value%\"}"; value="${value#\"}"
  printf '%s' "${value:-${fallback}}"
}

generate_password() { openssl rand -hex 24; }

replace_env_value() {
  local key="$1" value="$2" temp_file
  temp_file="$(mktemp "${ENV_FILE}.XXXXXX")"
  awk -F= -v wanted="${key}" -v replacement="${value}" '
    BEGIN { replaced = 0 }
    $1 == wanted { print wanted "=" replacement; replaced = 1; next }
    { print }
    END { if (!replaced) print wanted "=" replacement }
  ' "${ENV_FILE}" > "${temp_file}"
  chmod --reference="${ENV_FILE}" "${temp_file}"
  chown --reference="${ENV_FILE}" "${temp_file}"
  mv "${temp_file}" "${ENV_FILE}"
}

ensure_environment() {
  [[ -f "${ENV_EXAMPLE}" ]] || die "Missing ${ENV_EXAMPLE}."
  if [[ ! -f "${ENV_FILE}" ]]; then
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then chown "${SUDO_UID}:${SUDO_GID}" "${ENV_FILE}"; fi
    log "Created .env from .env.example. Review it before production use."
  else
    log "Keeping existing .env file."
  fi

  if [[ "${STACK_MODE}" == "observability" ]]; then
    local password
    password="$(read_env_value GRAFANA_ADMIN_PASSWORD change-me)"
    if [[ -z "${password}" || "${password}" == "change-me" ]]; then
      replace_env_value GRAFANA_ADMIN_PASSWORD "$(generate_password)"
      log "Generated Grafana admin password in .env."
    fi
  fi
}

prepare_host_home() {
  local host_home
  host_home="$(read_env_value HOST_HOME /srv/jenkins/home)"
  [[ "${host_home}" == /* ]] || die "HOST_HOME must be an absolute path: ${host_home}"
  case "${host_home}" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "HOST_HOME cannot be a protected system directory: ${host_home}" ;;
  esac
  install -d -m 0755 "${host_home}"
  chown 1000:1000 "${host_home}"
}

validate_domain() {
  local value="$1" name="$2"
  [[ -n "${value}" ]] || die "${name} is required for --with-https."
  [[ "${value}" != *.example.com ]] || die "Replace placeholder ${name}=${value} in .env."
  [[ "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Invalid ${name}: ${value}"
}

validate_https_environment() {
  local jenkins_domain grafana_domain acme_email
  jenkins_domain="$(read_env_value JENKINS_DOMAIN '')"
  grafana_domain="$(read_env_value GRAFANA_DOMAIN '')"
  acme_email="$(read_env_value ACME_EMAIL '')"

  validate_domain "${jenkins_domain}" JENKINS_DOMAIN
  [[ "${acme_email}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "ACME_EMAIL must be a valid email address."
  getent ahostsv4 "${jenkins_domain}" >/dev/null || die "JENKINS_DOMAIN does not resolve: ${jenkins_domain}"
  log "DNS resolves for ${jenkins_domain}."

  if [[ "${STACK_MODE}" == "observability" ]]; then
    validate_domain "${grafana_domain}" GRAFANA_DOMAIN
    [[ "${grafana_domain}" != "${jenkins_domain}" ]] || die "GRAFANA_DOMAIN must differ from JENKINS_DOMAIN."
    getent ahostsv4 "${grafana_domain}" >/dev/null || die "GRAFANA_DOMAIN does not resolve: ${grafana_domain}"
    log "DNS resolves for ${grafana_domain}."
  fi
}

ensure_certbot() {
  command -v certbot >/dev/null 2>&1 && return 0
  [[ "${ACTION}" != "check" ]] || die "certbot is required to check HTTPS mode."
  require_ubuntu
  log "Installing Certbot."
  apt-get update
  apt-get install -y certbot
}

stop_nginx_for_acme() {
  docker rm -f jenkins-nginx >/dev/null 2>&1 || true
}

ensure_certificate() {
  local jenkins_domain grafana_domain acme_email letsencrypt_dir cert_path
  jenkins_domain="$(read_env_value JENKINS_DOMAIN '')"
  grafana_domain="$(read_env_value GRAFANA_DOMAIN '')"
  acme_email="$(read_env_value ACME_EMAIL '')"
  letsencrypt_dir="$(read_env_value LETSENCRYPT_DIR /etc/letsencrypt)"
  cert_path="${letsencrypt_dir}/live/${jenkins_domain}/fullchain.pem"

  [[ "${letsencrypt_dir}" == /* ]] || die "LETSENCRYPT_DIR must be an absolute path."
  install -d -m 0755 "${letsencrypt_dir}"
  if [[ -s "${cert_path}" ]]; then
    log "Existing TLS certificate found for ${jenkins_domain}."
    return 0
  fi

  log "Issuing Let's Encrypt certificate. Port 80 must be reachable from the Internet."
  stop_nginx_for_acme
  local args=(certonly --standalone --non-interactive --agree-tos --email "${acme_email}" --cert-name "${jenkins_domain}" -d "${jenkins_domain}")
  if [[ "${STACK_MODE}" == "observability" ]]; then args+=(-d "${grafana_domain}"); fi
  certbot --config-dir "${letsencrypt_dir}" "${args[@]}"
  [[ -s "${cert_path}" ]] || die "Certificate issuance completed but ${cert_path} is missing."
}

render_https_nginx() {
  local jenkins_domain grafana_domain letsencrypt_dir
  jenkins_domain="$(read_env_value JENKINS_DOMAIN '')"
  grafana_domain="$(read_env_value GRAFANA_DOMAIN '')"
  letsencrypt_dir="$(read_env_value LETSENCRYPT_DIR /etc/letsencrypt)"
  install -d -m 0755 "${NGINX_RUNTIME_DIR}"

  cat > "${NGINX_RUNTIME_DIR}/default.conf" <<EOF
server {
    listen 80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${jenkins_domain};
    ssl_certificate /etc/letsencrypt/live/${jenkins_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${jenkins_domain}/privkey.pem;

    location / {
        proxy_pass http://jenkins:8080;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Server \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  if [[ "${STACK_MODE}" == "observability" ]]; then
    cat >> "${NGINX_RUNTIME_DIR}/default.conf" <<EOF

server {
    listen 443 ssl;
    server_name ${grafana_domain};
    ssl_certificate /etc/letsencrypt/live/${jenkins_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${jenkins_domain}/privkey.pem;

    location / {
        proxy_pass http://grafana:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
  fi

  chmod 0644 "${NGINX_RUNTIME_DIR}/default.conf"
  log "Rendered HTTPS Nginx configuration."
}

install_certificate_hooks() {
  local hook_dir="/etc/letsencrypt/renewal-hooks"
  install -d -m 0755 "${hook_dir}/pre" "${hook_dir}/post"
  cat > "${hook_dir}/pre/compose-stack-stop-nginx.sh" <<'EOF'
#!/usr/bin/env bash
docker stop jenkins-nginx >/dev/null 2>&1 || true
EOF
  cat > "${hook_dir}/post/compose-stack-start-nginx.sh" <<'EOF'
#!/usr/bin/env bash
docker start jenkins-nginx >/dev/null 2>&1 || true
EOF
  chmod 0755 "${hook_dir}/pre/compose-stack-stop-nginx.sh" "${hook_dir}/post/compose-stack-start-nginx.sh"
  systemctl enable --now certbot.timer >/dev/null 2>&1 || warn "certbot.timer is unavailable; configure certificate renewal manually."
}

compose_args=(-f "${SCRIPT_DIR}/compose.yaml")
if [[ "${STACK_MODE}" == "observability" ]]; then compose_args+=(-f "${SCRIPT_DIR}/compose.observability.yaml"); fi
if [[ "${ACCESS_MODE}" == "https" ]]; then
  compose_args+=(-f "${SCRIPT_DIR}/compose.ingress.yaml")
else
  compose_args+=(-f "${SCRIPT_DIR}/compose.local.yaml")
fi

compose() { docker compose --env-file "${ENV_FILE}" "${compose_args[@]}" "$@"; }
validate_configuration() { log "Validating ${STACK_MODE}/${ACCESS_MODE} Compose configuration."; compose config --quiet; }

expected_services=(docker jenkins nginx)
if [[ "${STACK_MODE}" == "observability" ]]; then expected_services+=(prometheus grafana node-exporter cadvisor); fi

service_state() {
  local container_id
  container_id="$(compose ps -q "$1")"
  [[ -n "${container_id}" ]] || return 1
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container_id}"
}

wait_for_services() {
  local service state attempt
  for service in "${expected_services[@]}"; do
    state=""
    for attempt in {1..60}; do
      state="$(service_state "${service}" 2>/dev/null || true)"
      [[ "${state}" == "healthy" || "${state}" == "running" ]] && break
      sleep 2
    done
    if [[ "${state}" != "healthy" && "${state}" != "running" ]]; then
      compose logs --tail 50 "${service}" >&2 || true
      die "Service '${service}' did not become ready (state: ${state:-missing})."
    fi
    log "Service '${service}' is ${state}."
  done
}

check_services() {
  local service state failed="false"
  for service in "${expected_services[@]}"; do
    state="$(service_state "${service}" 2>/dev/null || true)"
    if [[ "${state}" == "healthy" || "${state}" == "running" ]]; then log "Service '${service}' is ${state}."; else warn "Service '${service}' is ${state:-missing}."; failed="true"; fi
  done
  [[ "${failed}" == "false" ]] || die "One or more services are not ready."
}

wait_for_http() {
  local name="$1" url="$2" attempt status=""
  for attempt in {1..30}; do
    status="$(curl -k --output /dev/null --silent --max-time 5 --write-out '%{http_code}' "${url}" || true)"
    [[ "${status}" =~ ^(2|3)[0-9][0-9]$ ]] && { log "${name} endpoint is ready: ${url}"; return 0; }
    sleep 2
  done
  die "${name} endpoint did not become ready: ${url} (HTTP ${status:-unavailable})."
}

verify_endpoints() {
  if [[ "${ACCESS_MODE}" == "https" ]]; then
    local jenkins_domain grafana_domain
    jenkins_domain="$(read_env_value JENKINS_DOMAIN '')"
    wait_for_http Jenkins "https://${jenkins_domain}/login"
    if [[ "${STACK_MODE}" == "observability" ]]; then
      grafana_domain="$(read_env_value GRAFANA_DOMAIN '')"
      wait_for_http Grafana "https://${grafana_domain}/api/health"
      compose exec -T prometheus wget -qO- http://localhost:9090/-/ready >/dev/null
    fi
  else
    local nginx_port prometheus_port grafana_port
    nginx_port="$(read_env_value NGINX_HTTP_PORT 9000)"
    wait_for_http Jenkins "http://127.0.0.1:${nginx_port}/login"
    if [[ "${STACK_MODE}" == "observability" ]]; then
      prometheus_port="$(read_env_value PROMETHEUS_PORT 9090)"
      grafana_port="$(read_env_value GRAFANA_PORT 3030)"
      wait_for_http Prometheus "http://127.0.0.1:${prometheus_port}/-/ready"
      wait_for_http Grafana "http://127.0.0.1:${grafana_port}/api/health"
    fi
  fi
}

print_summary() {
  printf '\nCompose Stack is ready.\n'
  if [[ "${ACCESS_MODE}" == "https" ]]; then
    printf '  Jenkins: https://%s\n' "$(read_env_value JENKINS_DOMAIN '')"
    if [[ "${STACK_MODE}" == "observability" ]]; then
      printf '  Grafana: https://%s\n' "$(read_env_value GRAFANA_DOMAIN '')"
      printf '  Prometheus: internal only (prometheus:9090)\n'
    fi
    printf '  TLS renewal: certbot.timer\n'
  else
    local server_ip
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"; server_ip="${server_ip:-SERVER_IP}"
    printf '  Jenkins through Nginx: http://%s:%s\n' "${server_ip}" "$(read_env_value NGINX_HTTP_PORT 9000)"
    printf '  Jenkins direct:        http://%s:%s\n' "${server_ip}" "$(read_env_value JENKINS_HTTP_PORT 49000)"
    if [[ "${STACK_MODE}" == "observability" ]]; then
      printf '  Prometheus:            http://%s:%s\n' "${server_ip}" "$(read_env_value PROMETHEUS_PORT 9090)"
      printf '  Grafana:               http://%s:%s\n' "${server_ip}" "$(read_env_value GRAFANA_PORT 3030)"
    fi
  fi

  local admin_password
  admin_password="$(compose exec -T jenkins cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || true)"
  if [[ -n "${admin_password}" ]]; then printf '  Jenkins initial password: %s\n' "${admin_password}"; fi
}

cd "${SCRIPT_DIR}"
ensure_docker
ensure_host_tools

if [[ "${ACTION}" == "check" ]]; then
  [[ -f "${ENV_FILE}" ]] || die "Missing .env. Run setup first."
  if [[ "${ACCESS_MODE}" == "https" ]]; then
    validate_https_environment
    [[ -f "${NGINX_RUNTIME_DIR}/default.conf" ]] || die "Missing generated HTTPS config. Run setup first."
  fi
  validate_configuration
  check_services
  verify_endpoints
  print_summary
  exit 0
fi

ensure_environment
prepare_host_home

if [[ "${ACCESS_MODE}" == "https" ]]; then
  validate_https_environment
  ensure_certbot
  ensure_certificate
  render_https_nginx
  install_certificate_hooks
fi

validate_configuration

if [[ "${ACTION}" == "update" ]]; then
  log "Pulling current service images."
  compose pull --ignore-buildable
  log "Rebuilding Jenkins image."
  compose build --pull jenkins
fi

log "Starting ${STACK_MODE}/${ACCESS_MODE} stack."
if [[ "${ACTION}" == "update" ]]; then compose up --detach; else compose up --detach --build; fi
compose restart nginx
wait_for_services
verify_endpoints
print_summary

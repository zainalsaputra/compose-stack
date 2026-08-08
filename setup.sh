#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

STACK_MODE="core"
ACTION="setup"
ALLOW_DOCKER_INSTALL="true"

log() {
  printf '[compose-stack] %s\n' "$*"
}

warn() {
  printf '[compose-stack] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[compose-stack] ERROR: %s\n' "$*" >&2
  exit 1
}

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

Setup and update operations require root privileges. Run the command directly
from a root shell, or prefix it with sudo when using a non-root account.

Options:
  --with-observability  Start Prometheus, Grafana, node-exporter, and cAdvisor.
  --check               Validate configuration and check an existing deployment.
  --update              Pull newer images, rebuild Jenkins, and apply the stack.
  --skip-docker-install Fail instead of installing Docker when it is unavailable.
  -h, --help            Show this help message.

Examples:
  bash setup.sh
  bash setup.sh --with-observability
  sudo bash setup.sh
  sudo bash setup.sh --with-observability
  bash setup.sh --with-observability --check
  sudo bash setup.sh --with-observability --update
EOF
}

while (($# > 0)); do
  case "$1" in
    --with-observability)
      STACK_MODE="observability"
      ;;
    --check)
      ACTION="check"
      ;;
    --update)
      ACTION="update"
      ;;
    --skip-docker-install)
      ALLOW_DOCKER_INSTALL="false"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown option: $1"
      ;;
  esac
  shift
done

if [[ "${ACTION}" != "check" && "${EUID}" -ne 0 ]]; then
  die "Setup and update operations require root privileges. Log in as root or use: sudo bash setup.sh"
fi

require_ubuntu() {
  [[ -r /etc/os-release ]] || die "Cannot determine the operating system. This script supports Ubuntu."

  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Unsupported operating system '${ID:-unknown}'. This script supports Ubuntu."
  [[ -n "${VERSION_CODENAME:-}" ]] || die "Ubuntu VERSION_CODENAME is unavailable."
}

install_docker() {
  require_ubuntu
  log "Installing Docker Engine and the Docker Compose plugin."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg openssl

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
    local key_file
    key_file="$(mktemp)"
    curl --fail --silent --show-error --location https://download.docker.com/linux/ubuntu/gpg -o "${key_file}"
    gpg --dearmor --yes --output /etc/apt/keyrings/docker.gpg "${key_file}"
    rm -f "${key_file}"
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local architecture
  architecture="$(dpkg --print-architecture)"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
    "${architecture}" "${VERSION_CODENAME}" > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    [[ "${ACTION}" != "check" ]] || die "Docker Engine and the Compose plugin are required for --check."
    [[ "${ALLOW_DOCKER_INSTALL}" == "true" ]] || die "Docker is unavailable and automatic installation was disabled."
    install_docker
  fi

  if [[ "${ACTION}" != "check" ]]; then
    systemctl enable --now docker
  fi

  docker info >/dev/null 2>&1 || die "The Docker daemon is unavailable or the current user cannot access it."
}

ensure_host_tools() {
  if command -v curl >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
    return 0
  fi

  [[ "${ACTION}" != "check" ]] || die "curl and openssl are required for --check."
  require_ubuntu
  log "Installing required host utilities."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl openssl
}

read_env_value() {
  local key="$1"
  local fallback="$2"
  local value

  value="$(awk -F= -v wanted="${key}" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "${ENV_FILE}")"
  value="${value%$'\r'}"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "${value:-${fallback}}"
}

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

replace_env_value() {
  local key="$1"
  local value="$2"
  local temp_file
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
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
      chown "${SUDO_UID}:${SUDO_GID}" "${ENV_FILE}"
    fi
    log "Created .env from .env.example."
  else
    log "Keeping the existing .env file."
  fi

  if [[ "${STACK_MODE}" == "observability" ]]; then
    local grafana_password
    grafana_password="$(read_env_value GRAFANA_ADMIN_PASSWORD change-me)"
    if [[ -z "${grafana_password}" || "${grafana_password}" == "change-me" ]]; then
      replace_env_value GRAFANA_ADMIN_PASSWORD "$(generate_password)"
      log "Replaced the default Grafana password with a generated value in .env."
    fi
  fi
}

prepare_host_home() {
  local host_home
  host_home="$(read_env_value HOST_HOME /srv/jenkins/home)"

  [[ "${host_home}" == /* ]] || die "HOST_HOME must be an absolute path: ${host_home}"
  case "${host_home}" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "HOST_HOME cannot use a protected system directory: ${host_home}"
      ;;
  esac

  install -d -m 0755 "${host_home}"
  chown 1000:1000 "${host_home}"
  log "Prepared Jenkins shared directory: ${host_home}"
}

compose_args=(-f "${SCRIPT_DIR}/compose.yaml")
if [[ "${STACK_MODE}" == "observability" ]]; then
  compose_args+=(-f "${SCRIPT_DIR}/compose.observability.yaml")
fi

compose() {
  docker compose --env-file "${ENV_FILE}" "${compose_args[@]}" "$@"
}

validate_configuration() {
  log "Validating the ${STACK_MODE} Compose configuration."
  compose config --quiet
}

expected_services=(docker jenkins nginx)
if [[ "${STACK_MODE}" == "observability" ]]; then
  expected_services+=(prometheus grafana node-exporter cadvisor)
fi

service_state() {
  local service="$1"
  local container_id
  container_id="$(compose ps -q "${service}")"
  [[ -n "${container_id}" ]] || return 1

  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container_id}"
}

wait_for_services() {
  local service state attempt

  for service in "${expected_services[@]}"; do
    state=""
    for attempt in {1..60}; do
      state="$(service_state "${service}" 2>/dev/null || true)"
      if [[ "${state}" == "healthy" || "${state}" == "running" ]]; then
        break
      fi
      sleep 2
    done

    if [[ "${state}" != "healthy" && "${state}" != "running" ]]; then
      compose logs --tail 50 "${service}" >&2 || true
      die "Service '${service}' did not become ready (last state: ${state:-missing})."
    fi
    log "Service '${service}' is ${state}."
  done
}

check_services() {
  local service state failed="false"

  for service in "${expected_services[@]}"; do
    state="$(service_state "${service}" 2>/dev/null || true)"
    if [[ "${state}" == "healthy" || "${state}" == "running" ]]; then
      log "Service '${service}' is ${state}."
    else
      warn "Service '${service}' is not ready (state: ${state:-missing})."
      failed="true"
    fi
  done

  [[ "${failed}" == "false" ]] || die "One or more services are not ready."
}

wait_for_http() {
  local name="$1"
  local url="$2"
  local attempt status=""

  for attempt in {1..30}; do
    status="$(curl --output /dev/null --silent --max-time 5 --write-out '%{http_code}' "${url}" || true)"
    if [[ "${status}" =~ ^(2|3)[0-9][0-9]$ ]]; then
      log "${name} endpoint is ready: ${url}"
      return 0
    fi
    sleep 2
  done

  die "${name} endpoint did not become ready: ${url} (last HTTP status: ${status:-unavailable})"
}

verify_endpoints() {
  local nginx_port prometheus_port grafana_port
  nginx_port="$(read_env_value NGINX_HTTP_PORT 9000)"
  wait_for_http Jenkins "http://127.0.0.1:${nginx_port}/login"

  if [[ "${STACK_MODE}" == "observability" ]]; then
    prometheus_port="$(read_env_value PROMETHEUS_PORT 9090)"
    grafana_port="$(read_env_value GRAFANA_PORT 3030)"
    wait_for_http Prometheus "http://127.0.0.1:${prometheus_port}/-/ready"
    wait_for_http Grafana "http://127.0.0.1:${grafana_port}/api/health"
  fi
}

print_summary() {
  local server_ip nginx_port jenkins_port prometheus_port grafana_port admin_password
  server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  server_ip="${server_ip:-SERVER_IP}"
  nginx_port="$(read_env_value NGINX_HTTP_PORT 9000)"
  jenkins_port="$(read_env_value JENKINS_HTTP_PORT 49000)"

  printf '\nCompose Stack is ready.\n'
  printf '  Jenkins through Nginx: http://%s:%s\n' "${server_ip}" "${nginx_port}"
  printf '  Jenkins direct:        http://%s:%s\n' "${server_ip}" "${jenkins_port}"

  if [[ "${STACK_MODE}" == "observability" ]]; then
    prometheus_port="$(read_env_value PROMETHEUS_PORT 9090)"
    grafana_port="$(read_env_value GRAFANA_PORT 3030)"
    printf '  Prometheus:            http://%s:%s\n' "${server_ip}" "${prometheus_port}"
    printf '  Grafana:               http://%s:%s\n' "${server_ip}" "${grafana_port}"
    printf '  Grafana credentials:   configured in %s\n' "${ENV_FILE}"
  fi

  admin_password="$(compose exec -T jenkins cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || true)"
  if [[ -n "${admin_password}" ]]; then
    printf '  Jenkins initial password: %s\n' "${admin_password}"
  else
    printf '  Jenkins initial password: already consumed or unavailable\n'
  fi
}

cd "${SCRIPT_DIR}"
ensure_docker
ensure_host_tools

if [[ "${ACTION}" == "check" ]]; then
  [[ -f "${ENV_FILE}" ]] || die "Missing .env. Run the setup command first."
  validate_configuration
  check_services
  verify_endpoints
  print_summary
  exit 0
fi

ensure_environment
prepare_host_home
validate_configuration

if [[ "${ACTION}" == "update" ]]; then
  log "Pulling current service images."
  compose pull --ignore-buildable
  log "Rebuilding the Jenkins image with current base packages."
  compose build --pull jenkins
fi

log "Starting the ${STACK_MODE} stack."
if [[ "${ACTION}" == "update" ]]; then
  compose up --detach
else
  compose up --detach --build
fi
log "Refreshing the Nginx upstream after service reconciliation."
compose restart nginx
wait_for_services
verify_endpoints
print_summary

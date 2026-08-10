#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

STACK_MODE="core"
ACTION="setup"
ALLOW_DOCKER_INSTALL="true"

log() { printf '[compose-stack] %s\n' "$*"; }
warn() { printf '[compose-stack] WARNING: %s\n' "$*" >&2; }
die() { printf '[compose-stack] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  bash setup-cloudflare.sh [options]

Runs Compose Stack behind a remotely-managed Cloudflare Tunnel. No Jenkins,
Nginx, or Grafana port is published to the public network by this mode.

Options:
  --with-observability  Start Prometheus, Grafana, node-exporter, and cAdvisor.
  --check               Validate configuration and check an existing deployment.
  --update              Pull service images, rebuild Jenkins, and apply the stack.
  --skip-docker-install Fail instead of installing Docker when unavailable.
  -h, --help            Show this help message.

Examples:
  sudo bash setup-cloudflare.sh
  sudo bash setup-cloudflare.sh --with-observability
  bash setup-cloudflare.sh --with-observability --check
  sudo bash setup-cloudflare.sh --with-observability --update
EOF
}

while (($# > 0)); do
  case "$1" in
    --with-observability) STACK_MODE="observability" ;;
    --check) ACTION="check" ;;
    --update) ACTION="update" ;;
    --skip-docker-install) ALLOW_DOCKER_INSTALL="false" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

if [[ "${ACTION}" != "check" && "${EUID}" -ne 0 ]]; then
  die "Setup and update operations require root privileges. Use: sudo bash setup-cloudflare.sh"
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

read_env_value() {
  local key="$1" fallback="$2" value
  value="$(awk -F= -v wanted="${key}" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "${ENV_FILE}" 2>/dev/null || true)"
  value="${value%$'\r'}"; value="${value%\"}"; value="${value#\"}"
  printf '%s' "${value:-${fallback}}"
}

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
    die "Created .env from .env.example. Set CLOUDFLARE_TUNNEL_TOKEN, then rerun the command."
  fi

  if [[ "${STACK_MODE}" == "observability" ]]; then
    local password
    password="$(read_env_value GRAFANA_ADMIN_PASSWORD change-me)"
    if [[ -z "${password}" || "${password}" == "change-me" ]]; then
      replace_env_value GRAFANA_ADMIN_PASSWORD "$(openssl rand -hex 24)"
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
      die "HOST_HOME cannot use a protected system directory: ${host_home}" ;;
  esac
  install -d -m 0755 "${host_home}"
  chown 1000:1000 "${host_home}"
}

validate_cloudflare_environment() {
  local token protocol
  token="$(read_env_value CLOUDFLARE_TUNNEL_TOKEN '')"
  protocol="$(read_env_value CLOUDFLARE_TUNNEL_PROTOCOL http2)"
  [[ -n "${token}" ]] || die "CLOUDFLARE_TUNNEL_TOKEN is required. Set it only in .env."
  [[ "${token}" != *"<"* && "${token}" != *">"* ]] || die "CLOUDFLARE_TUNNEL_TOKEN still looks like a placeholder."
  case "${protocol}" in
    http2|quic|auto) ;;
    *) die "CLOUDFLARE_TUNNEL_PROTOCOL must be one of: http2, quic, auto." ;;
  esac
}

compose_args=(-f "${SCRIPT_DIR}/compose.yaml")
if [[ "${STACK_MODE}" == "observability" ]]; then
  compose_args+=(-f "${SCRIPT_DIR}/compose.observability.yaml")
fi
compose_args+=(-f "${SCRIPT_DIR}/compose.cloudflare.yaml")

compose() { docker compose --env-file "${ENV_FILE}" "${compose_args[@]}" "$@"; }

expected_services=(docker jenkins nginx cloudflared)
if [[ "${STACK_MODE}" == "observability" ]]; then
  expected_services+=(prometheus grafana node-exporter cadvisor)
fi

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
      compose logs --tail 60 "${service}" >&2 || true
      die "Service '${service}' did not become ready (state: ${state:-missing})."
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
      warn "Service '${service}' is ${state:-missing}."
      failed="true"
    fi
  done
  [[ "${failed}" == "false" ]] || die "One or more services are not ready."
}

probe_network_http() {
  local network="$1" url="$2" name="$3"
  docker run --rm \
    --network "${network}" \
    alpine:3.20 \
    wget -q --spider --timeout=10 "${url}" \
    || die "${name} is not reachable through Docker network '${network}': ${url}"
  log "${name} is reachable through Docker network '${network}': ${url}"
}

verify_internal_endpoints() {
  local ci_network observability_network
  ci_network="$(read_env_value CI_NETWORK_NAME compose-stack-ci)"
  observability_network="$(read_env_value OBSERVABILITY_NETWORK_NAME compose-stack-observability)"

  probe_network_http "${ci_network}" "http://jenkins:8080/login" "Jenkins"

  if [[ "${STACK_MODE}" == "observability" ]]; then
    probe_network_http "${observability_network}" "http://grafana:3000/api/health" "Grafana"

    curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:$(read_env_value PROMETHEUS_PORT 9090)/-/ready" >/dev/null \
      || die "Prometheus readiness endpoint is unavailable on loopback."
    log "Prometheus readiness endpoint is healthy on loopback."
  fi
}

print_summary() {
  local jenkins_domain grafana_domain
  jenkins_domain="$(read_env_value JENKINS_DOMAIN '')"
  grafana_domain="$(read_env_value GRAFANA_DOMAIN '')"

  printf '\nCompose Stack Cloudflare Tunnel mode is ready.\n'
  printf '  Cloudflared: running via encrypted outbound tunnel\n'
  printf '  Public inbound ports required by this mode: none\n'
  printf '\nConfigure these Published application routes in Cloudflare Zero Trust:\n'
  if [[ -n "${jenkins_domain}" && "${jenkins_domain}" != *.example.com ]]; then
    printf '  %s -> http://jenkins:8080\n' "${jenkins_domain}"
  else
    printf '  Jenkins hostname -> http://jenkins:8080\n'
  fi
  if [[ "${STACK_MODE}" == "observability" ]]; then
    if [[ -n "${grafana_domain}" && "${grafana_domain}" != *.example.com ]]; then
      printf '  %s -> http://grafana:3000\n' "${grafana_domain}"
    else
      printf '  Grafana hostname -> http://grafana:3000\n'
    fi
    printf '  Prometheus remains internal/loopback only.\n'
  fi
  printf '\nDo not create public routes for docker:2376, node-exporter, or cAdvisor.\n'
}

cd "${SCRIPT_DIR}"
ensure_docker

if [[ "${ACTION}" == "check" ]]; then
  [[ -f "${ENV_FILE}" ]] || die "Missing .env. Run setup first."
  validate_cloudflare_environment
  compose config --quiet
  check_services
  verify_internal_endpoints
  print_summary
  exit 0
fi

ensure_environment
prepare_host_home
validate_cloudflare_environment
compose config --quiet

if [[ "${ACTION}" == "update" ]]; then
  log "Pulling current service images."
  compose pull --ignore-buildable
  log "Rebuilding Jenkins image."
  compose build --pull jenkins
fi

log "Starting ${STACK_MODE}/cloudflare stack."
if [[ "${ACTION}" == "update" ]]; then
  compose up --detach
else
  compose up --detach --build
fi
wait_for_services
verify_internal_endpoints
print_summary

# Compose Stack

Reusable Docker Compose infrastructure for Jenkins with Docker-in-Docker, Nginx, and optional Prometheus/Grafana observability.

The repository supports two access modes:

- **Local mode** — IP/localhost + ports, intended for Windows, development, and troubleshooting.
- **DNS + HTTPS mode** — production-oriented Ubuntu server ingress using Nginx, Let's Encrypt, and domain-based routing.

## Architecture

```text
Internet
   |
   | DNS
   v
jenkins.ops.example.com -----+
grafana.ops.example.com -----+
                              |
                           80 / 443
                              |
                            Nginx
                         /           \
                   CI network   observability network
                      |                 |
                   Jenkins           Grafana
                      |                 |
                 Docker DinD        Prometheus
                                        |
                                 node-exporter / cAdvisor
```

In HTTPS mode, Jenkins is not published directly to the public host interface. Prometheus and Grafana keep loopback-only host bindings for local health checks and administration; Grafana is exposed remotely only through Nginx HTTPS. Docker-in-Docker, node-exporter, and cAdvisor remain Docker-network-only.

## Repository Layout

```text
.
├── compose.yaml
├── compose.local.yaml
├── compose.observability.yaml
├── compose.ingress.yaml
├── Dockerfile
├── .env.example
├── setup.sh
├── setup.ps1
├── nginx/
│   └── default.conf
├── runtime/                 # generated, ignored by Git
│   └── nginx/
│       └── default.conf
├── prometheus/
├── grafana/
└── examples/
```

### Compose layers

| File | Purpose |
| --- | --- |
| `compose.yaml` | Internal core services: Jenkins, Nginx, Docker-in-Docker. |
| `compose.local.yaml` | Local Jenkins/Nginx host port exposure and local Nginx configuration. |
| `compose.observability.yaml` | Prometheus, Grafana, node-exporter, and cAdvisor. Prometheus/Grafana bind only to `127.0.0.1`. |
| `compose.ingress.yaml` | Ubuntu DNS + HTTPS ingress on host ports 80/443 and certificate mount. |

## Services

| Service | Purpose |
| --- | --- |
| `jenkins` | Jenkins LTS CI/CD controller with Docker CLI, Pipeline, Blue Ocean, Docker Workflow, and Prometheus plugins. |
| `docker` | TLS-enabled Docker-in-Docker daemon used by Jenkins builds. |
| `nginx` | Local reverse proxy or DNS/HTTPS ingress, depending on Compose mode. |
| `prometheus` | Optional metrics collection. |
| `grafana` | Optional observability dashboard. |
| `node-exporter` | Optional Linux host metrics exporter. |
| `cadvisor` | Optional container metrics exporter. |

## Prerequisites

### Ubuntu

- Ubuntu server
- Root shell or user with `sudo`
- Internet access
- Git
- Public DNS records when `--with-https` is used
- Public inbound TCP 80 and 443 when issuing Let's Encrypt certificates

Docker Engine, Docker Compose, Certbot, and required utilities are installed automatically when required.

### Windows

- Windows 10/11
- Hardware virtualization
- Docker Desktop using Linux containers

`setup.ps1` uses local mode only. DNS + HTTPS server ingress is intentionally implemented by `setup.sh` on Ubuntu.

## Environment Configuration

Create the environment file:

```bash
cp .env.example .env
```

Important HTTPS values:

```dotenv
JENKINS_DOMAIN=jenkins.ops.example.com
GRAFANA_DOMAIN=grafana.ops.example.com
ACME_EMAIL=devops@example.com
HTTP_PORT=80
HTTPS_PORT=443
LETSENCRYPT_DIR=/etc/letsencrypt
```

Replace all `example.com` values before running HTTPS setup.

Do not commit `.env`.

## Ubuntu: Local Mode

Core stack:

```bash
sudo bash setup.sh
```

With observability:

```bash
sudo bash setup.sh --with-observability
```

Default local endpoints:

```text
Jenkins via Nginx : http://SERVER_IP:9000
Jenkins direct    : http://SERVER_IP:49000
Prometheus        : http://127.0.0.1:9090
Grafana           : http://127.0.0.1:3030
```

Prometheus and Grafana intentionally use loopback bindings. Use DNS + HTTPS mode for remote Grafana access.

## Ubuntu: DNS + HTTPS Mode

### 1. Clone

Recommended path:

```bash
sudo mkdir -p /opt/compose-stack
sudo chown -R "$USER:$USER" /opt/compose-stack
git clone https://github.com/zainalsaputra/compose-stack.git /opt/compose-stack
cd /opt/compose-stack
```

When evaluating a feature branch, check it out before setup.

### 2. Configure `.env`

```bash
cp .env.example .env
nano .env
```

At minimum configure:

```dotenv
JENKINS_DOMAIN=jenkins.ops.company.com
GRAFANA_DOMAIN=grafana.ops.company.com
ACME_EMAIL=devops@company.com
```

### 3. Create DNS records

Example:

```text
A  jenkins.ops.company.com  -> CI_SERVER_PUBLIC_IP
A  grafana.ops.company.com  -> CI_SERVER_PUBLIC_IP
```

The setup script validates that required hostnames resolve before certificate issuance.

### 4. Start HTTPS ingress

Jenkins only:

```bash
sudo bash setup.sh --with-https
```

Jenkins + observability:

```bash
sudo bash setup.sh --with-observability --with-https
```

The HTTPS setup performs the following operations:

1. Ensures Docker and required host utilities are available.
2. Creates `.env` if missing without replacing an existing one.
3. Validates Jenkins/Grafana domain values.
4. Validates DNS resolution.
5. Installs Certbot when required.
6. Issues a Let's Encrypt certificate using the Jenkins hostname as the certificate name.
7. Adds Grafana as a SAN when observability is enabled.
8. Generates runtime Nginx HTTPS configuration under `runtime/nginx/`.
9. Mounts certificates read-only into Nginx.
10. Starts the requested Compose layers.
11. Validates service readiness and HTTPS endpoints.
12. Enables the Certbot renewal timer when available.

Target endpoints:

```text
https://jenkins.ops.company.com
https://grafana.ops.company.com
```

Prometheus remains non-public:

```text
prometheus:9090
127.0.0.1:9090
```

## Port Exposure Model

### HTTPS server mode

Expected externally reachable application ports:

| Port | Purpose |
| ---: | --- |
| 80 | HTTP redirect / ACME certificate issuance |
| 443 | HTTPS ingress |
| 22 | SSH, according to server access policy |

Internal or loopback-only ports:

| Service | Endpoint |
| --- | --- |
| Jenkins | `jenkins:8080` |
| Docker DinD | `docker:2376` |
| Grafana | `grafana:3000`, plus `127.0.0.1:3030` |
| Prometheus | `prometheus:9090`, plus `127.0.0.1:9090` |
| node-exporter | `node-exporter:9100` |
| cAdvisor | `cadvisor:8080` |

The Jenkins inbound agent port is published only by local mode. If future production agents require inbound TCP agents, define and restrict that exposure explicitly rather than making it part of the default HTTPS ingress.

## Networks

| Network | Members |
| --- | --- |
| `compose-stack-ci` | Jenkins, Docker-in-Docker, Nginx, Prometheus |
| `compose-stack-observability` | Grafana, Prometheus, node-exporter, cAdvisor, HTTPS Nginx |

Nginx joins the observability network only through `compose.ingress.yaml` so it can proxy Grafana.

## Data Storage

Named volumes:

| Volume | Data |
| --- | --- |
| `compose-stack-jenkins-data` | Jenkins state, jobs, plugins, credentials, configuration |
| `compose-stack-jenkins-docker-certs` | Docker-in-Docker client certificates |
| `compose-stack-prometheus-data` | Prometheus TSDB |
| `compose-stack-grafana-data` | Grafana state |

Shared Jenkins host directory:

```text
/srv/jenkins/home -> /home
```

On Windows, `setup.ps1` automatically replaces the default Linux shared directory with `data/jenkins-home`.

TLS certificates are host-managed under `/etc/letsencrypt` by default and are never committed to Git.

## Operations

Check a local deployment:

```bash
bash setup.sh --with-observability --check
```

Check an HTTPS deployment:

```bash
bash setup.sh --with-observability --with-https --check
```

Update local mode:

```bash
sudo bash setup.sh --with-observability --update
```

Update HTTPS mode:

```bash
sudo bash setup.sh --with-observability --with-https --update
```

View status manually for HTTPS + observability:

```bash
docker compose \
  -f compose.yaml \
  -f compose.observability.yaml \
  -f compose.ingress.yaml \
  ps
```

View Jenkins logs:

```bash
docker logs -f jenkins-blueocean
```

## Certificate Renewal

Ubuntu package installation normally provides `certbot.timer`. The setup script enables it when available and installs renewal hooks that temporarily stop/start the Nginx container for standalone ACME validation.

Verify renewal configuration before production handover:

```bash
sudo certbot renew --dry-run
```

Certificate renewal can briefly interrupt Nginx because standalone validation requires port 80. A future enhancement may migrate renewal to an ACME webroot or DNS challenge to eliminate this interruption.

## Security Notes

- Docker-in-Docker runs with `privileged: true`; treat it as a high-privilege infrastructure component.
- Docker port `2376` is never published publicly.
- node-exporter and cAdvisor are not published to the host.
- Prometheus and Grafana host bindings are loopback-only.
- HTTPS ingress publishes only ports 80/443.
- `.env`, generated runtime configuration, backups, and data directories are ignored by Git.
- Protect Jenkins and Grafana using appropriate authentication and, where possible, VPN, Zero Trust access, or IP restrictions.
- Restrict SSH independently at the host firewall/network layer.

## Jenkins Pipeline Examples

Production-oriented Node.js pipeline references remain under `examples/node-app`:

- `Jenkinsfile.development` — build, test, push, immutable digest deployment, health verification.
- `Jenkinsfile.production` — immutable image promotion, Trivy security gate, approval, deployment, verification, rollback.
- `compose.deploy.example.yaml` — expected remote Compose application contract.

See `examples/node-app/README.md` for pipeline credentials and deployment requirements.

## Recommended Server Workflow

The intended template workflow is:

```text
Clone repository
      |
      v
Create .env
      |
      v
Configure DNS
      |
      v
sudo bash setup.sh --with-observability --with-https
      |
      v
Jenkins + Grafana available through HTTPS DNS
```

Application deployment hosts should have their own reverse proxy and application DNS. Production application traffic should not be routed through the Jenkins CI server.

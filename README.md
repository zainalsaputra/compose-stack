# Compose Stack

This repository contains a non-separated Docker Compose stack for running Jenkins with Docker-in-Docker, Nginx, and optional observability components on an Ubuntu server.

The stack is designed to be cloned and operated from a single root directory, for example:

```bash
/opt/compose-stack
```

## Architecture

```text
.
+-- compose.yaml
+-- compose.observability.yaml
+-- Dockerfile
+-- .env.example
+-- setup.sh
+-- setup.ps1
+-- nginx/
|   +-- default.conf
+-- prometheus/
|   +-- prometheus.yml
+-- grafana/
    +-- provisioning/
        +-- datasources/
            +-- prometheus.yaml
```

There is no dedicated `jenkins/` directory in this non-separated layout. Jenkins is defined as a service in `compose.yaml`, and its custom image is built from the root-level `Dockerfile`.

## Services

| Service | Purpose |
| --- | --- |
| `jenkins` | Jenkins LTS with Blue Ocean, Docker CLI, Pipeline, Docker Workflow, and Prometheus plugin. |
| `nginx` | Reverse proxy for Jenkins using `nginx/default.conf`. |
| `docker` | Docker-in-Docker daemon with TLS enabled and the internal network alias `docker`. |
| `prometheus` | Optional metrics scraper for Jenkins, host metrics, and container metrics. |
| `grafana` | Optional dashboard UI with Prometheus provisioned as the default datasource. |
| `node-exporter` | Optional Linux host metrics exporter. On Docker Desktop, it observes the Linux VM rather than Windows itself. |
| `cadvisor` | Optional container-level metrics exporter for Docker workloads. |

## Data Storage

The stack uses Docker named volumes for stateful data. Application data is not stored inside this Git repository.

| Volume | Stores | Default host path on Ubuntu |
| --- | --- | --- |
| `compose-stack-jenkins-data` | Jenkins home, jobs, plugins, credentials, and configuration | `/var/lib/docker/volumes/compose-stack-jenkins-data/_data` |
| `compose-stack-jenkins-docker-certs` | Docker-in-Docker client TLS certificates | `/var/lib/docker/volumes/compose-stack-jenkins-docker-certs/_data` |
| `compose-stack-prometheus-data` | Prometheus time-series database | `/var/lib/docker/volumes/compose-stack-prometheus-data/_data` |
| `compose-stack-grafana-data` | Grafana database, sessions, and plugins | `/var/lib/docker/volumes/compose-stack-grafana-data/_data` |

This is the recommended approach for this setup because the repository remains configuration-only, while stateful data is managed by Docker.

The only host bind mount used by default is:

```text
${HOST_HOME:-/srv/jenkins/home}:/home
```

Use this path for files that need to be visible from both the Ubuntu host and the Jenkins container. Create it before starting the stack:

```bash
sudo mkdir -p /srv/jenkins/home
sudo chown -R 1000:1000 /srv/jenkins/home
```

On Windows, `setup.ps1` replaces the default Linux path with an absolute `data/jenkins-home` path inside the repository and creates the directory automatically.

If you later choose to use repository-local bind mounts, place them under `data/`. The `data/` directory is ignored by Git.

## Networking

Because this is a non-separated stack, Docker networks are defined directly in the Compose files. A separate infrastructure folder is not necessary unless each service is split into its own Compose project.

| Compose network | Default Docker network name | Members |
| --- | --- | --- |
| `ci` | `compose-stack-ci` | Jenkins, Nginx, Docker-in-Docker, and Prometheus |
| `observability` | `compose-stack-observability` | Prometheus, Grafana, node-exporter, and cAdvisor |

Prometheus is attached to both networks so it can scrape Jenkins from the CI network and exporters from the observability network.

Internal service discovery uses Docker DNS:

- Nginx proxies Jenkins through `http://jenkins:8080`.
- Jenkins connects to Docker-in-Docker through `tcp://docker:2376`.

## Prerequisites

Common requirements:

- Internet access for package, image, and plugin downloads
- Git

Ubuntu additionally requires either a root shell or a non-root user with `sudo` access. Docker Engine and the Docker Compose plugin are installed automatically when unavailable.

Windows requires Windows 10 or 11 with hardware virtualization enabled. Docker Desktop is installed through `winget` when unavailable; its installer may display a Windows UAC prompt or request a restart. Docker Desktop must use Linux containers.

Recommended deployment path:

```bash
sudo mkdir -p /opt/compose-stack
sudo chown -R "$USER:$USER" /opt/compose-stack
```

Clone or copy this repository into `/opt/compose-stack`.

## One-Command Setup

### Ubuntu

Start the core stack:

```bash
cd /opt/compose-stack
bash setup.sh
```

Start the complete stack with Prometheus, Grafana, node-exporter, and cAdvisor:

```bash
cd /opt/compose-stack
bash setup.sh --with-observability
```

The commands above assume that the current shell is already running as `root`. From a non-root account, prefix setup and update commands with `sudo`, for example `sudo bash setup.sh`. The `--check` mode does not require root when the current user has permission to access Docker.

Ubuntu modes:

| Command | Purpose |
| --- | --- |
| `bash setup.sh` | Install or start the core stack from a root shell. |
| `bash setup.sh --with-observability` | Install or start the full monitoring stack from a root shell. |
| `bash setup.sh --check` | Validate and check an existing core deployment without changing it. |
| `bash setup.sh --with-observability --check` | Validate and check an existing full deployment. |
| `bash setup.sh --update` | Pull service images, rebuild Jenkins, and apply the core stack from a root shell. |
| `bash setup.sh --with-observability --update` | Update and apply the full stack from a root shell. |
| `bash setup.sh --skip-docker-install` | Start the stack but fail if Docker is unavailable. |

### Windows

Run the core stack from PowerShell without `sudo`:

```powershell
Set-Location C:\path\to\compose-stack
.\setup.ps1
```

Run the complete stack with observability:

```powershell
.\setup.ps1 -WithObservability
```

Windows modes:

| Command | Purpose |
| --- | --- |
| `.\setup.ps1` | Install Docker Desktop when required, then start the core stack. |
| `.\setup.ps1 -WithObservability` | Install or start the full monitoring stack. |
| `.\setup.ps1 -Check` | Validate and check an existing core deployment without changing it. |
| `.\setup.ps1 -WithObservability -Check` | Validate and check an existing full deployment. |
| `.\setup.ps1 -Update` | Pull service images, rebuild Jenkins, and apply the core stack. |
| `.\setup.ps1 -WithObservability -Update` | Update and apply the full stack. |
| `.\setup.ps1 -SkipDockerInstall` | Start the stack but fail if Docker Desktop is unavailable. |
| `.\setup.ps1 -Help` | Display the Windows setup options and examples. |

If the PowerShell execution policy blocks local scripts, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -WithObservability
```

The Windows script starts Docker Desktop when needed and waits for its daemon. Complete any Docker Desktop first-run, WSL 2, or license prompts shown on screen. Observability containers run inside Docker Desktop's Linux VM; node-exporter does not expose native Windows host metrics.

Both platform scripts perform the following operations:

1. Verifies the platform and Docker requirements.
2. Installs the platform's Docker runtime when required.
3. Creates `.env` from `.env.example` without replacing an existing `.env`.
4. Replaces the default Grafana password with a generated password when observability is enabled.
5. Validates and creates the configured Jenkins shared directory.
6. Validates the merged Compose configuration.
7. Builds and starts the requested services.
8. Waits for service readiness and verifies the HTTP endpoints.
9. On Windows observability runs, verifies every Prometheus target and the Grafana datasource.
10. Displays the service URLs and the initial Jenkins administrator password when available.

The scripts are safe to run repeatedly. They do not remove containers, networks, named volumes, backups, or an existing `.env` file. Destructive reset operations remain manual.

Internet access is required when Docker, packages, container images, or Jenkins plugins must be downloaded. Review `.env` after the first setup, especially ports, `HOST_HOME`, and credentials.

## Jenkins Pipeline Examples

Production-oriented Node.js pipeline references are available under `examples/node-app`:

- [`Jenkinsfile.development`](examples/node-app/Jenkinsfile.development) builds, tests, pushes, deploys, and verifies an immutable image digest in development.
- [`Jenkinsfile.production`](examples/node-app/Jenkinsfile.production) promotes an existing digest with security scanning, authorized approval, health verification, and rollback.
- [`compose.deploy.example.yaml`](examples/node-app/compose.deploy.example.yaml) defines the remote Compose service contract expected by both pipelines.
- [`examples/node-app/README.md`](examples/node-app/README.md) documents credentials, registry requirements, remote host preparation, and required customization.

The templates deploy to remote Ubuntu hosts over SSH with strict host-key verification. They are reference implementations and must be adapted to the application, registry, environments, and organizational release policy before production use.

The Jenkins image includes the OpenSSH client required by these examples. Rebuild an existing installation after pulling this change:

```bash
bash setup.sh --update
```

On Windows:

```powershell
.\setup.ps1 -Update
```

## Configuration

Create the local environment file:

```bash
cd /opt/compose-stack
cp .env.example .env
```

On Windows PowerShell, use:

```powershell
Copy-Item .env.example .env
```

Review and update `.env` before starting the stack. Important values:

| Variable | Default | Description |
| --- | --- | --- |
| `COMPOSE_PROJECT_NAME` | `compose-stack` | Compose project name. |
| `CI_NETWORK_NAME` | `compose-stack-ci` | Docker network for CI services. |
| `OBSERVABILITY_NETWORK_NAME` | `compose-stack-observability` | Docker network for monitoring services. |
| `JENKINS_HTTP_PORT` | `49000` | Direct Jenkins HTTP port on the host. |
| `JENKINS_AGENT_PORT` | `50000` | Jenkins inbound agent port. |
| `NGINX_HTTP_PORT` | `9000` | Nginx reverse proxy port on the host. |
| `HOST_HOME` | `/srv/jenkins/home` | Host directory mounted to `/home` in Jenkins. |
| `PROMETHEUS_PORT` | `9090` | Prometheus HTTP port on the host. |
| `GRAFANA_PORT` | `3030` | Grafana HTTP port on the host. |
| `GRAFANA_ADMIN_PASSWORD` | `change-me` | Initial Grafana admin password. Change this before production use. |

Prepare the shared host directory:

```bash
sudo mkdir -p /srv/jenkins/home
sudo chown -R 1000:1000 /srv/jenkins/home
```

## Start The Core Stack

Start Jenkins, Nginx, and Docker-in-Docker:

```bash
docker compose config --quiet
docker compose up -d --build
```

Access endpoints:

| Endpoint | URL |
| --- | --- |
| Jenkins direct access | `http://SERVER_IP:49000` |
| Jenkins through Nginx | `http://SERVER_IP:9000` |
| Jenkins inbound agent port | `SERVER_IP:50000` |

Get the initial Jenkins administrator password:

```bash
docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

## Start With Observability

Validate and start the full stack including Prometheus, Grafana, node-exporter, and cAdvisor:

```bash
docker compose -f compose.yaml -f compose.observability.yaml config --quiet
docker compose -f compose.yaml -f compose.observability.yaml up -d --build
```

Access endpoints:

| Endpoint | URL |
| --- | --- |
| Prometheus | `http://SERVER_IP:9090` |
| Grafana | `http://SERVER_IP:3030` |

Grafana uses the credentials from `.env`:

- `GRAFANA_ADMIN_USER`
- `GRAFANA_ADMIN_PASSWORD`

The observability Compose file is equivalent to these base commands, with persistent volumes and provisioning added:

```bash
docker run -d --name prometheus -p 9090:9090 prom/prometheus
docker run -d --name grafana -p 3030:3000 grafana/grafana
```

Prometheus scrapes Jenkins, node-exporter, and cAdvisor through Docker DNS on the internal Compose networks. Prometheus and Grafana are exposed directly on their configured host ports; Nginx is dedicated to Jenkins.

Verify the monitoring targets after startup:

1. Open `http://SERVER_IP:9090/targets`.
2. Confirm that `prometheus`, `jenkins`, `node-exporter`, and `cadvisor` are `UP`.
3. Open Grafana and confirm that the provisioned Prometheus datasource is healthy.

## Backup And Restore

Create a backup directory:

```bash
mkdir -p backups
```

Back up Jenkins data:

```bash
docker run --rm -v compose-stack-jenkins-data:/data -v "$PWD/backups:/backup" alpine tar czf /backup/jenkins-data.tgz -C /data .
```

Restore should be performed while Jenkins is stopped:

```bash
docker compose stop jenkins
docker run --rm -v compose-stack-jenkins-data:/data -v "$PWD/backups:/backup" alpine sh -c "cd /data && tar xzf /backup/jenkins-data.tgz"
docker compose start jenkins
```

## Operations

Check service status:

```bash
docker compose ps
```

For the observability stack, always include both Compose files:

```bash
docker compose -f compose.yaml -f compose.observability.yaml ps
```

Follow Jenkins logs:

```bash
docker compose logs -f jenkins
```

Restart Jenkins:

```bash
docker compose restart jenkins
```

Stop containers and remove networks while keeping volumes:

```bash
docker compose -f compose.yaml -f compose.observability.yaml down
```

Reset the full stack, including volumes:

```bash
docker compose -f compose.yaml -f compose.observability.yaml down -v
```

## Security Notes

- The Docker-in-Docker daemon port `2376` is not published to the host.
- Jenkins accesses Docker-in-Docker through the internal Docker network using `tcp://docker:2376`.
- The `docker:dind` service runs with `privileged: true`, which is required for this Docker-in-Docker setup.
- Do not commit `.env`; it contains local configuration and credentials.
- Change `GRAFANA_ADMIN_PASSWORD` before exposing Grafana outside a trusted network.

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
| `prometheus` | Metrics scraper for Jenkins, host metrics, and container metrics. |
| `grafana` | Dashboard UI with Prometheus provisioned as the default datasource. |
| `node-exporter` | Host-level metrics exporter for Ubuntu. |
| `cadvisor` | Container-level metrics exporter for Docker workloads. |

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

Install the following on the Ubuntu server:

- Docker Engine
- Docker Compose plugin
- Git

Recommended deployment path:

```bash
sudo mkdir -p /opt/compose-stack
sudo chown -R "$USER:$USER" /opt/compose-stack
```

Clone or copy this repository into `/opt/compose-stack`.

## Configuration

Create the local environment file:

```bash
cd /opt/compose-stack
cp .env.example .env
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
| `GRAFANA_INTERNAL_PORT` | `3030` | Grafana HTTP port inside the container, mapped through `GF_SERVER_HTTP_PORT`. |
| `GRAFANA_ADMIN_PASSWORD` | `change-me` | Initial Grafana admin password. Change this before production use. |

Prepare the shared host directory:

```bash
sudo mkdir -p /srv/jenkins/home
sudo chown -R 1000:1000 /srv/jenkins/home
```

## Start The Core Stack

Start Jenkins, Nginx, and Docker-in-Docker:

```bash
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

Start the full stack including Prometheus, Grafana, node-exporter, and cAdvisor:

```bash
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
docker run -d --name grafana -p 3030:3030 -e "GF_SERVER_HTTP_PORT=3030" grafana/grafana
```

On Ubuntu, Prometheus uses `host.docker.internal:9000` to scrape Jenkins through Nginx. The Compose file maps `host.docker.internal` to Docker's `host-gateway` automatically.

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

- The Docker-in-Docker daemon port `2376` is bound to `127.0.0.1` on the host, not to all network interfaces.
- Jenkins accesses Docker-in-Docker through the internal Docker network using `tcp://docker:2376`.
- The `docker:dind` service runs with `privileged: true`, which is required for this Docker-in-Docker setup.
- Do not commit `.env`; it contains local configuration and credentials.
- Change `GRAFANA_ADMIN_PASSWORD` before exposing Grafana outside a trusted network.

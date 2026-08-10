# Cloudflare Tunnel Deployment

This repository supports a Cloudflare Tunnel access mode for Ubuntu deployments. In this mode, `cloudflared` creates an outbound encrypted tunnel to Cloudflare and joins the internal Compose networks. Jenkins, Grafana, Docker-in-Docker, node-exporter, and cAdvisor do not need public host ports.

## Architecture

```text
Internet
  |
  v
Cloudflare
  |
  v
Cloudflare Tunnel
  |
  v
cloudflared
  |-- ci network ------------> jenkins:8080
  `-- observability network -> grafana:3000

Internal only:
  prometheus:9090
  docker:2376
  node-exporter:9100
  cadvisor:8080
```

Cloudflare terminates public HTTPS. The tunnel then reaches the selected service over the private Docker network using Docker DNS.

## 1. Create the tunnel

Create a remotely-managed tunnel in Cloudflare Zero Trust and copy the tunnel token.

Do not commit the token to Git.

## 2. Configure `.env`

```bash
cp .env.example .env
nano .env
```

Set at minimum:

```dotenv
CLOUDFLARE_TUNNEL_TOKEN=REPLACE_WITH_REAL_TOKEN
CLOUDFLARE_TUNNEL_PROTOCOL=http2

JENKINS_DOMAIN=jenkins.ops.example.com
GRAFANA_DOMAIN=grafana.ops.example.com
```

`JENKINS_DOMAIN` and `GRAFANA_DOMAIN` are used as operator-facing references by the setup script. The actual Published application routes are managed from Cloudflare Zero Trust.

The token is passed to the container through the `TUNNEL_TOKEN` environment variable instead of being placed in the container command line.

## 3. Start the stack

Core Jenkins stack:

```bash
sudo bash setup-cloudflare.sh
```

Jenkins plus observability:

```bash
sudo bash setup-cloudflare.sh --with-observability
```

Update an existing deployment:

```bash
sudo bash setup-cloudflare.sh --with-observability --update
```

Validate an existing deployment:

```bash
bash setup-cloudflare.sh --with-observability --check
```

## 4. Configure Cloudflare Published application routes

For Jenkins, create a Published application route with the public hostname you want and use this service target:

```text
http://jenkins:8080
```

For Grafana, when observability is enabled:

```text
http://grafana:3000
```

Example:

| Public hostname | Service target |
| --- | --- |
| `jenkins.ops.example.com` | `http://jenkins:8080` |
| `grafana.ops.example.com` | `http://grafana:3000` |

Do not create public routes for:

- `docker:2376`
- `prometheus:9090` unless there is an explicit administrative requirement
- `node-exporter:9100`
- `cadvisor:8080`

Grafana should normally be the visualization layer for Prometheus.

## Network exposure

Cloudflare Tunnel mode does not publish Jenkins, Nginx, or cloudflared ports to the host.

The observability Compose file binds Prometheus and Grafana only to loopback for host-local diagnostics:

```text
127.0.0.1:9090 -> prometheus:9090
127.0.0.1:3030 -> grafana:3000
```

These loopback bindings are not reachable through the server's public network interface.

Because Cloudflare Tunnel uses outbound connections, this mode does not require inbound public port 80 or 443 for the tunnel itself.

## Cloudflare Access recommendation

Jenkins and Grafana are management services. After the tunnel routes are working, protect their hostnames with Cloudflare Access policies rather than exposing them to unrestricted Internet users.

Typical access policy:

```text
User
  |
  v
Cloudflare Access
  |
  v
Cloudflare Tunnel
  |
  +--> Jenkins
  `--> Grafana
```

## Operational commands

Check containers:

```bash
docker compose \
  -f compose.yaml \
  -f compose.observability.yaml \
  -f compose.cloudflare.yaml \
  ps
```

Follow tunnel logs:

```bash
docker logs -f compose-stack-cloudflared
```

Restart the connector:

```bash
docker restart compose-stack-cloudflared
```

Check the full deployment:

```bash
bash setup-cloudflare.sh --with-observability --check
```

## Security notes

- Keep `CLOUDFLARE_TUNNEL_TOKEN` only in the local `.env` file or a stronger secret-management system.
- `.env` is ignored by Git.
- Do not use `--network host` for the repository deployment. The connector only needs the Compose networks required to reach its origin services.
- Do not publish Docker-in-Docker port `2376` to the host.
- Restrict Jenkins and Grafana with Cloudflare Access or an equivalent identity-aware policy.
- Consider pinning the `cloudflare/cloudflared` image to an approved version or digest for production environments.

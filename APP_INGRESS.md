# Wildcard Application Ingress with Cloudflare Tunnel

This stack can expose many deployed applications through one Cloudflare Tunnel route instead of creating a new Cloudflare route for every application.

## Architecture

```text
*.apps.example.com
        |
        v
Cloudflare Tunnel
        |
        v
cloudflared
        |
        v
nginx:80
        |
        v
compose-stack-app-ingress
        |
        +--> orders:3000
        +--> crm:8080
        +--> portal:3000
```

Cloudflare owns the public HTTPS edge. Nginx routes requests by hostname to containers on a shared Docker network.

## 1. Environment

Set these values in `.env`:

```dotenv
APP_INGRESS_NETWORK_NAME=compose-stack-app-ingress
APP_DOMAIN_SUFFIX=apps.example.com
```

Do not commit the real `.env` file.

## 2. Cloudflare Published Application Route

Create this route once in the same remotely-managed tunnel used by this stack:

```text
Hostname: *.apps.example.com
Service:  http://nginx:80
```

The wildcard suffix must match `APP_DOMAIN_SUFFIX`.

Jenkins and Grafana may keep their own explicit routes if desired:

```text
jenkins.ops.example.com -> http://jenkins:8080
grafana.ops.example.com -> http://grafana:3000
```

Do not publish Prometheus, Docker DinD, node-exporter, or cAdvisor.

## 3. Application Compose Contract

Each deployed application that should be reachable through the wildcard ingress must join the external shared network:

```yaml
services:
  app:
    image: ${IMAGE_REF:?IMAGE_REF is required}
    restart: unless-stopped
    expose:
      - "3000"
    networks:
      - app-ingress

networks:
  app-ingress:
    external: true
    name: ${APP_INGRESS_NETWORK_NAME:-compose-stack-app-ingress}
```

A complete example is available at:

```text
examples/node-app/compose.cloudflare-app.example.yaml
```

The application does not need a public host port.

## 4. Register a Hostname

Deploy the application first, then register its hostname:

```bash
sudo bash /opt/compose-stack/app-route.sh register \
  --host orders.apps.example.com \
  --upstream app:3000
```

For unique Docker DNS names, prefer a service/container alias specific to the application, for example:

```text
orders:3000
crm:8080
portal:3000
```

The helper writes a runtime Nginx virtual host and reloads Nginx only after `nginx -t` succeeds.

## 5. List Routes

```bash
bash /opt/compose-stack/app-route.sh list
```

## 6. Remove a Route

```bash
sudo bash /opt/compose-stack/app-route.sh remove \
  --host orders.apps.example.com
```

Remove the Nginx route before or together with retiring the application.

## 7. Jenkins Deployment Pattern

A deployment pipeline can use the following order:

```text
build image
  -> push immutable image
  -> deploy application Compose stack
  -> attach application to compose-stack-app-ingress
  -> register/update hostname with app-route.sh
  -> verify public HTTPS health endpoint
```

Example remote deployment commands:

```bash
cd /opt/orders
IMAGE_REF="$DEPLOY_IMAGE_REF" docker compose pull app
IMAGE_REF="$DEPLOY_IMAGE_REF" docker compose up -d --no-build app

sudo bash /opt/compose-stack/app-route.sh register \
  --host orders.apps.example.com \
  --upstream orders:3000
```

The SSH deployment user must be allowed to execute the route helper. In production, prefer a narrowly scoped sudoers rule for `app-route.sh` instead of unrestricted passwordless sudo.

## 8. Naming Recommendation

Use a stable convention such as:

```text
<application>.apps.example.com
```

or separate environment suffixes:

```text
<application>.dev.example.com
<application>.staging.example.com
```

If environments use different wildcard suffixes, deploy separate ingress stacks or explicitly plan the network and routing boundary for each environment.

## 9. Security Notes

- The application containers should not publish their application ports to `0.0.0.0` when Cloudflare Tunnel is the intended ingress.
- Only containers that need public application ingress should join `compose-stack-app-ingress`.
- Keep databases, Redis, queues, Docker DinD, and monitoring exporters off the application ingress network.
- Cloudflare Access can be added to sensitive hostnames.
- Runtime route files are stored under `runtime/nginx/apps/` and are intentionally not committed.

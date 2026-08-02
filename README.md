# Jenkins Blue Ocean Docker Compose Stack

Compose stack ini menggantikan dua command `docker run` Jenkins Blue Ocean + Docker-in-Docker menjadi struktur yang lebih mudah di-clone ke server Ubuntu.

## Struktur

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

## Service

- `jenkins`: Jenkins LTS + Blue Ocean + Docker CLI + plugin Pipeline/Docker/Prometheus.
- `nginx`: reverse proxy ke Jenkins memakai config `nginx/default.conf`.
- `docker`: Docker-in-Docker daemon dengan TLS, network alias `docker`, dan volume certificate yang sama dengan Jenkins.
- `prometheus`: scraping Jenkins, host metrics, dan container metrics.
- `grafana`: dashboard UI dengan datasource Prometheus otomatis.
- `node-exporter`: metrics host Ubuntu.
- `cadvisor`: metrics container Docker.

## Persiapan di Ubuntu

Install Docker Engine dan Docker Compose plugin terlebih dahulu, lalu clone folder/repo ini ke server.

```bash
cp .env.example .env
mkdir -p /srv/jenkins/home
sudo chown -R 1000:1000 /srv/jenkins/home
```

Ubah `.env` sesuai kebutuhan, terutama:

- `JENKINS_HTTP_PORT=49000`
- `NGINX_HTTP_PORT=9000`
- `HOST_HOME=/srv/jenkins/home`
- `GRAFANA_ADMIN_PASSWORD=change-me`

## Menjalankan Jenkins

```bash
docker compose up -d --build
```

Akses:

- Jenkins: `http://SERVER_IP:49000`
- Jenkins via Nginx: `http://SERVER_IP:9000`
- Jenkins agent inbound port: `50000`

Ambil initial admin password:

```bash
docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

## Menjalankan Dengan Prometheus dan Grafana

```bash
docker compose -f compose.yaml -f compose.observability.yaml up -d --build
```

Akses:

- Prometheus: `http://SERVER_IP:9090`
- Grafana: `http://SERVER_IP:3001`

Login Grafana memakai `GRAFANA_ADMIN_USER` dan `GRAFANA_ADMIN_PASSWORD` dari `.env`.

## Catatan Keamanan

- Port Docker daemon `2376` dibind ke `127.0.0.1`, bukan semua interface server. Jenkins tetap mengakses Docker lewat network internal `tcp://docker:2376`.
- Service `docker:dind` berjalan dengan `privileged: true` karena dibutuhkan Docker-in-Docker.
- Jangan commit file `.env` karena berisi konfigurasi lokal dan password Grafana.

## Perintah Operasional

```bash
docker compose ps
docker compose logs -f jenkins
docker compose restart jenkins
docker compose down
```

Hapus semua data Jenkins dan observability jika benar-benar ingin reset total:

```bash
docker compose -f compose.yaml -f compose.observability.yaml down -v
```

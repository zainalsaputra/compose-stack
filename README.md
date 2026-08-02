# Compose Stack

Compose stack ini adalah layout non-separated: semua service utama dijalankan dari root folder ini. Folder ini cocok di-clone ke server Ubuntu, misalnya ke `/opt/compose-stack`.

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

Tidak ada folder `jenkins/` pada setup ini karena Jenkins adalah service utama di `compose.yaml`, sementara `Dockerfile` Jenkins berada langsung di root.

## Service

- `jenkins`: Jenkins LTS + Blue Ocean + Docker CLI + plugin Pipeline/Docker/Prometheus.
- `nginx`: reverse proxy ke Jenkins memakai config `nginx/default.conf`.
- `docker`: Docker-in-Docker daemon dengan TLS, network alias `docker`.
- `prometheus`: scraping Jenkins, host metrics, dan container metrics.
- `grafana`: dashboard UI dengan datasource Prometheus otomatis.
- `node-exporter`: metrics host Ubuntu.
- `cadvisor`: metrics container Docker.

## Volume

Default stack ini memakai Docker named volume, bukan folder data di dalam repo.

| Volume | Isi | Lokasi fisik di Ubuntu |
| --- | --- | --- |
| `compose-stack-jenkins-data` | Jenkins home, jobs, plugins, credentials, config | `/var/lib/docker/volumes/compose-stack-jenkins-data/_data` |
| `compose-stack-jenkins-docker-certs` | TLS cert Docker-in-Docker client | `/var/lib/docker/volumes/compose-stack-jenkins-docker-certs/_data` |
| `compose-stack-prometheus-data` | Prometheus TSDB | `/var/lib/docker/volumes/compose-stack-prometheus-data/_data` |
| `compose-stack-grafana-data` | Grafana database, sessions, plugins | `/var/lib/docker/volumes/compose-stack-grafana-data/_data` |

Saya sarankan data stateful tetap di Docker named volume karena lebih aman untuk Git repo dan lebih mudah dipindahkan dengan backup Docker. Yang masuk repo hanya config deklaratif seperti `compose.yaml`, `nginx/default.conf`, `prometheus/prometheus.yml`, dan provisioning Grafana.

Bind mount yang tetap dipakai:

- `${HOST_HOME:-/srv/jenkins/home}:/home`

Folder ini untuk shared workspace tambahan yang bisa Anda akses langsung dari host. Buat foldernya di server:

```bash
sudo mkdir -p /srv/jenkins/home
sudo chown -R 1000:1000 /srv/jenkins/home
```

Jika suatu saat ingin memakai bind mount lokal di repo, pakai folder `data/`; folder itu sudah masuk `.gitignore`.

## Networking

Untuk non-separated setup, network disimpan langsung di file compose karena semua service naik dari satu root folder.

Network yang dipakai:

- `ci`, dengan nama aktual default `compose-stack-ci`.
- `observability`, dengan nama aktual default `compose-stack-observability`.

Pembagian:

- `ci`: Jenkins, Nginx, dan Docker-in-Docker.
- `observability`: Prometheus, Grafana, node-exporter, dan cAdvisor.
- Prometheus masuk ke dua network karena perlu scrape Jenkins di `ci` dan exporter di `observability`.

Nginx melakukan proxy ke `http://jenkins:8080` lewat Docker DNS internal. Docker-in-Docker tetap diakses Jenkins lewat `tcp://docker:2376`.

## Persiapan di Ubuntu

Install Docker Engine dan Docker Compose plugin terlebih dahulu, lalu clone repo ini.

```bash
sudo mkdir -p /opt/compose-stack
sudo chown -R "$USER:$USER" /opt/compose-stack
cd /opt/compose-stack
cp .env.example .env
sudo mkdir -p /srv/jenkins/home
sudo chown -R 1000:1000 /srv/jenkins/home
```

Ubah `.env` sesuai kebutuhan, terutama:

- `COMPOSE_PROJECT_NAME=compose-stack`
- `CI_NETWORK_NAME=compose-stack-ci`
- `OBSERVABILITY_NETWORK_NAME=compose-stack-observability`
- `JENKINS_HTTP_PORT=49000`
- `NGINX_HTTP_PORT=9000`
- `HOST_HOME=/srv/jenkins/home`
- `GRAFANA_ADMIN_PASSWORD=change-me`

## Menjalankan Stack Utama

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

## Menjalankan Dengan Observability

```bash
docker compose -f compose.yaml -f compose.observability.yaml up -d --build
```

Akses:

- Prometheus: `http://SERVER_IP:9090`
- Grafana: `http://SERVER_IP:3001`

Login Grafana memakai `GRAFANA_ADMIN_USER` dan `GRAFANA_ADMIN_PASSWORD` dari `.env`.

## Backup Volume

Contoh backup Jenkins data:

```bash
docker run --rm -v compose-stack-jenkins-data:/data -v "$PWD/backups:/backup" alpine tar czf /backup/jenkins-data.tgz -C /data .
```

Restore sebaiknya dilakukan saat container Jenkins sudah berhenti.

## Catatan Keamanan

- Port Docker daemon `2376` dibind ke `127.0.0.1`, bukan semua interface server.
- Jenkins tetap mengakses Docker lewat network internal `tcp://docker:2376`.
- Service `docker:dind` berjalan dengan `privileged: true` karena dibutuhkan Docker-in-Docker.
- Jangan commit file `.env` karena berisi konfigurasi lokal dan password Grafana.

## Perintah Operasional

```bash
docker compose ps
docker compose logs -f jenkins
docker compose restart jenkins
docker compose down
```

Hapus semua container dan network, tetapi pertahankan volume:

```bash
docker compose -f compose.yaml -f compose.observability.yaml down
```

Reset total termasuk semua volume:

```bash
docker compose -f compose.yaml -f compose.observability.yaml down -v
```

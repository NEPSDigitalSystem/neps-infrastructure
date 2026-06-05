# NEPS Digital — Infrastructure & DevOps

This repository (`neps-infrastructure`) is the central nervous system of the NEPS Digital project. It orchestrates the various microservices (`neps-portal`, `neps-backend`, `neps-ml-ai`, `neps-data-platform`), manages their networking, enforces security, and monitors their health.

---

## 🛠️ Technology Stack

- **Containerization & Orchestration:** Docker, Docker Compose
- **Web Server / Reverse Proxy:** Nginx (with HTTPS & Security Headers)
- **Database layer:** PostgreSQL 15 (with automated PITR)
- **Monitoring & Observability:** Prometheus (Metrics), Grafana (Visualization), Loki (Logs), Alertmanager (Alerting)
- **Security:** Trivy (Image Scanning), Docker Secrets, GHCR
- **CI/CD:** GitHub Actions, Dependabot

---

## 🏗️ Architecture & How It Works

The `neps-infrastructure` repository serves as the unified orchestration layer.

- **`docker-compose.yml`**: The single source of truth for the entire stack.
- **Networks**: Segments the system into three tiers:
  1. `neps-public`: Only the Nginx proxy (Ports 80, 443).
  2. `neps-internal`: Backend, ML, and Data services.
  3. `neps-database`: Fully isolated for PostgreSQL.
- **`nginx/`**: Handles TLS termination and routing.

---

## 🔐 Security Mechanisms

1. **HTTPS/TLS**: Nginx enforces SSL and security headers (CSP, HSTS).
2. **Secrets Management**: Sensitive data (DB passwords, Auth secrets) are wired via **Docker Secrets** (`/run/secrets/`), avoiding plain-text environment variables.
3. **Hardened Containers**: 
   - All services run with `no-new-privileges: true`.
   - Applications run as non-root users (`nextjs` for portal, `python` for backend).
4. **CI/CD Scanning**: Every PR triggers a **Trivy security scan** before deployment.

---

## 📈 Monitoring & Observability

- **Prometheus**: Scrapes metrics from `/metrics` endpoints.
- **Loki & Promtail**: Centralized log aggregation for all containers.
- **Alertmanager**: Handles critical alerts (defined in `monitoring/rules/`).
- **Grafana**: Automatically provisioned with datasources and the "NEPS Overview" dashboard.

---

## 🔄 Disaster Recovery (PITR & Rollbacks)

- **Point-In-Time Recovery (PITR)**: Scripts (`pitr-setup.sh`, `backup-pitr.sh`, `pitr-restore.sh`) automatically perform daily base backups and continuous WAL (Write-Ahead Log) archiving, allowing the PostgreSQL database to be restored to *any specific second* in the past 30 days.
- **Rollbacks**: The `rollback.sh` script supports instant Blue-Green deployment switching via Nginx, and specific git SHA-based container pullbacks if a bad image enters production.

---

## 🏗️ CI/CD & Containerization

The NEPS pipeline emphasizes automation from code push to deployment:
1. **GitHub Actions**: Workflows (`ci-cd.yml`) exist in every repository to validate code, run tests, and build Docker containers upon push.
2. **GHCR Container Registry**: We use `ghcr.io/nepsdigitalsystem/` as our private image registry. The pipelines authenticate using an organization-wide `GHCR_PAT` secret, ensuring secure, token-based programmatic pushes.
3. Once containers are pushed to GHCR, `neps-infrastructure` pulls those updated images down using our `push-all-repos.ps1` synchronization script.

---

### Quick Start

**Local development** (builds from source, ML/data stubs):
```bash
./scripts/setup-secrets.sh
docker compose up -d
```

**Production / staging** (pulls versioned images from GHCR):
```bash
./scripts/setup-secrets.sh
export IMAGE_TAG=latest   # or a specific git SHA
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

**Rollback** to a prior deploy: `./scripts/rollback.sh previous` — see `docs/rollback-setup.md`.

# NEPS Digital — Infrastructure & DevOps

This repository (`neps-infrastructure`) is the central nervous system of the NEPS Digital project. It orchestrates the various microservices (`neps-portal`, `neps-backend`, `neps-ml-ai`, `neps-data-platform`), manages their networking, enforces security, and monitors their health.

---

## 🛠️ Technology Stack

- **Containerization & Orchestration:** Docker, Docker Compose
- **Web Server / Reverse Proxy:** Nginx
- **Database layer:** PostgreSQL (with automated PITR)
- **Monitoring & Observability:** Prometheus (Metrics), Grafana (Dashboards)
- **CI/CD:** GitHub Actions, GitHub Container Registry (GHCR)
- **Scripting:** Bash & PowerShell

---

## 🏗️ Architecture & How It Works

This repository ties the entire NEPS Digital ecosystem together using Docker Compose as our **Configuration as Code**. Instead of running services individually, `neps-infrastructure` defines how they securely communicate.

- **`docker-compose.yml`**: Defines the base orchestration for the core microservices.
- **`docker-compose.networks.yml`**: Segments the system into three tiers:
  1. `neps-public`: Accessible from the outside relative to the Nginx reverse proxy.
  2. `neps-internal`: Backend and ML APIs communicating privately without public exposure.
  3. `neps-database`: Fully isolated network exclusively for the PostgreSQL backend.

---

## 🔐 Security Mechanisms

Security is built-in following the Principle of Least Privilege:
1. **Hardened Base Images** (`hardened-base.Dockerfile`): All Python microservices use a customized, stripped-down Debian-slim container. It runs as a non-root user (`neps`), Drops all privileges, and disables shell access (`/sbin/nologin`).
2. **Container Overlays** (`docker-compose.security.yml`):
   - `read_only: true`: All containers run with immutable filesystems.
   - `no-new-privileges: true`: Prevents privilege escalation.
   - Resource limits (CPU/Memory) prevent Denial of Service (DoS) attacks.
3. **Automated Secrets** (`scripts/setup-secrets.sh`): Auto-generates cryptographic keys and database passwords for Docker to mount securely into `/run/secrets/`.

---

## 📈 Monitoring, Alerting, & Dashboards

We utilize an enterprise-grade observability stack:
- **Prometheus**: Automatically scrapes metrics from `/metrics` endpoints across the ecosystem every 15 seconds.
- **Critical Alerts** (`neps-alerts.yml`): AlertManager is configured to trigger on:
  - High error rates or service downtime.
  - Resource exhaustion (CPU/Disk/Memory).
  - Data Pipeline failures or Database Replication lags.
  - **Safeguarding Crisis Alerts**: Real-time psychological distress alerts trigger P0 operations.
- **Grafana**: A centralized System Overview Dashboard providing visual insight into REDCap synchronization latency, database connections, and ML model accuracy.

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
To bootstrap the entire infrastructure locally or on a production server:
```bash
./scripts/setup-secrets.sh
docker-compose -f docker-compose.yml -f docker-compose.networks.yml -f docker-compose.security.yml up -d
```

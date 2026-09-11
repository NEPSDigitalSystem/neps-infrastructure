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
- **Mock REDCap API Integration**: Underpins development of the data ingestion pipelines. It exposes realistic clinical and qualitative longitudinal data, including the newly integrated **2000-row semantically correlated NLP dataset** (with text-derived sentiment, emotions, themes, and clinical statuses) which allows the `neps-ml-ai` models and `neps-data-platform` pipelines to train and run tests on clean, non-random correlation patterns before swapping to the live REDCap server.

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

- **Prometheus**: Scrapes metrics from internal `/metrics` endpoints.
- **Blackbox Exporter**: Actively probes external HTTP/TCP endpoints to monitor service uptime from the user's perspective.
- **Loki & Promtail**: Centralized log aggregation for all containers.
- **Alertmanager**: Handles critical infrastructure and clinical alerts (defined in `monitoring/rules/`), including high-distress safeguarding crisis detection, database/disk thresholds, and data pipeline failures.
- **Grafana**: Automatically provisioned with datasources and the "NEPS Overview" dashboard.

---

## 🔄 Disaster Recovery (PITR & Rollbacks)

- **Point-In-Time Recovery (PITR)**: Scripts (`pitr-setup.sh`, `backup-pitr.sh`, `pitr-restore.sh`) automatically perform daily base backups and continuous WAL (Write-Ahead Log) archiving, allowing the PostgreSQL database to be restored to *any specific second* in the past 30 days.
- **PITR Drills**: The `pitr-drill.sh` script allows administrators to perform safe, end-to-end disaster recovery testing. It spins up an isolated temporary PostgreSQL instance on a separate port to verify data restoration without touching the live database.
- **Rollbacks**: The `rollback.sh` script supports instant Blue-Green deployment switching via Nginx, and specific git SHA-based container pullbacks if a bad image enters production.

---

## 🏗️ CI/CD & Containerization

The NEPS pipeline emphasizes automation from code push to deployment:
1. **GitHub Actions**: Workflows (`ci-cd.yml`) exist in every repository to validate code, run tests, and build Docker containers upon push.
2. **GHCR Container Registry**: We use `ghcr.io/nepsdigitalsystem/` as our private image registry. The pipelines authenticate using an organization-wide `GHCR_PAT` secret, ensuring secure, token-based programmatic pushes.
3. Once containers are pushed to GHCR, `neps-infrastructure` pulls those updated images down using our `push-all-repos.ps1` synchronization script (located at the workspace root).

---

### Quick Start

**Local development** (builds from source, ML/data stubs):
```bash
./scripts/setup-secrets.sh
docker compose up -d
```

**Production** (pulls versioned images from GHCR):
```bash
./scripts/setup-secrets.sh
export IMAGE_TAG=latest   # or a specific git SHA
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.discord-alerts.yml up -d
```

---

## 🧪 Staging Environment

Staging runs the **identical stack** as production using the same Dockerfiles and base compose service definitions. Isolation is provided by:

1. **Namespaced project name** — `COMPOSE_PROJECT_NAME=neps-staging` prefixes every container, volume, and network name so staging never touches production data.
2. **Separate host ports** — staging nginx binds `18080:80 / 18443:443` (prod: `80/443`); all other services shift by +10,000 (e.g. portal `13000`, backend `18000`, Grafana `13001`, Prometheus `19090`, Alertmanager `19093`, PgAdmin `15050`, Postgres `15432`).
3. **Separate data volumes** — staging gets its own `postgres-data-staging`, `wal-archive-staging`, `base-archive-staging`, `grafana-data-staging`, `prometheus-data-staging`, `redis-data-staging`, `alertmanager-data-staging`, `loki-data-staging`, `pgadmin-data-staging`. PITR restore drills on staging do not touch production backups.
4. **Separate Discord alert route** — `alertmanager.staging.yml` routes all critical/warning alerts to `#staging-alerts` test-only channel via `secrets/discord_webhook_url_staging.txt`. A synthetic alert smoke test is scheduled at 10:00 UTC every day via Ofelia to confirm the routing is live.
5. **Separate Ofelia scheduler config** — `config.staging.ini` looks up staging-prefixed container names (`neps-staging-neps-data-platform-1` etc.), because Ofelia matches containers by resolved Docker name.
6. **Separate Nginx config** — `staging-nginx.conf` emits the `X-NEPS-Environment: staging` response header and `X-Robots-Tag: noindex` so staging is never indexed and every response is identifiable.

### Option A — Single-host staging (prod + staging side-by-side on one KNUST VM)

This is the zero-hardware option — recommended before the second physical VM is provisioned:

```bash
# ── One-time secrets setup ──────────────────────────────────────────────
./scripts/setup-secrets.sh
# Create staging-only secret (separate Discord test webhook URL)
mkdir -p secrets
echo "https://discord.com/api/webhooks/YOUR_STAGING_WEBHOOK_URL" > secrets/discord_webhook_url_staging.txt
mkdir -p backups/staging-minio backups/staging-postgres

# ── Bring STAGING up ────────────────────────────────────────────────────
export COMPOSE_PROJECT_NAME=neps-staging
export IMAGE_TAG=staging          # or a specific git SHA for pinned deploy
docker compose -f docker-compose.yml \
              -f docker-compose.prod.yml \
              -f docker-compose.staging.yml \
              up -d

# ── Verify staging is up ────────────────────────────────────────────────
# All staging URLs use the +10000 ports:
#   Frontend:      http://<host>:13000   (or nginx: http://<host>:18080)
#   Backend:       http://<host>:18000/health
#   Grafana:       http://<host>:13001
#   Prometheus:    http://<host>:19090
#   Alertmanager:  http://<host>:19093
#   PgAdmin:       http://<host>:15050
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.staging.yml ps
```

Then separately (in a different shell, without `COMPOSE_PROJECT_NAME=neps-staging` exported), bring production up normally — it will own `:80 / :443 / :3000 / :8000 / :3001 / :9090`.

### Option B — Dedicated staging VM (separate physical KNUST host)

Same commands as Option A, but run them on the second VM with `DEPLOY_HOST` / `DEPLOY_USER` / `DEPLOY_KEY` GitHub vars replaced by `STAGING_DEPLOY_HOST` / `STAGING_DEPLOY_USER` / `STAGING_DEPLOY_KEY` in the CI secrets. Port overlap no longer matters (you can even edit the staging overlay ports back to 80/443 for a VM that doesn't host prod).

### Git-branch flow with staging

The staging tier is wired to the `staging` branch in all 5 repos:
```
feature-branch  →  PR to staging  →  CI runs validate/build/security
                              ↘    (if STAGING_DEPLOY_HOST GitHub var is set)
                               ↘   deploy-staging job deploys to staging server
                                              ↓
                                on-call smoke-tests on staging URLs
                                              ↓
                                     PR from staging → main
                                              ↓
                                deploy job deploys to production server
```
Push to `main` always triggers production only; push to `staging` always triggers staging only. The two deploy jobs never race because they're guarded by `github.ref`:

| Push to branch | Validated | Built | Security-scanned | Deployed to |
|---|---|---|---|---|
| feature/* | ✅ | ✅ | ✅ (fs only, no fail) | — |
| PR to main/staging | ✅ | ✅ | ✅ (fs only, no fail) | — |
| `staging` | ✅ | ✅ | ✅ (image, fails on HIGH/CRITICAL) | **staging server** (if var set) |
| `main` | ✅ | ✅ | ✅ (image, fails on HIGH/CRITICAL) | **production server** (if var set) |

**Rollback** to a prior deploy: `./scripts/rollback.sh previous` — see `docs/rollback-setup.md`.

**Discord alerts** (optional): see `docs/discord-alerts-setup.md` — prod uses `docker-compose.discord-alerts.yml` overlay with the real safeguarding channel; staging uses the webhook written to `secrets/discord_webhook_url_staging.txt` automatically.

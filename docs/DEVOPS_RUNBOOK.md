# NEPS Digital: DevOps Architecture & Runbook

**Audience:** DevOps Engineers, SREs (Site Reliability Engineers), and Infrastructure Administrators.
**Purpose:** Outlines the core operational capabilities, disaster recovery mechanisms (PITR / Rollbacks), observability stack (Prometheus / Grafana), and security topologies orchestrated within the NEPS Digital environment.

## 📁 1. Infrastructure Automation Scripts
These scripts reside in `neps-infrastructure/scripts/` and automate the heavy lifting of cluster maintenance and disaster resilience.

### `rollback.sh`
- **Function:** Provides instant, zero-downtime rollbacks for the entire microservice ecosystem.
- **How it Works:** By reading the `.deployment-history`, this script pulls down older GHCR image SHAs and leverages `docker-compose.rollback.yml` as an override overlay. It executes a container rollback and runs strict `/health` polling on the APIs before successfully declaring the environment fully restored. 
- **Usage:** `./rollback.sh previous` or `./rollback.sh specific-sha <commit-sha>`

### `pitr-setup.sh`
- **Function:** Initializes PostgreSQL Point-in-Time Recovery configuration.
- **How it Works:** Injected into the initial `postgres` container creation via `/docker-entrypoint-initdb.d/`. It forces PostgreSQL into WAL (Write-Ahead Logging) `replica` mode and sets up the `archive_command` to proactively flush WAL files out of the container and into the persistent `/backup/pitr/wal/` volume every 60 seconds.

### `backup-pitr.sh`
- **Function:** Performs automated "Base Backups".
- **How it Works:** Uses `pg_basebackup` to stream a full database snapshot into a compressed tarball every day. It cleans up base backups older than 30 days and removes orphaned WAL logs. These base backups serve as the "checkpoint" for point-in-time recovery.

### `pitr-restore.sh`
- **Function:** Executes precise, down-to-the-second recovery.
- **How it Works:** If database corruption or accidental cascading deletions occur, this script stops the `postgres` container, injects the last known healthy base backup into the recovery directory, and processes WAL logs forward using `recovery_target_time`.
- **Usage:** `./pitr-restore.sh "2026-05-27 14:30:15"`

### `setup-secrets.sh`
- **Function:** Cryptographic bootstrapping.
- **How it Works:** Dynamically generates highly secure strings, asymmetric JWT keys (`jwt_private.pem`, `jwt_public.pem`), and database credentials at deployment time. It drops these plain-text outputs strictly into the host's `secrets/` directory (`chmod 600`), and provisions them safely to corresponding Docker swarm/compose containers using Docker's native secret manager.

### `health-check.sh`
- **Function:** Advanced dependency chain awareness.
- **How it Works:** Rather than just returning HTTP 200 via an API, this script recursively checks if the underlying PostgreSQL connection is active, if Redis is responding to PINGs, and if upstream system disks have capacity. It acts as the backbone logic behind the `HEALTHCHECK` command inside our `hardened-base.Dockerfile`.

---

## 📈 2. Monitoring & Alerting 

Unlike standard web applications, the NEPS ecosystem requires aggressive monitoring for both infrastructural health and real-life psychological safeguarding. 

### The Metrics Flow (Prometheus)
1. **Application Layer:** Each microservice (`neps-backend`, `neps-portal`, `neps-ml-ai`) exposes a `/metrics` or `/api/metrics` endpoint utilizing Prometheus client libraries.
2. **Infrastructure Layer:** `node-exporter` tracks raw host CPU/Memory, while `postgres-exporter` tracks dead tuples and DB connections.
3. **Scraping Mechanism:** The central `prometheus` container executes a pull-based scrape against all internal Docker DNS targets (`neps-backend:8000`, `redis:6379`) every 15 seconds.

### Centralized Dashboards & Logging (Grafana)
Grafana sits on port `3001` and connects directly to Prometheus and Loki as continuous data sources. It is automatically provisioned on boot.
- **Metrics**: Query Prometheus for service performance.
- **Logs**: Query Loki for real-time container logs across the whole stack.

### Automated Alerting (Alertmanager & Rules)
Defined heavily in `monitoring/rules/neps-alerts.yml` and handled by the `alertmanager` service.
- **Infrastructure Alerts**: Triggers if CPU/Memory surpasses threshold, if services are down, or if error rates spike.
- **Safeguarding Crisis Alerts**: P0 alerts for psychological distress identified by ML models.

---

## 🔐 3. Security Engineering & Network Isolation

The infrastructure adheres to the **"Defense in Depth"** methodology.

### Zero-Trust Networking
All microservices communicate across the restricted `neps-internal` bridge. Only Nginx is exposed publicly.

### Container Hardening
- **no-new-privileges**: Enforced on all containers to prevent privilege escalation.
- **Non-Root Processes**: All application processes run as unprivileged users (`nextjs`, `neps`).
- **Image Scanning**: Trivy scans images in CI/CD before they reach GHCR.

### Nginx Edge Security & HTTPS
- **TLS Termination**: Enforced on port 443 with a 301 redirect from port 80.
- **Security Headers**: CSP, HSTS, and X-Frame-Options are set at the edge.

---

## 🛠️ 4. Maintenance & Scaling

### Adding a New Microservice
1. **Docker Compose**: Add the service block to `docker-compose.yml`.
2. **Networking**: Ensure it is connected to `neps-internal`.
3. **Metrics**: Expose a `/metrics` endpoint (see `monitoring/SERVICE_METRICS_GUIDE.md`).
4. **Nginx**: Add a new `location` block in `nginx/nginx.conf` to route traffic.
5. **CI/CD**: Copy the `ci-cd.yml` template from `neps-infrastructure` and configure repo secrets (`GHCR_PAT`, etc.).

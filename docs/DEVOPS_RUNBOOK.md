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

### Centralized Dashboards (Grafana)
Grafana sits on port `3001` and connects directly to Prometheus and PostgreSQL as continuous data sources. It is automatically provisioned with the `neps-overview.json` schema on boot, eliminating manual dashboard creation.
- **Key Visuals:** REDCap Sync Failure Rates, Memory Usage across ML Containers, Live User Logins, and API rate-limit drops.

### Automated Alerting (AlertManager & Rules)
Defined heavily in `monitoring/rules/neps-alerts.yml`.
- **Infrastructure Alerts:** Triggers operations pages if CPU/Memory surpasses 90% (`MemoryHigh`), if Docker Containers crash (`ServiceDown`), or if endpoints shoot over 5% failure rates (`HighErrorRate`).
- **Safeguarding Crisis Alerts:** The backend exposes `neps_safeguarding_alerts`. If the analytics/ML models determine a High-Risk crisis for a user (e.g., severe depressive intent identified from inputs), it fires an immediate `Severity: Critical` webhook directly to the administrative healthcare team.

---

## 🔐 3. Security Engineering & Network Isolation

The infrastructure adheres to the **"Defense in Depth"** methodology.

### Zero-Trust Docker Networking (`docker-compose.networks.yml`)
The Nginx inverse proxy is the ONLY container accessible from the host (`neps-public`). 
All microservices communicate across a restricted internal bridge (`neps-internal`). 
The `postgres` and `redis` instances are segmented completely into a non-routable `neps-database` subnet resulting in true network-layer isolation.

### Container Immutability & Hardening (`docker-compose.security.yml`)
- All Python APIs use the customized `hardened-base.Dockerfile`. They run entirely under a unprivileged `neps` (UID 1000) user.
- Root shell access is physically deleted from the container. 
- Containers are launched with `read_only: true`, meaning an attacker cannot download malware payloads or edit scripts even if an RCE vulnerability exists. Temporary file writes are restricted to `tmpfs` RAM-disks marked explicitly as `noexec, nosuid`.
- Privilege escalation is disabled via the `no-new-privileges: true` Docker security mapping.
- All Docker Linux capabilities (`cap_drop: ALL`) are stripped, retaining only `NET_BIND_SERVICE`.

### Nginx Edge Security
- **Rate Limiting:** IP-level throttling using `limit_req_zone` ensures standard APIs handle `10 req/sec` while Auth routes are heavily restricted to `1 req/sec` to prevent brute force.
- **Header Hardening:** Forces `X-Frame-Options` and strict Content Security Policies preventing cross-site scripting attacks at the edge before hitting the API mesh.

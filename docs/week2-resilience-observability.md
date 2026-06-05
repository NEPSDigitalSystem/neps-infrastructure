# Week 2 — Resilience & Observability (Handover)

This is the consolidated handover view of Week 2's resilience and observability
work on the canonical `neps-infrastructure/docker-compose.yml`. It merges four
task docs, which remain in place as the detailed source of record:
[wal-archiving-fix.md](./wal-archiving-fix.md),
[pitr-restore-drill.md](./pitr-restore-drill.md),
[rollback-setup.md](./rollback-setup.md),
[observability-setup.md](./observability-setup.md).

## Summary

Four tasks landed this week. Three are **done and proven** (applied + verified
end-to-end): WAL archiving was restored from broken scaffolding to a working,
persistent archive; a full PITR restore drill destroyed and rebuilt the database
to a precise point in time; and the observability stack gained Alertmanager,
Loki, and Promtail with Grafana provisioning fixed. The fourth, the rollback
overlay, is **staged but inert** — the file is correct and merge-validated, but it
cannot perform a real rollback until the base compose runs versioned GHCR images
instead of placeholder stubs. All consolidated follow-ups (supervisor decisions +
engineering tasks) are collected in the final section.

| Task | What it does | Status |
|---|---|---|
| **Task 1 — WAL archiving** | Continuous WAL archiving to a persistent, dedicated volume (PITR foundation) | ✅ **Done / proven** |
| **Task 3 — PITR restore drill** | Validated point-in-time recovery from base backup + WAL replay | ✅ **Done / proven** |
| **Task 2 — Observability** | Alertmanager + Loki + Promtail; Grafana datasource/dashboard provisioning | ✅ **Done / proven** |
| **Task 4 — Rollback** | `IMAGE_TAG`-driven overlay to roll services to a prior image version | ⚠️ **Staged — correct but inert** |

---

# Task 1 — WAL Archiving

Restores working WAL archiving (PITR foundation) on the canonical infrastructure
stack. Prior to this work, archiving was silently disabled — the configuration
was scaffolding that never applied any settings, and the archive destination was
ephemeral.

**Canonical file:** `neps-infrastructure/docker-compose.yml` (the file CI, the
README launch command, and the ops scripts all use). The orphaned
`neps-infrastructure/docker/docker-compose.yml` was **not** touched.

## What was done

### 1. Fixed WAL archiving in `docker-compose.yml` (postgres service)

- **Removed** the broken `POSTGRES_INITDB_ARGS: "--wal-level=replica --archive-mode=on"`.
  `--wal-level` and `--archive-mode` are **not** valid `initdb` flags (they are
  `postgresql.conf` parameters), so the line set nothing — on an existing data
  volume it was silently ignored, and on a fresh volume it would abort init.
- **Added a `command:` override** (YAML list form) passing the real settings
  directly to the server:

  ```yaml
  command:
    - postgres
    - -c
    - wal_level=replica
    - -c
    - archive_mode=on
    - -c
    - "archive_command=test ! -f /backup/pitr/wal/%f && cp %p /backup/pitr/wal/%f"
    - -c
    - archive_timeout=60
  ```

  The list form keeps the whole `archive_command` (including `&&`, `%f`, `%p`) as
  a single argument with no shell re-parsing on the Docker side. The
  `test ! -f … &&` guard refuses to overwrite an already-archived segment.

### 2. Added a dedicated `wal-archive` volume

A named volume mounted at `/backup/pitr/wal`, **separate from `postgres-data`**,
and declared in the top-level `volumes:` block. Archives now survive loss or
recreation of the data volume (previously the path existed only in the
container's ephemeral layer and was lost on every recreate).

### 3. Added a one-shot `postgres-init` service (volume ownership)

A freshly created named volume is owned `root:root`, but postgres runs
`archive_command` as uid 70 — so the first archive write would fail with
*permission denied*. The init service fixes this before postgres starts:

```yaml
postgres-init:
  image: postgres:15-alpine
  user: root
  command: chown -R 70:70 /backup/pitr/wal
  volumes:
    - wal-archive:/backup/pitr/wal
  networks:
    - neps-network
```

postgres waits for it:

```yaml
depends_on:
  postgres-init:
    condition: service_completed_successfully
```

> Note: in Task 3 this init service was extended to also chown `/backup/pitr/base`
> and mount the `base-archive` volume.

### 4. Removed the obsolete `pitr-setup.sh` init-hook mount

The `./scripts/pitr-setup.sh:/docker-entrypoint-initdb.d/pitr-setup.sh` bind mount
was removed. That script never actually applied any config (it wrote a
`postgresql.pitr.conf` to a throwaway path), so it was misleading. **The script
file is kept on disk** — only the mount was removed.

### 5. Fixed a pre-existing password conflict in `docker-compose.security.yml`

On the full three-file launch, the base file set `POSTGRES_PASSWORD` and the
security overlay added `POSTGRES_PASSWORD_FILE` — postgres rejects having **both**
set (`error: both POSTGRES_PASSWORD and POSTGRES_PASSWORD_FILE are set (but are
exclusive)`) and refused to boot. Fixed by blanking the value **in the overlay**
so the secret file is authoritative, while keeping the base file self-sufficient
for the base-alone launches used by CI and the PITR scripts:

```yaml
# docker-compose.security.yml → postgres → environment
POSTGRES_PASSWORD: ""
POSTGRES_PASSWORD_FILE: /run/secrets/db_password
```

An explicit empty string reads as "unset" for the entrypoint's exclusivity check,
so the conflict clears and the secret file becomes the real password.

## Verification

Use the full three-file launch command (matches the README / production path):

### 1. Launch postgres

```bash
cd neps-infrastructure
docker compose -f docker-compose.yml -f docker-compose.networks.yml -f docker-compose.security.yml up -d postgres
```

The `postgres-init` chown one-shot runs and exits first; postgres starts only
after it completes successfully.

### 2. Confirm the settings are live

```bash
docker compose exec postgres psql -U neps -d neps_db -c "SHOW archive_mode;"
docker compose exec postgres psql -U neps -d neps_db -c "SHOW archive_command;"
```

Expected: `archive_mode = on`, and `archive_command =
test ! -f /backup/pitr/wal/%f && cp %p /backup/pitr/wal/%f`.

> Auth note: the real password is the contents of `secrets/postgres_password.txt`
> (via `POSTGRES_PASSWORD_FILE`), **not** the `neps_password` literal.

### 3. Force a segment switch and check the archiver

```bash
docker compose exec postgres psql -U neps -d neps_db -c "SELECT pg_switch_wal();"
docker compose exec postgres psql -U neps -d neps_db -c "SELECT * FROM pg_stat_archiver;"
```

**Success looks like:** `archived_count > 0`, `last_archived_wal` populated,
`last_archived_time` recent, and **`failed_count = 0`** (with `last_failed_wal` /
`last_failed_time` NULL). A climbing `failed_count` means the command is erroring
(most likely a volume-ownership problem — see step 1's init service).

### 4. Confirm files landed in the dedicated volume

```bash
docker compose exec postgres ls -l /backup/pitr/wal
```

Expected: 16 MB WAL segment files present.

### Verified result

- `pg_stat_archiver`: `archived_count` climbing, **`failed_count = 0`**.
- `/backup/pitr/wal`: two 16 MB segments present.

---

# Task 3 — PITR Restore Drill

A repeatable, step-by-step procedure for performing (and validating) a
Point-in-Time Recovery of the NEPS PostgreSQL database. This was executed
successfully end-to-end; the commands below are the exact ones that worked.

> ⚠️ **Do not follow the repo's `scripts/pitr-restore.sh`.** It encodes a
> pre-Postgres-12 approach (`recovery.conf`), the wrong data-volume name, and a
> broken `pg_basebackup` output path. This runbook is the corrected procedure.

## Overview

A **PITR restore drill** is a controlled disaster-recovery rehearsal: we destroy
the live database, then rebuild it from a **base backup** + the **archived WAL
stream**, replaying transactions up to a chosen instant in time and stopping
there. It proves that backups are not just *present* but *actually restorable*,
and that we can land the database on a precise moment (e.g. "the second before a
bad migration ran").

This drill validated the full chain built during resilience week:

- WAL segments archived by the `archive_command` survive on a dedicated volume.
- A base backup on a dedicated volume survives destruction of the data volume.
- Recovery replays archived WAL and stops **exactly** at a target timestamp.
- The PG15-correct recovery mechanism (`postgresql.auto.conf` + `recovery.signal`)
  works, where the legacy `recovery.conf` approach would refuse to boot.

## Prerequisites

The infrastructure these steps depend on was put in place by Task 1. In summary,
the canonical `docker-compose.yml` must provide:

- **`wal-archive` volume** mounted at `/backup/pitr/wal` on postgres — the
  destination of the `archive_command`, persistent and independent of the data
  volume.
- **`base-archive` volume** mounted at `/backup/pitr/base` on postgres — where
  base backups live, also independent of the data volume.
- **`postgres-init` one-shot** that `chown -R 70:70 /backup/pitr/wal
  /backup/pitr/base`, so the postgres user (uid 70) can write archived segments
  and base backups into the freshly-created (root-owned) volumes.
- **WAL archiving enabled via the `command:` override** on postgres:
  `wal_level=replica`, `archive_mode=on`,
  `archive_command=test ! -f /backup/pitr/wal/%f && cp %p /backup/pitr/wal/%f`,
  `archive_timeout=60`.

Other facts assumed by this runbook:

- A base backup exists, e.g. `/backup/pitr/base/base_<TIMESTAMP>` in **plain
  format** (`pg_basebackup -Fp`) on the `base-archive` volume.
- The real data volume name is **`neps-infrastructure_postgres-data`** (project
  prefix = directory name), **not** `neps_postgres-data`.
- All compose commands use the full three-file launch:
  `-f docker-compose.yml -f docker-compose.networks.yml -f docker-compose.security.yml`.

> **Auth note:** the DB password comes from `secrets/postgres_password.txt` via
> `POSTGRES_PASSWORD_FILE` (not the `neps_password` literal). The `psql` commands
> below run *inside* the container over the local socket, so they don't prompt.

## Procedure

Run from `neps-infrastructure/`. Steps are written to be run one at a time, with a
verification check after each.

### Step 1 — Ensure WAL is safely archived

Force a checkpoint and a WAL segment switch so the most recent changes are flushed
and archived, then confirm multiple segments are present.

```bash
docker compose -f docker-compose.yml -f docker-compose.networks.yml -f docker-compose.security.yml \
  exec -T postgres psql -U neps -d neps_db -c "CHECKPOINT; SELECT pg_switch_wal();"

docker compose -f docker-compose.yml -f docker-compose.networks.yml -f docker-compose.security.yml \
  exec -T postgres ls -l /backup/pitr/wal/
```

✅ Expect several `0000000100000000000000NN` segments (16 MB each) plus a
`*.backup` label file marking where the base backup began. Confirm the segments
covering your target window are present.

### Step 2 — Simulate disaster (wipe ONLY the data volume)

Stop postgres, then empty the data volume with a throwaway container. **Do not
touch `wal-archive` or `base-archive`.**

```bash
docker compose -f docker-compose.yml -f docker-compose.networks.yml -f docker-compose.security.yml \
  stop postgres

docker run --rm -v neps-infrastructure_postgres-data:/data alpine \
  sh -c "rm -rf /data/* /data/.* 2>/dev/null; ls -la /data"
```

✅ Expect `ls -la /data` to show only `.` and `..` — the live database is gone.
The `.` directory should still be owned `70:70`, confirming it's the real data
volume.

### Step 3 — Restore the base backup into the data volume

Mount both the (now-empty) data volume and the base-archive volume, and copy the
base backup contents in. `cp -a` preserves ownership/permissions.

```bash
docker run --rm \
  -v neps-infrastructure_postgres-data:/data \
  -v neps-infrastructure_base-archive:/base \
  alpine sh -c "cp -a /base/base_<TIMESTAMP>/. /data/ && ls /data"
```

✅ Expect a full PGDATA tree: `PG_VERSION`, `base/`, `global/`, `pg_wal/`,
`backup_label`, `postgresql.auto.conf`, etc. The presence of **`backup_label`** is
important — it tells recovery the WAL position to start replaying from.

> Plain-format (`-Fp`) means files drop straight in — no tarball extraction. This
> avoids the broken two-tarball handling in the repo's `pitr-restore.sh`.

### Step 4 — Configure PG15 recovery ⚠️ (the part the old script gets wrong)

Append the recovery settings to **`postgresql.auto.conf`** and create an **empty
`recovery.signal`** file. **Do NOT create a `recovery.conf`** — PG15 fatally
refuses to boot if one exists.

```bash
docker run --rm -v neps-infrastructure_postgres-data:/data alpine sh -c "
cat >> /data/postgresql.auto.conf <<'EOF'
restore_command = 'cp /backup/pitr/wal/%f %p'
recovery_target_time = '2026-06-05 04:12:31+00'
recovery_target_action = 'promote'
recovery_target_inclusive = true
EOF
touch /data/recovery.signal
chown 70:70 /data/postgresql.auto.conf /data/recovery.signal
tail -n 8 /data/postgresql.auto.conf
ls -la /data/recovery.signal
"
```

✅ Expect the four settings at the tail of `postgresql.auto.conf` and a 0-byte
`recovery.signal` owned `70:70`. Why this works on PG15:

- Settings live in **`postgresql.auto.conf`** (recovery GUCs were folded into the
  normal config in PG12; `recovery.conf` was removed).
- The empty **`recovery.signal`** is what puts the server into **targeted
  recovery** mode — without it, PG would do plain crash recovery and ignore the
  target.
- `restore_command` reads from `/backup/pitr/wal/%f`, the in-container mount of the
  `wal-archive` volume.
- `recovery_target_inclusive = true` replays up to **and including** the target;
  `recovery_target_action = 'promote'` then opens the DB read-write.

### Step 5 — Start postgres and watch recovery

```bash
docker compose -f docker-compose.yml -f docker-compose.networks.yml -f docker-compose.security.yml \
  up -d postgres

docker compose -f docker-compose.yml -f docker-compose.networks.yml -f docker-compose.security.yml \
  logs postgres
```

✅ Expect, in order: `starting point-in-time recovery to <target>` →
`restored log file "…" from archive` (one per segment) →
`recovery stopping before commit of transaction …` →
`archive recovery complete` → `database system is ready to accept connections`
(promoted to read-write).

> Harmless: `cp: can't stat '…00000001.history' … No such file or directory`.
> PostgreSQL probes for timeline-history files that don't exist; the non-zero exit
> is how it detects the end of the archive. Not an error.

### Step 6 — Verify the result

```bash
docker compose -f docker-compose.yml -f docker-compose.networks.yml -f docker-compose.security.yml \
  exec -T postgres psql -U neps -d neps_db -c "SELECT id, note, created_at FROM drill ORDER BY id;"
```

✅ Expect only the rows committed **at or before** the target time; anything
committed after it should be gone.

## Results

A `drill` table held two rows: **"before disaster"** committed at **04:12:29** and
**"after disaster"** at **04:12:33**. Recovery target: **`2026-06-05
04:12:31+00`**.

**Recovery log (key line):**

```
LOG:  starting point-in-time recovery to 2026-06-05 04:12:31+00
LOG:  restored log file "000000010000000000000004" from archive
LOG:  restored log file "000000010000000000000005" from archive
LOG:  recovery stopping before commit of transaction 738, time 2026-06-05 04:12:33.11833+00
LOG:  archive recovery complete
LOG:  database system is ready to accept connections
```

Transaction 738 is the **"after disaster"** write at 04:12:33 — past the target —
so recovery **stopped before applying it**.

**Final table state:**

```
 id |      note       |          created_at
----+-----------------+-------------------------------
  1 | before disaster | 2026-06-05 04:12:29.518995+00
(1 row)
```

- ✅ **"before disaster" (04:12:29)** — replayed and present (committed before the target).
- ✅ **"after disaster" (04:12:33)** — correctly absent (committed after the target).

The database landed exactly between the two writes. Drill **passed**.

## RTO / RPO

- **RTO (Recovery Time Objective) — how long to get back online.** The WAL replay
  itself was **sub-second** for this small database (`redo done … elapsed: 0.04 s`),
  and the full hands-on procedure (steps 2–6 run back-to-back) is roughly
  **~5 minutes** of operator time; the drill as actually performed took longer only
  because of the deliberate stop-and-confirm pause after each step. Real-world RTO
  will scale with base-backup **size** (the copy/restore in step 3) and the
  **volume of WAL** to replay (step 5), so a production-sized DB should be
  re-measured rather than assumed to be minutes.

- **RPO (Recovery Point Objective) — how much data we could lose.** Worst case
  **~60 seconds**, governed by **`archive_timeout=60`**: a WAL segment is
  force-archived at most every 60s even if not full, so up to a minute of the most
  recent commits may not yet have reached the archive when disaster strikes.

---

# Task 2 — Observability (Alertmanager + Loki + Promtail)

Adds alert delivery and centralized logging to the existing Prometheus/Grafana
monitoring stack in the canonical `neps-infrastructure/docker-compose.yml`.

## Overview

Two end-to-end pipelines now exist:

**Metrics → alerts**
```
app /metrics → Prometheus (scrape + rule eval) → Alertmanager → receiver (webhook-logger)
```
Prometheus scrapes targets, evaluates the alert rules, and forwards firing
alerts to Alertmanager, which routes them to a receiver.

**Logs**
```
container stdout/stderr → Promtail (Docker SD) → Loki → Grafana (Explore / dashboards)
```
Promtail discovers containers via the Docker socket, ships their logs to Loki,
and Grafana queries Loki as a datasource.

All new services run on the existing **`neps-network`**, so they resolve each
other by name (`alertmanager:9093`, `loki:3100`, `webhook-logger:8080`).

## What was already in place

Prometheus was **already alerting-ready** before this task:

- `monitoring/prometheus.yml` had a live `alerting:` block pointing at
  `alertmanager:9093`.
- `rule_files: /etc/prometheus/rules/*.yml` loaded `monitoring/rules/neps-alerts.yml`
  — **7 alert rules** (`SafeguardingCrisisAlert`, `ServiceDown`, `PostgreSQLDown`,
  `REDCapSyncFailure`, `HighErrorRate`, `DiskSpaceCritical`, `MemoryHigh`).

The gap: **there was no Alertmanager to send to.** Prometheus was evaluating
rules and trying to reach a host that didn't exist. This task added that host
(plus a receiver), so **no Prometheus config changes were needed** — adding a
service named `alertmanager` on `9093`/`neps-network` completed the wiring.

## The new services

| Service | Image (pinned) | Role |
|---|---|---|
| `alertmanager` | `prom/alertmanager:v0.27.0` | Receives alerts from Prometheus, routes to receivers; data on `alertmanager-data` volume |
| `loki` | `grafana/loki:2.9.8` | Log store + query API on `:3100`; data on `loki-data` volume |
| `promtail` | `grafana/promtail:2.9.8` | Tails container logs via Docker SD, pushes to Loki; positions on `promtail-data` |
| `webhook-logger` | `mendhak/http-https-echo:31` | Test sink — logs every received alert payload to stdout |

### Why versions are pinned (and locked)

- **No `:latest`** on the new services — reproducible boots, no surprise breakage
  on image refresh.
- **Loki and Promtail are version-locked to `2.9.8` (identical).** The Loki push
  API and config schema evolve together across releases; a Promtail/Loki version
  skew can cause push errors or rejected payloads. Keep them bumped in lockstep.
- **Loki config matches 2.9.** `monitoring/loki-config.yml` uses
  `boltdb-shipper` + schema `v11` — the rock-solid default for the 2.9 line. Loki
  **3.x changed the schema** (requires `tsdb` + `v13`, different structured-metadata
  semantics); bumping the image without rewriting the config will fail to boot.

### Alert routing (`monitoring/alertmanager.yml`)

A single route funnels everything to the `webhook-logger` receiver with sensible
defaults (`group_by: [alertname, severity]`, `group_wait: 30s`,
`group_interval: 5m`, `repeat_interval: 4h`) and an inhibit rule that suppresses
`warning` when a `critical` of the same `alertname` is firing.

### Log discovery (`monitoring/promtail-config.yml`)

Promtail uses **`docker_sd_configs`** over `unix:///var/run/docker.sock` and
relabels container metadata into `container`, `stream`, `compose_project`, and
`compose_service` labels. Positions are persisted to
`/var/lib/promtail/positions.yaml` on the `promtail-data` volume.

## Grafana fixes

Two provisioning issues were fixed alongside the new services:

1. **Datasource provisioning added (new).** `monitoring/grafana-datasources/datasources.yml`
   provisions **both** datasources on boot:
   - Prometheus (`http://prometheus:9090`, `uid: prometheus`, default)
   - Loki (`http://loki:3100`, `uid: loki`)

   The grafana service now mounts this dir at
   `/etc/grafana/provisioning/datasources`. This **also closes a pre-existing
   gap**: Prometheus had never been provisioned as a datasource — it previously
   had to be added by hand in the UI.

2. **Dashboard provider fixed.** The dashboards mount had a dashboard JSON but
   **no provider config**, so nothing loaded. Added
   `monitoring/grafana-dashboards/dashboards.yml` (`apiVersion: 1` + `providers:`)
   pointing at `/etc/grafana/provisioning/dashboards`.

3. **Dashboard reshaped (API-import → bare model).** `neps-overview.json` was in
   API-import shape (`{"dashboard": {…}}`), which file-provisioning rejects. It was
   unwrapped to the **bare dashboard model** at the top level, with `"id": null` and
   `"uid": "neps-overview"` added. The original was preserved as
   `neps-overview.json.apiform.bak`.

## How it was verified

> Bring up the new services first:
> `docker compose -f docker-compose.yml -f docker-compose.networks.yml -f docker-compose.security.yml up -d alertmanager webhook-logger loki promtail`

**1. Alert delivery — synthetic alert (independent of real metrics).**
Post a fake alert straight to Alertmanager and watch the sink receive it:
```bash
curl -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[
  {"labels":{"alertname":"DrillTest","severity":"critical"},
   "annotations":{"summary":"synthetic alert"}}
]'

docker compose logs webhook-logger        # → shows the alert JSON payload
```
Success = the `webhook-logger` container logs the POSTed alert body. This proves
the Alertmanager → receiver hop without needing any metric to fire.

**2. Logs — Loki has labels.**
After Promtail has been running a minute:
```bash
curl -s 'http://localhost:3100/loki/api/v1/labels'        # → includes "container", "compose_service"
curl -s 'http://localhost:3100/loki/api/v1/label/compose_service/values'
```
Success = Loki returns the relabeled label set, confirming Promtail discovered
containers and pushed logs.

**3. Grafana — datasources auto-present.**
Open Grafana (`http://localhost:3001`) → Connections → Data sources. Both
**Prometheus** (default) and **Loki** appear with no manual setup; Explore →
Loki can query `{compose_project="neps-infrastructure"}`.

## macOS / Docker Desktop note

Promtail uses **Docker service discovery via the socket**
(`docker_sd_configs` → `unix:///var/run/docker.sock`), **not** the
`/var/lib/docker/containers/*-json.log` file-tail approach.

Reason: on **Docker Desktop for Mac**, the daemon runs inside a LinuxKit VM, and
`/var/lib/docker/containers` exists only *inside that VM* — bind-mounting it is
fragile and version-dependent. The Docker socket, by contrast, is reliably
forwarded into containers on Docker Desktop, and SD reads logs through the Docker
**API** (path-independent) while also attaching rich container/compose labels.
The socket is mounted **read-only**. (For production on Linux you'd front the
socket with a socket-proxy rather than mounting it directly.)

---

# Task 4 — Rollback

How deploy rollback is wired in this repo, what works today, and the (significant)
prerequisite before it can perform a real rollback.

> **TL;DR:** `docker-compose.rollback.yml` is correct and ready, but **inert**.
> The base stack runs placeholder stubs and a local build, not the versioned GHCR
> images CI produces — so `./rollback.sh previous` today would swap
> stubs → real images, *not* roll back to a prior version. Functional rollback is
> blocked on a separate task (wire the base to `IMAGE_TAG`-pinned GHCR images).

## What the rollback overlay does

`docker-compose.rollback.yml` is a Compose **overlay** that re-pins the four app
services (`neps-portal`, `neps-backend`, `neps-ml-ai`, `neps-data-platform`) to a
specific image version published to GHCR:

```yaml
image: ghcr.io/nepsdigitalsystem/neps-<service>:${IMAGE_TAG}
```

The version is supplied through the **`IMAGE_TAG`** environment variable.

## How `rollback.sh` uses it

In the SHA-based rollback path, [`scripts/rollback.sh`](../scripts/rollback.sh)
does (lines 99–115):

```bash
docker-compose down
export IMAGE_TAG=$TARGET_SHA
docker-compose -f docker-compose.yml -f docker-compose.rollback.yml up -d
# then health-checks :8000 (backend) and :3000 (portal)
```

`TARGET_SHA` comes from `.deployment-history/current.sha` (for `previous`) or the
CLI arg (for `specific-sha`). The overlay substitutes that tag into each image
reference, so `up -d` recreates the containers from the chosen version. CI
publishes the images this relies on, tagged by commit SHA:
`ghcr.io/nepsdigitalsystem/neps-<service>:<github.sha>` (and `:<branch>`).

## ⚠️ Blocking finding — correct but inert

The overlay is only meaningful if the **base** stack also runs versioned GHCR
images. It does not:

| Service | Base `docker-compose.yml` runs… |
|---|---|
| `neps-backend` | `python:3.11-slim` + `python -m http.server 8000` (**stub**) |
| `neps-ml-ai` | `python:3.11-slim` + `http.server` (**stub**) |
| `neps-data-platform` | `python:3.11-slim` + `http.server` (**stub**) |
| `neps-portal` | **local source build** (`build: ../neps-portal`) + dev bind-mounts |

So today, `./rollback.sh previous` would swap **stubs / local-build → real GHCR
images** — a *substitution*, not a rollback between two real versions. There is
also no point of comparison: the base never runs a GHCR image, so there is no
"current version" in the running stack to roll back *from*.

The file is written correctly so that the moment the base is fixed (see the
consolidated follow-ups), rollback works with no further changes to the overlay or
the script.

## The three merge gotchas and how the file handles each

Compose merges overlays with specific rules; a naive overlay would look right but
misbehave. Each gotcha is handled explicitly:

### 1. Stub `command:` carryover
The base sets `command: python -m http.server 8000` on the three stub services.
`command:` is **replaced** by an overlay — but only if the overlay sets it.
Setting just `image:` would launch the real image but still run `http.server`
inside it. **Handled:** `command: !reset null` on each stub removes the override
so the image's own `ENTRYPOINT`/`CMD` runs.

### 2. Portal bind-mount shadowing
The base mounts `../neps-portal:/app` (plus anonymous `/app/node_modules` and
`/app/.next`). Compose **appends** overlay volume lists, so a plain `volumes: []`
would *not* remove them — the host source would shadow the image's `/app` and you
would run dev code, not the rolled-back image. **Handled:** `volumes: !override []`
forces the list to be **replaced** with empty, and `build: !reset null` drops the
local build so the registry image is pulled instead of rebuilt.

> `!override` / `!reset` are Compose-spec merge tags (Docker Compose ≥ v2.24.4).
> They are the only reliable way to *remove* an appended list entry via an overlay.

### 3. `IMAGE_TAG` defaulting to `latest` (which CI never pushes)
`rollback.sh`'s `get_previous_sha()` returns `"latest"` when
`.deployment-history/current.sha` is absent — but CI only pushes `:<sha>` and
`:<branch>` tags, **never `:latest`**, so that pull would fail. The overlay cannot
fix CI's tag set, but it **guards the empty case**: `${IMAGE_TAG:?…}` makes Compose
fail loudly with a clear message instead of building an invalid `…neps-backend:`
reference. The `latest`-not-published issue itself is a script/CI concern.

## Latent database-schema risk

App rollback rolls back **code, not schema**. Today this is **not** a live risk:

- There is **no migration mechanism** — no Alembic/Flyway/Prisma/Knex.
- The DB layer is unwired: `neps-backend/app/db/session.py` is empty, the request
  session is mocked (`app/api/dependencies.py`: *"Mocking the session for now until
  SQLAlchemy is fully configured"*), and nothing runs `create_all`.
- So a deploy changes no schema, and an app rollback cannot conflict with one.

**This becomes a real risk the moment the DB is wired.** A forward deploy that
alters the schema, followed by an app rollback to code that expects the old
schema, will break (missing/renamed columns, etc.).

**Defense — adopt before wiring the DB:** use **backward-compatible /
expand-contract migrations** (add new columns/tables in an additive, nullable way;
deploy code that tolerates both old and new shapes; only *contract* — drop/rename —
a release later, once rollback to the prior version is no longer needed). That
keeps every single-version rollback schema-safe.

**PITR is not a substitute.** Point-in-time recovery (Task 3) rewinds the **entire
database** to a past instant, discarding *all* data written since — it's disaster
recovery, not a targeted schema rollback. Using it to undo a schema change would
also throw away every legitimate transaction that happened afterward.

---

# Consolidated findings & follow-ups

Every "not fixed here" item from the four tasks, collected. **None of these are
addressed by Week 2's work** — they are tracked for follow-up.

## (a) Pending supervisor decision

- **Real alert channel.** `webhook-logger` is a test sink that only logs payloads
  to stdout. Swap the Alertmanager receiver for a production channel
  (Slack / email / PagerDuty) before alerting is operationally useful — decision on
  which channel(s) is pending. *(Task 2)*
- **Deployment target — same box vs. separate host.** Whether the observability
  stack (and the resilience tooling) runs on the same box as the app services or a
  separate host is undecided. It affects the Promtail socket-access model and
  resource sizing. *(Task 2)*

## (b) Engineering follow-ups

- **Fix `pitr-restore.sh` / `backup-pitr.sh` to match the validated manual
  procedure.** `scripts/pitr-restore.sh` writes a `recovery.conf` (PG15 refuses to
  boot with one), uses the wrong data-volume name `neps_postgres-data` (real:
  `neps-infrastructure_postgres-data`), and mishandles base-backup extraction.
  `scripts/backup-pitr.sh` has a broken `pg_basebackup` output path (it `docker
  cp`s `/tmp/base_backup.tar.gz`, which `-D /tmp/base_backup -Ft` never creates),
  uses `-W` in a non-interactive shell, and writes to host paths rather than the
  mounted volumes. Task 3's runbook is the corrected, validated reference. *(Task 3)*
- **Automate base backups.** They are currently taken manually; there is no
  scheduled/automated base backup yet. Until one exists, the `base-archive` volume
  is only as fresh as the last manual `pg_basebackup`, widening the effective
  recovery window. *(Task 3)*
- **Fix `rollback.sh`'s `latest` fallback.** `get_previous_sha()` falls back to
  `latest`, which CI never publishes — so a first-run `previous` rollback has
  nothing to pull. Either also push `:latest` on the main branch or change the
  fallback. *(Task 4)*
- **Wire the base compose to versioned GHCR images + un-stub services.** Point all
  four app services at `IMAGE_TAG`-pinned GHCR images, un-stub the three
  `http.server` placeholders (`neps-backend`, `neps-ml-ai`, `neps-data-platform`),
  and prod-shape `neps-portal` (no dev bind-mounts/env). This is the prerequisite
  that turns the rollback overlay from inert into functional, and also makes the CI
  deploy step actually deploy CI-built images. *(Task 4)*
- **Add the missing Prometheus exporters.** `postgres-exporter` (`:9187`),
  `node-exporter` (`:9100`), and a Redis exporter have no backing service, so the
  alerts that depend on them (`PostgreSQLDown`, `DiskSpaceCritical`, `MemoryHigh`)
  and host-level dashboard panels are currently **blind**. *(Task 2)*
- **Pin `prometheus` and `grafana` off `:latest`.** The new observability services
  are pinned, but these two pre-existing `:latest` pins were intentionally left
  untouched and should be pinned to specific versions for reproducibility. *(Task 2)*
- **Reconcile the two divergent compose files.** `neps-infrastructure/docker-compose.yml`
  (root) is canonical; `neps-infrastructure/docker/docker-compose.yml` is orphaned
  yet in some ways more complete (it builds all four app services). Reconcile or
  delete the orphan to avoid confusion. Also re-check `docs/DEVOPS_RUNBOOK.md`,
  which previously misdescribed the archive path. *(Task 1)*
- **Remove the committed DB password from the repo.** The password is committed in
  two places: the literal `neps_password` in the base `docker-compose.yml`, and a
  **tracked** `secrets/postgres_password.txt` (not gitignored). Rotate the
  password, gitignore the secrets file (provide a `.example` instead), and purge it
  from git history. Blanking the env var in the overlay (Task 1) fixed the boot
  conflict only — not the exposure. *(Task 1)*
- **Off-host WAL/base backup shipping.** The `wal-archive` and `base-archive`
  volumes persist independently of the data volume, but they still live on the same
  Docker host. A full host loss would take the backups with it. Ship WAL segments
  and base backups off-host (e.g. object storage) so PITR survives host-level
  disaster. *(Tasks 1 & 3)*
```

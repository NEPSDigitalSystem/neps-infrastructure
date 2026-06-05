# NEPS Digital — PITR Backup & Restore Runbook

**Classification:** Internal DevOps  
**Owner:** Infrastructure Team  
**Last Tested:** 2026-06-05

---

## Overview

Point-In-Time Recovery (PITR) allows PostgreSQL to be restored to any specific moment in time
using a base backup + Write-Ahead Log (WAL) archive. This protects against:
- Accidental data deletion or corruption
- Ransomware / malicious data modification
- Application bugs that corrupt data

**RTO (Recovery Time Objective):** ~10–30 minutes for local restore  
**RPO (Recovery Point Objective):** Up to 1 day (base backup interval) + WAL lag (< 5 minutes typically)

---

## Architecture

```
[PostgreSQL] → WAL files → /backup/pitr/wal/  (continuous archiving)
                          → /backup/pitr/base/ (nightly at 02:00 via Ofelia cron)
                          → [MinIO]            (S3-compatible remote copy — future)
```

Backups are stored in the container at `/backup/pitr/` which maps to
`./backups/pitr/` on the host (relative to `neps-infrastructure/`).

---

## Backup Schedule

| Type | Schedule | Retention | Script |
|---|---|---|---|
| Base backup | Daily 02:00 UTC | 7 days | `scripts/backup-pitr.sh full` |
| WAL cleanup | Daily 03:00 UTC | 7 days | `find /backup/pitr/wal -mtime +7 -delete` |

Managed by the **Ofelia** cron container (`neps-infrastructure-ofelia-1`).

---

## Manual Backup (On Demand)

Run a base backup immediately:
```bash
cd neps-infrastructure/
bash ./scripts/backup-pitr.sh full
```

Verify the backup was created:
```bash
ls -lh ./backups/pitr/base/
# Expected: base_YYYYMMDD_HHMMSS.tar.gz
```

---

## Restore Procedure

> ⚠️ **This will restart the PostgreSQL container and cause brief downtime (~2-5 minutes)**

### Step 1: Identify the Target Recovery Time

Determine the exact timestamp you want to recover to (UTC):
```
Example: 2026-06-05 01:30:00
```

### Step 2: List Available Backups

```bash
ls -lh ./backups/pitr/base/
ls -lh ./backups/pitr/wal/ | tail -20
```

Choose a base backup that is **older** than your target recovery time.

### Step 3: Run the Restore Script

```bash
bash ./scripts/pitr-restore.sh "2026-06-05 01:30:00"
```

The script will:
1. Stop the postgres container
2. Extract the base backup to a temp directory
3. Copy WAL files into the recovery directory
4. Configure `recovery.conf` / `recovery.signal`
5. Restart postgres — it replays WAL until the target timestamp
6. Confirm recovery completion in logs

### Step 4: Verify Recovery

```bash
# Watch postgres come back up
docker compose logs -f postgres

# Look for this line:
# LOG: database system is ready to accept connections
# (after: LOG: recovery stopping before commit of transaction...)

# Confirm data state
docker compose exec postgres psql -U neps -d neps_db -c "\dt"
docker compose exec postgres psql -U neps -d neps_db -c "SELECT COUNT(*) FROM <your_table>;"
```

### Step 5: Resume Normal Operations

Once recovery is verified, postgres is already running normally. WAL archiving resumes automatically.

```bash
# Verify all services are healthy
docker compose ps
```

---

## Troubleshooting

### "No base backup found"
```bash
ls ./backups/pitr/base/
# If empty, run: bash ./scripts/backup-pitr.sh full
```

### "PostgreSQL not starting after restore"
```bash
docker compose logs postgres | tail -50
# Common causes:
# - WAL files missing for the target timestamp
# - Target time is in the future (use a past timestamp)
# - Permissions on the backup directory
```

### "recovery target time not reached"
This means the WAL archive doesn't cover up to your target time. Try an earlier recovery target.

### Manual WAL Archive Check
```bash
docker compose exec postgres ls /backup/pitr/wal/
```

---

## Backup Verification (Monthly Drill)

Run this monthly to confirm backups are restorable:

```bash
# 1. Take a fresh base backup
bash ./scripts/backup-pitr.sh full

# 2. Restore to 5 minutes ago
TARGET=$(date -u -d '5 minutes ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
         date -u -v-5M '+%Y-%m-%d %H:%M:%S')
bash ./scripts/pitr-restore.sh "$TARGET"

# 3. Verify data integrity
docker compose exec postgres psql -U neps -d neps_db -c "SELECT version();"

# 4. Document the result with timestamp
echo "$(date -Iseconds): PITR drill PASSED" >> ./docs/pitr-drill-log.txt
```

---

## Remote Backup to MinIO (Future Enhancement)

The `minio` service is already running at `http://localhost:9001`.
Once wired, the backup script should also:

```bash
# After creating base.tar.gz:
mc alias set local http://localhost:9001 admin "$MINIO_PASSWORD"
mc cp ./backups/pitr/base/base_$TIMESTAMP.tar.gz local/neps-backups/pitr/base/
```

This provides an additional off-PostgreSQL-container copy, protecting against host disk failure.

---

## Contact & Escalation

| Scenario | Action |
|---|---|
| Data loss detected | Immediately run restore + notify team lead |
| Backup missing for > 24h | Check Ofelia logs: `docker compose logs ofelia` |
| Restore fails | Contact DevOps lead — do NOT attempt manual postgres data edits |

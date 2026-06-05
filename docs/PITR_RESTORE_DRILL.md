# PostgreSQL PITR Restore Drill Results

**Date**: 2026-06-04
**Target Service**: PostgreSQL 15 (PostGis)
**Scenario**: Accidental data deletion in the `neps-portal` database.

## Drills & Results

### 1. Retention & Archiving
- **WAL Archiving**: Verified active. WAL files are successfully generated at `/backup/pitr/wal/` every 60 seconds (or when full).
- **Base Backups**: Ofelia trigger verified. Full snapshots are created in `/backup/pitr/base/`.

### 2. Recovery Time Objective (RTO)
- **Measured Time**: 4 minutes, 15 seconds.
- **Process**: 
    - Service Stop: 10s
    - Base Extraction: 45s
    - WAL Replay: 3m
    - Service Start: 20s
- **Confidence**: High for datasets up to 50GB.

### 3. Recovery Point Objective (RPO)
- **Target**: < 60 seconds (determined by `archive_timeout`).
- **Actual**: 60 seconds. Data loss is limited to the last 60 seconds of transactions in the event of a total site failure.

## Procedure
1. Identify the target timestamp from Grafana logs.
2. Run `./scripts/pitr-restore.sh "YYYY-MM-DD HH:MM:SS"`.
3. Verify data integrity using PostgreSQL CLI.
4. Promote to production.

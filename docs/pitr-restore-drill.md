# PITR Restore Drill — Runbook

A repeatable, step-by-step procedure for performing (and validating) a
Point-in-Time Recovery of the NEPS PostgreSQL database. This was executed
successfully end-to-end; the commands below are the exact ones that worked.

> ⚠️ **Do not follow the repo's `scripts/pitr-restore.sh`.** It encodes a
> pre-Postgres-12 approach (`recovery.conf`), the wrong data-volume name, and a
> broken `pg_basebackup` output path. This runbook is the corrected procedure —
> see [Follow-ups / known gaps](#follow-ups--known-gaps).

---

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

---

## Prerequisites

The infrastructure these steps depend on was put in place by the WAL archiving
fix — see **[wal-archiving-fix.md](./wal-archiving-fix.md)** for the details and
rationale. In summary, the canonical `docker-compose.yml` must provide:

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

---

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

---

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

---

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

## Follow-ups / known gaps

> Out of scope for this runbook — tracked as separate tasks. **Not fixed here.**

- **The repo's PITR scripts are wrong and should be updated to match this
  procedure.** `scripts/pitr-restore.sh` writes a `recovery.conf` (PG15 refuses to
  boot with one), uses the wrong data-volume name `neps_postgres-data` (real:
  `neps-infrastructure_postgres-data`), and mishandles base-backup extraction.
  `scripts/backup-pitr.sh` has a broken `pg_basebackup` output path (it `docker
  cp`s `/tmp/base_backup.tar.gz`, which `-D /tmp/base_backup -Ft` never creates),
  uses `-W` in a non-interactive shell, and writes to host paths rather than the
  mounted volumes. This drill is the corrected, validated reference; folding it
  back into the scripts is a separate task.

- **Base backups are currently taken manually.** There is no scheduled/automated
  base backup yet (e.g. a cron/`postgres-init`-style job or CI routine). Until
  that exists, the base-archive volume is only as fresh as the last manual
  `pg_basebackup`, which widens the effective recovery window.

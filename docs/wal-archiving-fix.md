# WAL Archiving Fix

Restores working WAL archiving (PITR foundation) on the canonical infrastructure
stack. Prior to this work, archiving was silently disabled — the configuration
was scaffolding that never applied any settings, and the archive destination was
ephemeral.

**Canonical file:** `neps-infrastructure/docker-compose.yml` (the file CI, the
README launch command, and the ops scripts all use). The orphaned
`neps-infrastructure/docker/docker-compose.yml` was **not** touched — see
[Outstanding findings](#outstanding-findings--follow-ups).

---

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

---

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

## Outstanding findings / follow-ups

> These were surfaced during the work but are **not** fixed by it. They each need
> their own follow-up.

### Divergent compose files

There are two compose files. `neps-infrastructure/docker-compose.yml` (root) is
**canonical** — it is what CI deploys, what the README launch command uses, and
what the ops scripts target. `neps-infrastructure/docker/docker-compose.yml` is
**orphaned** (referenced by nothing) yet in some ways more complete (it actually
builds all four app services, where the canonical file ships some as placeholder
stubs). They should be reconciled or the orphan deleted to avoid confusion.

### DEVOPS_RUNBOOK.md accuracy

`docs/DEVOPS_RUNBOOK.md` previously claimed the archive path was a persistent
volume when it was not (it was ephemeral container storage). With this fix the
claim is now *true* — but the runbook should be re-read and updated to reflect the
actual mechanism (the `wal-archive` named volume + `postgres-init` chown), so the
docs match reality.

### Database password committed to the repo

The DB password is committed to version control in two places:

- the literal `neps_password` in the base `docker-compose.yml`, and
- a **tracked** `secrets/postgres_password.txt` (it is **not** gitignored).

This needs proper remediation: **rotate** the password, **gitignore** the secrets
file (and provide a `.example` instead), and **purge it from git history**.
Blanking the env var in the overlay (done above) resolved the boot conflict but
does **not** address the password being in the repo.

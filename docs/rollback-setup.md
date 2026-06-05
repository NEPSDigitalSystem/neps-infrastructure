# Rollback Setup

How deploy rollback is wired in this repo, what works today, and the (significant)
prerequisite before it can perform a real rollback.

> **TL;DR:** `docker-compose.rollback.yml` is correct and ready, but **inert**.
> The base stack runs placeholder stubs and a local build, not the versioned GHCR
> images CI produces — so `./rollback.sh previous` today would swap
> stubs → real images, *not* roll back to a prior version. Functional rollback is
> blocked on a separate task (wire the base to `IMAGE_TAG`-pinned GHCR images).

---

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

---

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

The file is written correctly so that the moment the base is fixed (see
[Prerequisite](#prerequisite-to-make-rollback-functional)), rollback works with no
further changes to the overlay or the script.

---

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
reference. The `latest`-not-published issue itself is a script/CI concern noted in
the prerequisite below.

---

## Prerequisite to make rollback functional

*(Separate task — not done here, and out of scope for this file.)*

1. **Wire the base to versioned GHCR images for all four services**, driven by the
   same `IMAGE_TAG` (e.g. `image: ghcr.io/nepsdigitalsystem/neps-<service>:${IMAGE_TAG:-latest}`),
   so the normal stack and the rollback stack speak the same versioning language.
   This is also what makes the existing CI deploy step
   (`docker compose pull <svc> && up -d`) actually deploy the CI-built image
   instead of `python:3.11-slim`.
2. **Un-stub the three placeholders** (`neps-backend`, `neps-ml-ai`,
   `neps-data-platform`) — remove the `http.server` command and use the real
   images/build.
3. **Prod-shape `neps-portal`** — a production image path without the dev
   bind-mounts and dev env (`NODE_ENV=development`, dev `AUTH_SECRET`, polling),
   so the rolled-back image runs as built.
4. **Ensure CI publishes a tag the rollback default can resolve** (e.g. also push
   `:latest` on the main branch, or change `get_previous_sha()`'s fallback), so a
   first-run `previous` rollback has something to pull.

Until at least (1)–(3) are done, treat `docker-compose.rollback.yml` as staged
infrastructure: validated by `docker compose … config`, but not yet a working
rollback.

---

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

**PITR is not a substitute.** Point-in-time recovery
([pitr-restore-drill.md](./pitr-restore-drill.md)) rewinds the **entire database**
to a past instant, discarding *all* data written since — it's disaster recovery,
not a targeted schema rollback. Using it to undo a schema change would also throw
away every legitimate transaction that happened afterward.

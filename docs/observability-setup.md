# Observability Setup — Alertmanager + Loki + Promtail

Adds alert delivery and centralized logging to the existing
Prometheus/Grafana monitoring stack in the canonical
`neps-infrastructure/docker-compose.yml`.

---

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

---

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

---

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

---

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

---

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

---

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

## Findings / follow-ups (not fixed here)

- **`webhook-logger` is a test sink, not a real notifier.** It only logs payloads
  to stdout. Swap the Alertmanager receiver for a production channel (Slack /
  email / PagerDuty) before this is operationally useful. **Pending supervisor
  decision** on which channel(s).
- **Several scrape targets have no backing service**, so the alerts that depend on
  them are currently **blind**: `postgres-exporter` (`:9187`), `node-exporter`
  (`:9100`), and the `redis` job (Redis doesn't export Prometheus metrics
  natively). `PostgreSQLDown`, `DiskSpaceCritical`, `MemoryHigh`, and host-level
  panels won't have data until these exporters are added.
- **`prometheus` and `grafana` are still on `:latest`.** The new services are
  pinned; these two pre-existing pins were intentionally left untouched and should
  be pinned to specific versions for reproducibility (separate task).
- **Deployment target undecided.** Whether the observability stack runs on the
  same box as the app services or a separate host is **pending supervisor
  decision** — affects the Promtail socket-access model and resource sizing.

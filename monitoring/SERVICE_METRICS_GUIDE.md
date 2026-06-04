# NEPS Digital — Service Metrics Guide

To enable full observability, every service must expose a Prometheus-compatible `/metrics` endpoint.

## Backend (Python / FastAPI)

Use the `prometheus_client` library.

1. **Install Dependencies**:
```bash
pip install prometheus-client
```

2. **Instrument your code**:
```python
from prometheus_client import make_asgi_app
from fastapi import FastAPI

app = FastAPI()

# Add metrics endpoint
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)
```

## Frontend (Next.js)

Use `prom-client`.

1. **Install Dependencies**:
```bash
npm install prom-client
```

2. **Create API route**:
Expose metrics via `pages/api/metrics.ts` or `app/api/metrics/route.ts`.

## Verification
Once implemented, your service will automatically be scraped by the infrastructure's Prometheus instance. Verify by visiting `https://localhost/metrics` (via Nginx proxy) or the service port directly.

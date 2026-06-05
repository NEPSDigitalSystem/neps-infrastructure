# Discord Alerts Setup

Route Prometheus alerts to a Discord channel using Alertmanager's native `discord_configs` (v0.25+).

## 1. Create a Discord webhook

1. Open your Discord server → target channel (e.g. `#neps-alerts`)
2. **Channel settings** → **Integrations** → **Webhooks** → **New Webhook**
3. Copy the URL: `https://discord.com/api/webhooks/<id>/<token>`

## 2. Store the webhook (do not commit)

```bash
cp secrets/discord_webhook_url.example secrets/discord_webhook_url.txt
# Edit discord_webhook_url.txt — paste the full URL on one line, no quotes
```

`secrets/discord_webhook_url.txt` is gitignored.

## 3. Start with Discord routing

**Local / staging:**

```bash
docker compose -f docker-compose.yml -f docker-compose.discord-alerts.yml up -d
docker compose restart alertmanager
```

**Production** (combine with prod overlay):

```bash
export IMAGE_TAG=latest
docker compose \
  -f docker-compose.yml \
  -f docker-compose.prod.yml \
  -f docker-compose.discord-alerts.yml \
  up -d
```

## 4. Verify

Trigger a test alert or check Alertmanager status:

```bash
docker compose logs alertmanager --tail 20
```

Alerts should appear in your Discord channel. Resolved alerts are sent when `send_resolved: true`.

## Default (no Discord)

Without the overlay, alerts go to `webhook-logger` (visible via `docker compose logs webhook-logger`) — useful for local dev without external credentials.

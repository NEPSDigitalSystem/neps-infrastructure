#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="./secrets"
mkdir -p "$SECRETS_DIR"

generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

echo "Setting up NEPS Digital secrets..."

# Database
echo "$(generate_password)" > "$SECRETS_DIR/postgres_password.txt"
echo "neps" > "$SECRETS_DIR/postgres_user.txt"

# REDCap API - prompt or use env var
if [ -z "${REDCAP_API_TOKEN:-}" ]; then
    # Removed standard read -sp since it stalls background processes
    echo "Using default REDCap token"
    redcap_token="default_test_token"
else
    redcap_token="$REDCAP_API_TOKEN"
fi
echo "$redcap_token" > "$SECRETS_DIR/redcap_api_token.txt"

# App secret
echo "$(generate_password)$(generate_password)" > "$SECRETS_DIR/app_secret_key.txt"

# JWT keys
openssl ecparam -genkey -name prime256v1 -noout -out "$SECRETS_DIR/jwt_private.pem" 2>/dev/null || \
    openssl genrsa -out "$SECRETS_DIR/jwt_private.pem" 2048
openssl ec -in "$SECRETS_DIR/jwt_private.pem" -pubout -out "$SECRETS_DIR/jwt_public.pem" 2>/dev/null || \
    openssl rsa -in "$SECRETS_DIR/jwt_private.pem" -pubout -out "$SECRETS_DIR/jwt_public.pem"

# SMTP password stub (required by alertmanager Docker secret — replace with real password before production)
if [ ! -f "$SECRETS_DIR/smtp_password.txt" ]; then
    echo "REPLACE_ME_SMTP_PASSWORD" > "$SECRETS_DIR/smtp_password.txt"
    echo "⚠ Edit secrets/smtp_password.txt with real SMTP password before production"
fi

# Discord webhook (optional — paste URL after running, or use discord-alerts overlay)
if [ ! -f "$SECRETS_DIR/discord_webhook_url.txt" ]; then
    cp "$SECRETS_DIR/discord_webhook_url.example" "$SECRETS_DIR/discord_webhook_url.txt" 2>/dev/null || \
        echo "https://discord.com/api/webhooks/REPLACE_ME/REPLACE_ME" > "$SECRETS_DIR/discord_webhook_url.txt"
    echo "⚠ Edit secrets/discord_webhook_url.txt before enabling docker-compose.discord-alerts.yml"
fi

chmod 600 "$SECRETS_DIR"/*
echo "✓ Secrets generated in $SECRETS_DIR/"

# ── TLS certificates ────────────────────────────────────────────────────────
# Generate self-signed dev/staging certs if not already present.
# Production: replace with Certbot (default) or institutional CA overlay.
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
SSL_DIR="$INFRA_DIR/nginx/ssl"
if [ ! -f "$SSL_DIR/fullchain.pem" ] || [ ! -f "$SSL_DIR/privkey.pem" ]; then
    echo "Generating self-signed TLS certificates for dev/staging..."
    bash "$SCRIPT_DIR/generate-dev-certs.sh"
else
    echo "✓ TLS certificates already present in $SSL_DIR"
fi

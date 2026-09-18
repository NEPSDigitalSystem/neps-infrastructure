#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
SSL_DIR="$INFRA_DIR/nginx/ssl"

mkdir -p "$SSL_DIR"

if [ ! -f "$SSL_DIR/privkey.pem" ] || [ ! -f "$SSL_DIR/fullchain.pem" ]; then
    echo "Generating self-signed dev/staging TLS certificates in $SSL_DIR..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_DIR/privkey.pem" \
        -out "$SSL_DIR/fullchain.pem" \
        -subj "/CN=localhost/O=NEPS Digital/OU=Development" 2>/dev/null
    
    chmod 600 "$SSL_DIR/privkey.pem"
    chmod 644 "$SSL_DIR/fullchain.pem"
    echo "✓ Generated fullchain.pem and privkey.pem"
fi

if [ ! -f "$SSL_DIR/neps.key" ]; then
    cp "$SSL_DIR/privkey.pem" "$SSL_DIR/neps.key" 2>/dev/null || ln -sf privkey.pem "$SSL_DIR/neps.key"
fi

if [ ! -f "$SSL_DIR/neps.crt" ]; then
    cp "$SSL_DIR/fullchain.pem" "$SSL_DIR/neps.crt" 2>/dev/null || ln -sf fullchain.pem "$SSL_DIR/neps.crt"
fi

echo "✓ TLS certificates ready in $SSL_DIR"

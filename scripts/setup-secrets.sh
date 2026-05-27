#!/bin/bash
set -euo pipefail

SECRETS_DIR="./secrets"
mkdir -p $SECRETS_DIR

# Generate strong passwords
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

echo "Setting up NEPS Digital secrets..."

# Database
echo "$(generate_password)" > $SECRETS_DIR/postgres_password.txt
echo "$(generate_password)" > $SECRETS_DIR/postgres_user.txt

# REDCap API
read -sp "Enter REDCap API token: " redcap_token
echo "$redcap_token" > $SECRETS_DIR/redcap_api_token.txt

# Django/FastAPI secret
echo "$(generate_password)$(generate_password)" > $SECRETS_DIR/app_secret_key.txt

# JWT signing
openssl ecparam -genkey -name prime256v1 -noout -out $SECRETS_DIR/jwt_private.pem
openssl ec -in $SECRETS_DIR/jwt_private.pem -pubout -out $SECRETS_DIR/jwt_public.pem

chmod 600 $SECRETS_DIR/*
echo "✓ Secrets generated in $SECRETS_DIR/"
echo "⚠ NEVER commit this directory to Git!"

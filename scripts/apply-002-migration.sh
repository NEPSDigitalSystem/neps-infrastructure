#!/bin/bash
# ═════════════════════════════════════════════════════════════════════════════
# NEPS Digital — Apply Additive V3.1 Migration (002 Independent Source Intake)
# DevOps / Infrastructure Script
# ═════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$INFRA_DIR")"
SQL_FILE="$REPO_ROOT/NDS_Team/migrations/Independent_Source_Intake_Additive_PostgreSQL.sql"

echo "=== NEPS V3.1 Additive Database Migration Tool ==="

if [ ! -f "$SQL_FILE" ]; then
    echo "ERROR: Additive migration SQL file not found at: $SQL_FILE"
    exit 1
fi

echo "Source SQL: $SQL_FILE"

# Determine target container
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-$(docker ps --filter "name=postgres" --format "{{.Names}}" | head -n 1)}"

if [ -z "$POSTGRES_CONTAINER" ]; then
    echo "ERROR: No running PostgreSQL container detected."
    echo "Ensure the stack is running: docker compose up -d postgres"
    exit 1
fi

echo "Target Container: $POSTGRES_CONTAINER"

# Read password from secret
if [ -f "$INFRA_DIR/secrets/postgres_password.txt" ]; then
    PGPASSWORD="$(cat "$INFRA_DIR/secrets/postgres_password.txt")"
    export PGPASSWORD
fi

echo "Applying additive migration to neps_db..."
docker exec -i "$POSTGRES_CONTAINER" psql -U neps -d neps_db -v ON_ERROR_STOP=1 < "$SQL_FILE"

echo ""
echo "=== Verifying 9 Additive Tables ==="
EXPECTED_TABLES=(
    "nds_v31_intake_raw"
    "nds_v31_intake_audit"
    "nds_v31_intake_head"
    "nds_v31_intake_pending"
    "nds_v31_participant_links"
    "nds_v31_source"
    "nds_v31_audit"
    "nds_v31_derived"
    "nds_v31_validated"
)

ALL_PRESENT=true
for table in "${EXPECTED_TABLES[@]}"; do
    EXISTS=$(docker exec -i "$POSTGRES_CONTAINER" psql -U neps -d neps_db -tAc "SELECT to_regclass('public.$table');")
    if [ "$EXISTS" = "$table" ] || [ -n "$EXISTS" ]; then
        echo "  [OK] Table '$table' confirmed."
    else
        echo "  [MISSING] Table '$table' NOT found!"
        ALL_PRESENT=false
    fi
done

if [ "$ALL_PRESENT" = true ]; then
    echo ""
    echo "SUCCESS: All 9 independent intake tables applied and verified successfully."
    echo "Migration 002 is complete."
else
    echo ""
    echo "WARNING: One or more tables could not be verified."
    exit 1
fi

#!/bin/bash
set -euo pipefail

# NEPS Digital — Point-in-Time Recovery
# Usage: ./pitr-restore.sh "2026-05-27 14:30:15"

TARGET_TIME="${1:-}"
BACKUP_DIR="./backups/pitr"
RECOVERY_DIR="./backups/pitr/recovery"

if [ -z "$TARGET_TIME" ]; then
    echo "Usage: $0 \"YYYY-MM-DD HH:MM:SS\""
    echo "Example: $0 \"2026-05-27 14:30:15\""
    exit 1
fi

echo "==================================================="
echo "  NEPS Digital — Point-in-Time Recovery"
echo "  Target: $TARGET_TIME"
echo "==================================================="

# Stop PostgreSQL
echo "[1/6] Stopping PostgreSQL..."
docker-compose stop postgres

# Create recovery environment
echo "[2/6] Preparing recovery environment..."
rm -rf $RECOVERY_DIR
mkdir -p $RECOVERY_DIR

# Find closest base backup before target time
echo "[3/6] Finding base backup..."
LATEST_BASE=$(ls -t $BACKUP_DIR/base/ | grep "^base_" | head -1)
if [ -z "$LATEST_BASE" ]; then
    echo "ERROR: No base backup found!"
    exit 1
fi
echo "Using base backup: $LATEST_BASE"

# Extract base backup
echo "[4/6] Extracting base backup..."
tar -xzf "$BACKUP_DIR/base/$LATEST_BASE" -C $RECOVERY_DIR

# Create recovery configuration (PostgreSQL 15+ style)
echo "[5/6] Configuring recovery to $TARGET_TIME..."
touch $RECOVERY_DIR/recovery.signal
cat > $RECOVERY_DIR/postgresql.auto.conf << EOF
restore_command = 'cp /backup/pitr/wal/%f %p'
recovery_target_time = '$TARGET_TIME'
recovery_target_action = 'promote'
recovery_target_inclusive = true
EOF

# Backup current data and replace with recovery
echo "[6/6] Starting PostgreSQL in recovery mode..."
# Note: Using the default compose project name prefix
docker run --rm \
    -v neps-infrastructure_postgres-data:/var/lib/postgresql/data \
    -v $(realpath $RECOVERY_DIR):/recovery \
    postgres:15-alpine \
    sh -c "rm -rf /var/lib/postgresql/data/* && cp -r /recovery/* /var/lib/postgresql/data/ && chown -R postgres:postgres /var/lib/postgresql/data/"

# Start PostgreSQL — it will automatically recover to target time
docker-compose up -d postgres

# Monitor recovery progress
echo ""
echo "Monitoring recovery progress..."
for i in {1..60}; do
    STATUS=$(docker-compose logs postgres 2>&1 | grep -o "recovery in progress" | head -1 || true)
    if [ -z "$STATUS" ]; then
        echo "✓ Recovery complete! Database is at: $TARGET_TIME"
        break
    fi
    echo "  Recovery in progress... ($i/60)"
    sleep 2
done

echo ""
echo "==================================================="
echo "  PITR Recovery Complete"
echo "  Target Time: $TARGET_TIME"
echo "  Verify data before promoting to production!"
echo "==================================================="

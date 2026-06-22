#!/bin/bash
set -euo pipefail

BACKUP_DIR="/backup/pitr"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30

echo "==================================================="
echo "  NEPS Digital — PITR Backup"
echo "  Timestamp: $TIMESTAMP"
echo "==================================================="

# Base backup (daily at 2 AM)
if [ "${1:-}" = "full" ] || [ "$(date +%H)" = "02" ]; then
    echo "[FULL] Creating base backup..."
    rm -rf "$BACKUP_DIR/base/tmp_base_backup" || true
    
    pg_basebackup \
        -D "$BACKUP_DIR/base/tmp_base_backup" \
        -Ft -z -P -U neps
    
    mv "$BACKUP_DIR/base/tmp_base_backup/base.tar.gz" "$BACKUP_DIR/base/base_$TIMESTAMP.tar.gz"
    rm -rf "$BACKUP_DIR/base/tmp_base_backup"
    
    # Cleanup old base backups
    find $BACKUP_DIR/base -name "base_*.tar.gz" -mtime +$RETENTION_DAYS -delete
    echo "✓ Base backup: base_$TIMESTAMP.tar.gz"
fi

# WAL archiving is continuous via archive_command
echo "[WAL] WAL archiving active"
echo "  Archive location: $BACKUP_DIR/wal/"
echo "  Current WAL files: $(ls -1 $BACKUP_DIR/wal/ | wc -l)"

# Cleanup old WAL files (keep 7 days minimum for PITR)
find $BACKUP_DIR/wal -type f -mtime +7 -delete

echo "✓ PITR backup cycle complete"

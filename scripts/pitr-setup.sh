#!/bin/bash
# PostgreSQL Point-in-Time Recovery Setup for NEPS Digital

PITR_DIR="/backup/pitr"
WAL_ARCHIVE="$PITR_DIR/wal"
BASE_BACKUP="$PITR_DIR/base"

mkdir -p $WAL_ARCHIVE $BASE_BACKUP

# PostgreSQL configuration for PITR
mkdir -p postgres
cat > postgres/postgresql.pitr.conf << 'EOF'
# WAL Archiving for PITR
wal_level = replica
archive_mode = on
archive_command = 'cp %p /backup/pitr/wal/%f'
archive_timeout = 60
max_wal_size = 1GB
min_wal_size = 80MB

# Recovery settings (used during restore)
recovery_target_time = ''  # Set during PITR
recovery_target_action = 'promote'
EOF

echo "PITR configuration created. Add to docker-compose volumes."

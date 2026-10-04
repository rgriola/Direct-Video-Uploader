#!/bin/bash
# Nightly encrypted Postgres backup for the home server (dev.ms-fixer.com).
# Dumps directvideo -> gzip -> gpg symmetric encrypt -> ~/backups/, prunes >7 days.
set -euo pipefail

PG_BIN="/opt/homebrew/opt/postgresql@18/bin"
BACKUP_DIR="$HOME/backups"
PASSPHRASE_FILE="$HOME/.backup-passphrase"
RETENTION_DAYS=7
DATE=$(date +%Y-%m-%d_%H%M%S)
DUMP_FILE="$BACKUP_DIR/directvideo_${DATE}.sql.gz.gpg"

mkdir -p "$BACKUP_DIR"

"$PG_BIN/pg_dump" -h 127.0.0.1 -U fixer_app -d directvideo \
  | gzip \
  | gpg --batch --yes --passphrase-file "$PASSPHRASE_FILE" --symmetric --cipher-algo AES256 -o "$DUMP_FILE"

find "$BACKUP_DIR" -name "directvideo_*.sql.gz.gpg" -mtime +$RETENTION_DAYS -delete

echo "$(date '+%Y-%m-%d %H:%M:%S') Backup complete: $DUMP_FILE"

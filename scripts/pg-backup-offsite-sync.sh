#!/bin/bash
# Weekly offsite copy of encrypted local backups to Backblaze B2.
set -euo pipefail

BACKUP_DIR="$HOME/backups"
REMOTE="b2backup:ms-fixer-backups"

/opt/homebrew/bin/rclone sync "$BACKUP_DIR" "$REMOTE" \
  --include "directvideo_*.sql.gz.gpg" \
  --log-level INFO

echo "$(date '+%Y-%m-%d %H:%M:%S') Offsite sync complete: $BACKUP_DIR -> $REMOTE"

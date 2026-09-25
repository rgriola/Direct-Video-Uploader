#!/bin/bash
# One-time local dev setup: enable passwordless (trust) local auth on the
# system PostgreSQL 17 install and create the directvideo database.
# Run this yourself — it needs sudo for a root-owned config file + system daemon restart.
set -euo pipefail

PGDATA=/Library/PostgreSQL/17/data
PSQL=/Library/PostgreSQL/17/bin/psql

echo "→ Backing up pg_hba.conf"
sudo cp "$PGDATA/pg_hba.conf" "$PGDATA/pg_hba.conf.bak"

echo "→ Enabling trust auth for local/loopback connections"
sudo sed -i '' -E \
  -e 's/(host[[:space:]]+all[[:space:]]+all[[:space:]]+(127\.0\.0\.1\/32|::1\/128)[[:space:]]+)(scram-sha-256|md5|password)/\1trust/' \
  -e 's/(local[[:space:]]+all[[:space:]]+all[[:space:]]+)(peer|scram-sha-256|md5|password)/\1trust/' \
  "$PGDATA/pg_hba.conf"

echo "→ Restarting postgresql-17"
sudo launchctl kickstart -k system/postgresql-17
sleep 2

echo "→ Creating directvideo database (if missing)"
"$PSQL" -h localhost -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = 'directvideo'" | grep -q 1 \
  || "$PSQL" -h localhost -U postgres -c "CREATE DATABASE directvideo;"

echo "→ Done. Test with:"
echo "  $PSQL -h localhost -U postgres -d directvideo -c '\\conninfo'"

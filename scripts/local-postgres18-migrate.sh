#!/bin/bash
# One-time migration: stop the old system PostgreSQL 17 (EDB installer) so
# Homebrew's postgresql@18 can bind to port 5432, then start postgresql@18
# and create a fresh directvideo database.
set -euo pipefail

echo "→ Disabling system PostgreSQL 17 daemon (frees port 5432)"
sudo launchctl bootout system/postgresql-17 2>/dev/null || true
sudo launchctl disable system/postgresql-17

echo "→ Starting postgresql@18 via brew services"
brew services start postgresql@18
sleep 2

echo "→ Creating directvideo database"
/opt/homebrew/opt/postgresql@18/bin/createdb directvideo

echo "→ Done. Test with:"
echo "  /opt/homebrew/opt/postgresql@18/bin/psql -h localhost -d directvideo -c '\\conninfo'"

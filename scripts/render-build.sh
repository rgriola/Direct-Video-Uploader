#!/usr/bin/env bash
# Render Build Script — Direct Video Uploader
# Runs during each deploy: installs deps, builds admin, generates Prisma, pushes schema, seeds DB.
set -euo pipefail

echo "══════════════════════════════════════════"
echo "  🎬 Direct Video Uploader — Render Build"
echo "══════════════════════════════════════════"

# 1. Install dependencies (both server + admin)
echo "📦 Installing server dependencies..."
cd server && npm ci
cd ..

echo "📦 Installing admin dependencies..."
cd admin && npm ci
cd ..

# 2. Build admin dashboard → server/public/
echo "🔨 Building admin dashboard..."
cd admin && npm run build
cd ..

# 3. Generate Prisma client
echo "🔧 Generating Prisma client..."
cd server && npx prisma generate

# 4. Push schema to database (creates tables if missing)
echo "🗄️  Pushing schema to database..."
npx prisma db push --accept-data-loss

# 5. Seed demo users (idempotent — skips existing)
echo "🌱 Seeding demo users..."
node src/seed.js

# 6. Ensure uploads directory exists (ephemeral on Render — cloud storage replaces this)
mkdir -p uploads

echo ""
echo "✅ Build complete — ready to start!"
echo ""

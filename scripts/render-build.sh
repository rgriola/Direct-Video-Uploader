#!/usr/bin/env bash
# Last updated: May 13, 2026 - 2:05pm - GitHub Copilot (GPT-5.3-Codex)
# Render Build Script — Direct Video Uploader
# Runs during each deploy: installs deps, builds admin, generates Prisma, applies migrations, seeds DB.
set -euo pipefail

echo "══════════════════════════════════════════"
echo "  🎬 Direct Video Uploader — Render Build"
echo "══════════════════════════════════════════"

# 1. Install dependencies (both server + admin)
# --include=dev is required because Render sets NODE_ENV=production,
# which skips devDependencies (prisma, vite, typescript, @types/*).
echo "📦 Installing server dependencies..."
cd server && npm ci --include=dev
cd ..

echo "📦 Installing admin dependencies..."
cd admin && npm ci --include=dev
cd ..

# 2. Build admin dashboard → server/public/
echo "🔨 Building admin dashboard..."
cd admin && npm run build
cd ..

# 3. Generate Prisma client
echo "🔧 Generating Prisma client..."
cd server && npx prisma generate

# 3.5. One-time baseline for pre-existing production databases (P3005 guard)
echo "🧭 Checking Prisma baseline..."
node scripts/prisma-baseline-if-needed.js

# 4. Apply versioned migrations
echo "🗄️  Applying migrations..."
npx prisma migrate deploy

# 5. Seed demo users (idempotent — skips existing)
echo "🌱 Seeding demo users..."
node src/seed.js

# 6. Ensure uploads directory exists (ephemeral on Render — cloud storage replaces this)
mkdir -p uploads

echo ""
echo "✅ Build complete — ready to start!"
echo ""

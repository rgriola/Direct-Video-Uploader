Last updated: May 12, 2026 - 1:25pm - GitHub Copilot (GPT-5.3-Codex)

# Prisma Migrations Runbook (Phase 0.5)

This project now uses versioned Prisma migrations.

## Baseline Migration

The baseline migration for existing databases is:

- `20260512132446_baseline`

Committed files:

- `server/prisma/migrations/20260512132446_baseline/migration.sql`
- `server/prisma/migrations/migration_lock.toml`

## Standard Developer Flow

When changing `server/prisma/schema.prisma`:

1. Create and apply a named migration locally:
   - `cd server && npm run db:migrate -- --name <short_change_name>`
2. Verify migration status:
   - `cd server && npm run db:status`
3. Commit both:
   - Schema changes
   - New folder under `server/prisma/migrations/`

For fresh or ephemeral databases (no existing schema), apply migrations with:

- `cd server && npm run db:deploy`

## One-Time Baselining for Existing Non-Empty Databases

If `prisma migrate deploy` fails with `P3005` (database schema is not empty), run this once per environment:

1. Optional safety check:
   - `cd server && npx prisma migrate diff --from-schema prisma/schema.prisma --to-config-datasource --exit-code`
2. Mark baseline migration as already applied:
   - `cd server && npm run db:resolve -- --applied 20260512132446_baseline`
3. Re-run deploy:
   - `cd server && npm run db:deploy`

## Production Rollback Procedure

Use this when a deployment migration fails or must be reverted.

1. Roll back application code in Render to the last known-good deploy.
2. Mark the failed migration as rolled back:
   - `cd server && npm run db:resolve -- --rolled-back <failed_migration_name>`
3. Re-run migration deploy from stable code:
   - `cd server && npm run db:deploy`
4. Validate:
   - `cd server && npm run db:status`
   - `curl https://ms-fixer.com/api/health/ready`

Notes:

- Do not use `prisma db push` in production.
- Always include migration files in PRs that modify Prisma schema.

-- Last updated: May 12, 2026 - 3:35pm - GitHub Copilot (GPT-5.3-Codex)

-- Phase 2.1 RBAC enum expansion
-- Legacy values are renamed in place to preserve existing records.

ALTER TYPE "UserRole" RENAME VALUE 'ADMIN' TO 'SUPER_ADMIN';
ALTER TYPE "UserRole" RENAME VALUE 'USER' TO 'EDITOR';

ALTER TYPE "UserRole" ADD VALUE IF NOT EXISTS 'ORG_ADMIN';
ALTER TYPE "UserRole" ADD VALUE IF NOT EXISTS 'VIEWER';

ALTER TABLE "users"
  ALTER COLUMN "role" SET DEFAULT 'EDITOR';

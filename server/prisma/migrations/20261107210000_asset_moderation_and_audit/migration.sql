CREATE TYPE "AssetModeration" AS ENUM ('ACTIVE', 'PAUSED', 'FLAGGED_FOR_REMOVAL', 'REMOVED');
CREATE TYPE "AuditTargetType" AS ENUM ('USER', 'ASSET');

ALTER TABLE "users"
ADD COLUMN "paused_at" TIMESTAMP(3),
ADD COLUMN "paused_by_id" TEXT;

ALTER TABLE "assets"
ADD COLUMN "moderation" "AssetModeration" NOT NULL DEFAULT 'ACTIVE',
ADD COLUMN "moderated_at" TIMESTAMP(3),
ADD COLUMN "moderated_by_id" TEXT,
ADD COLUMN "moderation_reason" TEXT;

CREATE TABLE "audit_logs" (
    "id" TEXT NOT NULL,
    "actor_user_id" TEXT NOT NULL,
    "target_type" "AuditTargetType" NOT NULL,
    "target_id" TEXT NOT NULL,
    "action" VARCHAR(50) NOT NULL,
    "reason" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "assets_moderation_created_at_idx" ON "assets"("moderation", "created_at");
CREATE INDEX "audit_logs_target_type_target_id_created_at_idx" ON "audit_logs"("target_type", "target_id", "created_at");
CREATE INDEX "audit_logs_actor_user_id_created_at_idx" ON "audit_logs"("actor_user_id", "created_at");

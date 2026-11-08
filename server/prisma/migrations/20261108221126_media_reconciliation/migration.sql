-- CreateEnum
CREATE TYPE "MediaSyncState" AS ENUM ('PENDING', 'SYNCED', 'ERROR');

-- AlterTable
ALTER TABLE "assets" ADD COLUMN     "media_create_mux_asset_id" TEXT,
ADD COLUMN     "media_create_operation_id" TEXT,
ADD COLUMN     "media_create_started_at" TIMESTAMP(3),
ADD COLUMN     "media_playback_reset" BOOLEAN NOT NULL DEFAULT false,
ADD COLUMN     "media_sync_error" TEXT,
ADD COLUMN     "media_sync_next_at" TIMESTAMP(3) DEFAULT CURRENT_TIMESTAMP,
ADD COLUMN     "media_sync_revision" INTEGER NOT NULL DEFAULT 0,
ADD COLUMN     "media_sync_state" "MediaSyncState" NOT NULL DEFAULT 'PENDING';

UPDATE "assets"
SET "media_playback_reset" = true
WHERE "moderation" <> 'ACTIVE';

ALTER TABLE "assets" ADD CONSTRAINT "assets_media_create_operation_check" CHECK (
    ("media_create_operation_id" IS NULL AND "media_create_mux_asset_id" IS NULL AND "media_create_started_at" IS NULL)
    OR
    ("media_create_operation_id" IS NOT NULL AND "media_create_mux_asset_id" IS NOT NULL AND "media_create_started_at" IS NOT NULL)
);

-- CreateIndex
CREATE INDEX "assets_media_sync_state_media_sync_next_at_idx" ON "assets"("media_sync_state", "media_sync_next_at");

-- CreateIndex
CREATE INDEX "assets_moderation_media_sync_next_at_idx" ON "assets"("moderation", "media_sync_next_at");

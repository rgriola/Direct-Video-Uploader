-- CreateEnum
CREATE TYPE "UploadSessionStatus" AS ENUM ('OPEN', 'COMPLETING', 'COMPLETED', 'ABORTED', 'EXPIRED');

-- AlterTable
ALTER TABLE "clips"
ADD COLUMN "storage_key" TEXT,
ADD COLUMN "storage_driver" TEXT,
ADD COLUMN "sha256" VARCHAR(64);

-- CreateTable
CREATE TABLE "upload_sessions" (
    "id" TEXT NOT NULL,
    "owner_id" TEXT NOT NULL,
    "asset_id" TEXT NOT NULL,
    "clip_id" TEXT NOT NULL,
    "storage_driver" TEXT NOT NULL DEFAULT 'local',
    "storage_key" TEXT NOT NULL,
    "expected_size_bytes" BIGINT,
    "expected_sha256" VARCHAR(64),
    "status" "UploadSessionStatus" NOT NULL DEFAULT 'OPEN',
    "expires_at" TIMESTAMP(3) NOT NULL,
    "completed_at" TIMESTAMP(3),
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "upload_sessions_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "upload_sessions_expected_size_bytes_check" CHECK ("expected_size_bytes" IS NULL OR "expected_size_bytes" >= 0),
    CONSTRAINT "upload_sessions_expected_sha256_check" CHECK ("expected_sha256" IS NULL OR "expected_sha256" ~ '^[0-9a-f]{64}$')
);

-- CreateTable
CREATE TABLE "upload_parts" (
    "upload_session_id" TEXT NOT NULL,
    "part_number" INTEGER NOT NULL,
    "size_bytes" BIGINT NOT NULL,
    "sha256" VARCHAR(64) NOT NULL,
    "uploaded_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "upload_parts_pkey" PRIMARY KEY ("upload_session_id", "part_number"),
    CONSTRAINT "upload_parts_part_number_check" CHECK ("part_number" > 0),
    CONSTRAINT "upload_parts_size_bytes_check" CHECK ("size_bytes" >= 0),
    CONSTRAINT "upload_parts_sha256_check" CHECK ("sha256" ~ '^[0-9a-f]{64}$')
);

-- CreateIndex
CREATE UNIQUE INDEX "clips_storage_key_key" ON "clips"("storage_key");
CREATE INDEX "upload_sessions_owner_id_status_expires_at_idx" ON "upload_sessions"("owner_id", "status", "expires_at");
CREATE INDEX "upload_sessions_asset_id_status_idx" ON "upload_sessions"("asset_id", "status");
CREATE INDEX "upload_sessions_clip_id_status_idx" ON "upload_sessions"("clip_id", "status");
CREATE UNIQUE INDEX "upload_sessions_storage_key_key" ON "upload_sessions"("storage_key");
CREATE INDEX "upload_parts_uploaded_at_idx" ON "upload_parts"("uploaded_at");

-- AddCheckConstraint
ALTER TABLE "clips" ADD CONSTRAINT "clips_storage_metadata_check"
CHECK ("storage_key" IS NULL OR ("storage_driver" IS NOT NULL AND "sha256" IS NOT NULL));

ALTER TABLE "clips" ADD CONSTRAINT "clips_sha256_check"
CHECK ("sha256" IS NULL OR "sha256" ~ '^[0-9a-f]{64}$');

-- AddForeignKey
ALTER TABLE "upload_sessions" ADD CONSTRAINT "upload_sessions_owner_id_fkey"
FOREIGN KEY ("owner_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "upload_sessions" ADD CONSTRAINT "upload_sessions_asset_id_fkey"
FOREIGN KEY ("asset_id") REFERENCES "assets"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "upload_sessions" ADD CONSTRAINT "upload_sessions_clip_id_fkey"
FOREIGN KEY ("clip_id") REFERENCES "clips"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "upload_parts" ADD CONSTRAINT "upload_parts_upload_session_id_fkey"
FOREIGN KEY ("upload_session_id") REFERENCES "upload_sessions"("id") ON DELETE CASCADE ON UPDATE CASCADE;

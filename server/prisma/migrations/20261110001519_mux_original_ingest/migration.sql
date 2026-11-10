-- CreateEnum
CREATE TYPE "MuxIngestJobStatus" AS ENUM ('QUEUED', 'CREATING', 'LINKED', 'FAILED', 'UNKNOWN', 'CONFLICT');

-- CreateEnum
CREATE TYPE "MuxIngestAttemptStatus" AS ENUM ('CREATING', 'LINKED', 'REJECTED', 'UNKNOWN', 'CONFIRMED_ABSENT');

-- CreateTable
CREATE TABLE "mux_ingest_jobs" (
    "upload_session_id" TEXT NOT NULL,
    "status" "MuxIngestJobStatus" NOT NULL DEFAULT 'QUEUED',
    "attempt_count" INTEGER NOT NULL DEFAULT 0,
    "retry_count" INTEGER NOT NULL DEFAULT 0,
    "current_attempt_id" TEXT,
    "next_attempt_at" TIMESTAMP(3) DEFAULT CURRENT_TIMESTAMP,
    "last_error" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "mux_ingest_jobs_pkey" PRIMARY KEY ("upload_session_id"),
    CONSTRAINT "mux_ingest_jobs_attempt_count_check" CHECK ("attempt_count" >= 0 AND "retry_count" >= 0)
);

-- A lease is removed only after the response closes, or after audited operator confirmation.
CREATE TABLE "mux_original_read_leases" (
    "id" TEXT NOT NULL,
    "asset_id" TEXT NOT NULL,
    "attempt_id" TEXT NOT NULL,
    "server_instance_id" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "mux_original_read_leases_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "mux_ingest_attempts" (
    "id" TEXT NOT NULL,
    "upload_session_id" TEXT NOT NULL,
    "status" "MuxIngestAttemptStatus" NOT NULL DEFAULT 'CREATING',
    "read_expires_at" TIMESTAMP(3) NOT NULL,
    "mux_asset_id" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "resolved_at" TIMESTAMP(3),

    CONSTRAINT "mux_ingest_attempts_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "mux_ingest_attempts_linked_asset_check"
        CHECK ("status" <> 'LINKED' OR "mux_asset_id" IS NOT NULL)
);

-- CreateIndex
CREATE INDEX "mux_ingest_jobs_status_next_attempt_at_idx" ON "mux_ingest_jobs"("status", "next_attempt_at");

-- CreateIndex
CREATE INDEX "mux_ingest_attempts_upload_session_id_status_idx" ON "mux_ingest_attempts"("upload_session_id", "status");

-- CreateIndex
CREATE INDEX "mux_ingest_attempts_mux_asset_id_idx" ON "mux_ingest_attempts"("mux_asset_id");

-- CreateIndex
CREATE INDEX "mux_original_read_leases_asset_id_created_at_idx" ON "mux_original_read_leases"("asset_id", "created_at");

-- Only one unresolved remote create may exist for an original.
CREATE UNIQUE INDEX "mux_ingest_attempts_one_unresolved_per_session"
ON "mux_ingest_attempts"("upload_session_id")
WHERE "status" IN ('CREATING', 'UNKNOWN');

-- AddForeignKey
ALTER TABLE "mux_ingest_jobs" ADD CONSTRAINT "mux_ingest_jobs_upload_session_id_fkey" FOREIGN KEY ("upload_session_id") REFERENCES "upload_sessions"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "mux_ingest_attempts" ADD CONSTRAINT "mux_ingest_attempts_upload_session_id_fkey" FOREIGN KEY ("upload_session_id") REFERENCES "mux_ingest_jobs"("upload_session_id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "mux_original_read_leases" ADD CONSTRAINT "mux_original_read_leases_asset_id_fkey" FOREIGN KEY ("asset_id") REFERENCES "assets"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "mux_original_read_leases" ADD CONSTRAINT "mux_original_read_leases_attempt_id_fkey" FOREIGN KEY ("attempt_id") REFERENCES "mux_ingest_attempts"("id") ON DELETE CASCADE ON UPDATE CASCADE;

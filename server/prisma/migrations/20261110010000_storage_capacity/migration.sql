ALTER TABLE "upload_sessions"
ADD COLUMN "storage_reservation_bytes" BIGINT;

UPDATE "upload_sessions"
SET "storage_reservation_bytes" = CASE
    WHEN "expected_size_bytes" > 0
      AND "expected_size_bytes" <= 4611686018426863615
    THEN "expected_size_bytes" * 2 + 1048576
    ELSE NULL
END;

ALTER TABLE "upload_sessions"
ADD CONSTRAINT "upload_sessions_storage_reservation_bytes_check"
CHECK ("storage_reservation_bytes" IS NULL OR "storage_reservation_bytes" >= 0);

CREATE TABLE "storage_write_leases" (
    "id" TEXT NOT NULL,
    "upload_session_id" TEXT NOT NULL,
    "storage_identity" TEXT NOT NULL,
    "size_bytes" BIGINT NOT NULL,
    "host" TEXT NOT NULL,
    "pid" INTEGER NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "storage_write_leases_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "storage_write_leases_size_bytes_check" CHECK ("size_bytes" > 0),
    CONSTRAINT "storage_write_leases_pid_check" CHECK ("pid" > 0)
);

CREATE INDEX "storage_write_leases_upload_session_id_idx"
ON "storage_write_leases"("upload_session_id");

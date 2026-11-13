-- CreateTable
CREATE TABLE "mux_retired_ingest_attempts" (
    "operation_id" TEXT NOT NULL,
    "original_mux_asset_id" TEXT,
    "retired_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "mux_retired_ingest_attempts_pkey" PRIMARY KEY ("operation_id")
);

-- CreateTable
CREATE TABLE "mux_retired_ingest_events" (
    "operation_id" TEXT NOT NULL,
    "mux_asset_id" TEXT NOT NULL,
    "first_seen_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "mux_retired_ingest_events_pkey" PRIMARY KEY ("operation_id","mux_asset_id")
);

-- AddForeignKey
ALTER TABLE "mux_retired_ingest_events" ADD CONSTRAINT "mux_retired_ingest_events_operation_id_fkey" FOREIGN KEY ("operation_id") REFERENCES "mux_retired_ingest_attempts"("operation_id") ON DELETE RESTRICT ON UPDATE CASCADE;

CREATE TYPE "AssetUploadMode" AS ENUM ('MUX', 'ORIGINAL');

ALTER TABLE "assets"
ADD COLUMN "upload_mode" "AssetUploadMode",
ADD COLUMN "original_intent_size_bytes" INTEGER,
ADD COLUMN "original_intent_sha256" VARCHAR(64),
ADD CONSTRAINT "assets_original_intent_integrity_check" CHECK (
    ("original_intent_size_bytes" IS NULL AND "original_intent_sha256" IS NULL)
    OR (
        "upload_mode" IS NOT NULL AND "upload_mode" = 'ORIGINAL'
        AND "original_intent_size_bytes" IS NOT NULL
        AND "original_intent_size_bytes" BETWEEN 1 AND 524288000
        AND "original_intent_sha256" IS NOT NULL
        AND "original_intent_sha256" ~ '^[0-9a-f]{64}$'
    )
);

UPDATE "assets" AS asset
SET "upload_mode" = 'ORIGINAL'
WHERE EXISTS (SELECT 1 FROM "upload_sessions" AS session WHERE session."asset_id" = asset."id")
   OR EXISTS (SELECT 1 FROM "clips" AS clip WHERE clip."asset_id" = asset."id" AND clip."storage_key" IS NOT NULL);

UPDATE "assets" AS asset
SET "upload_mode" = 'MUX'
WHERE asset."upload_mode" IS NULL
  AND EXISTS (SELECT 1 FROM "clips" AS clip WHERE clip."asset_id" = asset."id" AND clip."mux_upload_id" IS NOT NULL);

CREATE TABLE "original_upload_intents" (
    "user_id" TEXT NOT NULL,
    "client_request_id" UUID NOT NULL,
    "asset_id" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "original_upload_intents_pkey" PRIMARY KEY ("user_id", "client_request_id")
);

CREATE UNIQUE INDEX "original_upload_intents_asset_id_key"
ON "original_upload_intents"("asset_id");

ALTER TABLE "original_upload_intents"
ADD CONSTRAINT "original_upload_intents_user_id_fkey"
FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "original_upload_intents"
ADD CONSTRAINT "original_upload_intents_asset_id_fkey"
FOREIGN KEY ("asset_id") REFERENCES "assets"("id") ON DELETE SET NULL ON UPDATE CASCADE;

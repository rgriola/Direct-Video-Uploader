DROP INDEX "original_upload_intents_user_id_cancelled_at_asset_id_idx";

-- Managed in SQL because Prisma requires a preview feature for partial indexes.
CREATE INDEX "original_upload_intents_unreserved_cancelled_at_idx"
  ON "original_upload_intents"("user_id", "cancelled_at" DESC)
  WHERE "asset_id" IS NULL AND "cancelled_at" IS NOT NULL;

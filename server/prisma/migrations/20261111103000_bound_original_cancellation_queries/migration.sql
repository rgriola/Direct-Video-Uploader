CREATE INDEX "original_upload_intents_user_id_cancelled_at_asset_id_idx"
  ON "original_upload_intents"("user_id", "cancelled_at" DESC, "asset_id");

CREATE INDEX "upload_sessions_asset_id_id_idx"
  ON "upload_sessions"("asset_id", "id");

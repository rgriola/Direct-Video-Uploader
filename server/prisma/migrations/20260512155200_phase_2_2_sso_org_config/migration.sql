-- Last updated: May 12, 2026 - 3:52pm - GitHub Copilot (GPT-5.3-Codex)

-- Phase 2.2 Organization SSO configuration fields
ALTER TABLE "organizations"
  ADD COLUMN IF NOT EXISTS "sso_enabled" BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS "saml_metadata_url" TEXT,
  ADD COLUMN IF NOT EXISTS "saml_entity_id" TEXT,
  ADD COLUMN IF NOT EXISTS "saml_attribute_mapping" JSONB;

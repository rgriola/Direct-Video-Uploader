DO $$
BEGIN
    IF EXISTS (
        SELECT "mux_asset_id"
        FROM "clips"
        WHERE "mux_asset_id" IS NOT NULL
        GROUP BY "mux_asset_id"
        HAVING COUNT(DISTINCT "asset_id") > 1
    ) THEN
        RAISE EXCEPTION 'A Mux asset is associated with more than one asset';
    END IF;
END $$;

-- CreateTable
CREATE TABLE "mux_asset_references" (
    "mux_asset_id" TEXT NOT NULL,
    "asset_id" TEXT NOT NULL,
    "clip_id" TEXT,

    CONSTRAINT "mux_asset_references_pkey" PRIMARY KEY ("mux_asset_id")
);

-- CreateIndex
CREATE INDEX "mux_asset_references_asset_id_idx" ON "mux_asset_references"("asset_id");

-- AddForeignKey
ALTER TABLE "mux_asset_references" ADD CONSTRAINT "mux_asset_references_asset_id_fkey" FOREIGN KEY ("asset_id") REFERENCES "assets"("id") ON DELETE CASCADE ON UPDATE CASCADE;

INSERT INTO "mux_asset_references" ("mux_asset_id", "asset_id", "clip_id")
SELECT "mux_asset_id", MIN("asset_id"), MIN("id")
FROM "clips"
WHERE "mux_asset_id" IS NOT NULL
GROUP BY "mux_asset_id";

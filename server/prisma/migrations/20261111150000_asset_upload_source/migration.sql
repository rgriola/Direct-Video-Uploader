CREATE TYPE "AssetUploadSource" AS ENUM ('IOS', 'WEB');

ALTER TABLE "assets" ADD COLUMN "upload_source" "AssetUploadSource";

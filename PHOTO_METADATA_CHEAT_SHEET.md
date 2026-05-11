# Photo Metadata Cheat Sheet
- Last updated: May 9, 2026 - 10:14pm - GPT-5.3-Codex

Quick, practical reference for cross-app photo pipelines.

---

## EXIF/IPTC/XMP Foundational Truth (Quick, Practical)

1. EXIF is capture and camera data.
- Think: date/time captured, lens, shutter, ISO, GPS.

2. IPTC is editorial and publishing data.
- Think: caption, headline, keywords, credit, copyright.

3. XMP is the modern metadata container.
- XMP can carry EXIF/IPTC-style fields and app-specific fields.
- Adobe workflows center around XMP.

4. RAW files should stay byte-for-byte original.
- Write metadata to a sidecar .xmp for RAW workflows.

5. JPEG/TIFF can carry embedded metadata.
- Write editorial metadata into a tagged copy, not the original.

6. Always keep one source-of-truth metadata object.
- Keep normalized sidecar JSON in your app/database, then derive embedded or .xmp outputs from it.

---

## By File Type

| Type | Read EXIF | Embed IPTC/XMP | Recommended write pattern |
|---|---|---|---|
| RAW (.cr3/.nef/.arw/.dng/...) | Yes | Avoid direct writes | Keep original + write .xmp sidecar |
| JPEG | Yes | Yes | Keep original + write tagged JPG copy |
| TIFF | Yes | Yes | Keep original + write tagged TIFF copy |
| HEIC | Usually | Varies by tool/ecosystem | Test end-to-end; keep sidecar JSON source-of-truth |
| PNG | Limited/inconsistent for photo workflows | Limited/inconsistent | Use only when required; do not depend on IPTC parity |

---

## Canonical Cross-App Field Set

Treat these as your portable schema across apps: 

- Capture: dateCaptured, timezoneOffset, gpsLatitude, gpsLongitude
- Camera: make, model, lens, focalLength, aperture, shutterSpeed, iso
- Editorial: caption, headline, keywords
- Credit/Rights: byline, credit, copyright, usageTerms
- Location: city, stateProvince, country
- Provenance: importedAt, userModifiedAt, originalFileName, originalUTI, fileHash

Keep this schema stable in your own JSON model and map out to EXIF/IPTC/XMP tags per destination.

---

## Practical Field Mapping (Most Important)

| Business concept | EXIF-style tag | IPTC-style tag | XMP tag (common) |
|---|---|---|---|
| Capture date/time | EXIF:DateTimeOriginal | - | XMP-exif:DateTimeOriginal |
| Caption/description | - | IPTC:Caption-Abstract | XMP-dc:Description |
| Headline | - | IPTC:Headline | XMP-photoshop:Headline |
| Keywords | - | IPTC:Keywords | XMP-dc:Subject |
| Creator/byline | - | IPTC:By-line | XMP-dc:Creator |
| Credit | - | IPTC:Credit | XMP-photoshop:Credit |
| Copyright notice | EXIF:Copyright (sometimes) | IPTC:CopyrightNotice | XMP-dc:Rights |
| City | - | IPTC:City | XMP-photoshop:City |
| State/Province | - | IPTC:Province-State | XMP-photoshop:State |
| Country | - | IPTC:Country-PrimaryLocationName | XMP-photoshop:Country |
| GPS lat/lon | EXIF:GPSLatitude/EXIF:GPSLongitude | - | XMP-exif:GPSLatitude/XMP-exif:GPSLongitude |

Notes:
- Tag names vary slightly by tool output formatting.
- Keep business-level names in your app; keep tag mapping in one adapter layer.

---

## No-Heavy-Coding Inspection Workflow

Install ExifTool once:

```bash
brew install exiftool
```

Inspect everything:

```bash
exiftool -a -G1 -s /path/to/file.CR3
```

Inspect only key fields:

```bash
exiftool -DateTimeOriginal -Make -Model -LensModel -ISO -ShutterSpeed -Aperture \
  -GPSLatitude -GPSLongitude -Headline -Caption-Abstract -Keywords -Copyright \
  /path/to/file.jpg
```

Inspect an XMP sidecar:

```bash
exiftool -a -G1 -s /path/to/file.xmp
```

Quick compare original vs tagged:

```bash
exiftool -a -G1 -s original.jpg > original.meta.txt
exiftool -a -G1 -s tagged.jpg > tagged.meta.txt
diff -u original.meta.txt tagged.meta.txt
```

---

## Write-Safely Rules (Portable Across Apps)

1. Never mutate original RAW bytes.
2. Preserve original upload for all formats.
3. Write derivatives only:
- RAW: original + .xmp
- JPEG/TIFF: original + tagged copy
4. Keep sidecar JSON as source-of-truth for reprocessing. 
5. Store UTC plus original local capture context when possible.
6. Log who changed metadata and when. 

---

## Common Failure Modes

- Time drift: capture time interpreted without timezone context.
- GPS sign mistakes: west/south coordinates flipped positive.
- Keyword bloat: duplicate or inconsistent keyword casing.
- Tool mismatch: HEIC metadata appears in one app, missing in another.
- Accidental RAW mutation: breaks trust and ingest consistency.

---

## One-Line Decision Standard

Preserve originals, normalize metadata once, and render Lightroom-ready derivatives (.xmp for RAW, embedded tagged copy for JPEG/TIFF).
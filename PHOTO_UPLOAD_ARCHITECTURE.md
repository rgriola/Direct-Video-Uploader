# Photo-Fixer — Upload Pipeline Architecture
- May 3 2026
- Last updated: May 9, 2026 - 10:29pm - GPT-5.3-Codex
- NOTES for me. I need to consider the upload feature, sidecars + interaction with Lightroom + Classic. Also a way to manage LR Classic catalogs + thumbnails ie; Are catalogs connected by year? Month? Can the dashboard using Adobe Extensions auto create and connect catalogs so search works across all the catalogs.  Also how can an AI implimentation on the Photo Dash assist search, vetting and scanning photos, using LR Facial Recognition, can this be done? Is this complicated?  Is there a way to make the upload process TEXT to Number > Dumps on Server (original Fixer idea for video). 


> **Product identity:** Photo-Fixer is an **organize → transport → deliver** app.
> The end destination is **Adobe Lightroom**. Every architectural decision must ask:
> "Will this photo land in Lightroom ready to catalog with correct metadata?"
>
> Status: Design phase — no implementation yet.
> Last updated: May 9, 2026 - 10:29pm - GPT-5.3-Codex
> Quick reference: [Photo Metadata Cheat Sheet](PHOTO_METADATA_CHEAT_SHEET.md)

---

## 1. Product Goal 

Photo-Fixer captures photos from professional cameras (via iOS import), lets the
photographer organize them into named **Projects**, edit/confirm metadata, and
transport them to a user-owned catch server — where they land **Lightroom-ready**:
correct EXIF dates, embedded IPTC (caption, keywords, copyright, location), and
`.xmp` sidecar files for RAW formats.

Both the **sender** (photographer) and **receiver** (photo editor / desk) get
clear status messages at every stage of the transport.

---

## 2. Authentication — Keep Phone Number + PIN + Org Code (Demo Scope)

For demo development, Photo-Fixer keeps the existing Fixer auth model:

- Login uses `companyCode + phoneNumber + pin`
- Server verifies account is `ACTIVE` and issues JWT
- JWT carries: `id`, `role`, `companyCode`
- All project/photo API access is scoped by `companyCode`
- Optional SMS notifications remain independent of auth provider

> The existing video pipeline auth remains unchanged.
> Supabase email auth can be revisited post-demo as a migration project, not P1.

---

## 3. High-Level Architecture

```
[Photo-Fixer iOS App]
        │
        ├─ 1. Name Project (title, assignment, destination email)
        ├─ 2. Pick Photos  (PHPickerViewController — images only)
        ├─ 3. Review/Edit Metadata per photo
        ├─ 4. Upload (zip/multipart → catch server)
        └─ 5. Status notifications → sender + receiver
                        │
                        ▼ HTTPS (authenticated endpoint; no anonymous upload/download)
                        
[Catch Server — user-owned, minimal overhead]
        │
        ├─ Validate format
        ├─ Stream originals to storage (zero buffering)
        ├─ Run exiftool async:
        │     RAW  → write .xmp sidecar (Lightroom standard)
        │     JPEG/TIFF/HEIC → embed IPTC into file copy
        ├─ Generate thumbnail via Sharp (async, validates file integrity)
        ├─ Notify receiver (email) + sender (email/SMS)
        └─ Storage ready for Lightroom import
```

---

## 4. Lightroom Delivery Standard

This is the north star for all metadata decisions.

### RAW files (CR2, CR3, ARW, NEF, DNG, RAF, ORF…)
Lightroom **does not write into RAW files**. It reads/writes an `.xmp` sidecar:

```
original.cr3       ← exact original bytes, never modified
original.xmp       ← Adobe XMP sidecar, written by exiftool from our sidecar JSON
```

XMP sidecar written by exiftool:
```xml
<rdf:Description
  xmp:Label="Red"
  xmpDM:shotDate="2026-05-01T14:32:00"
  dc:description="Caption text here"
  dc:rights="© 2026 Photographer Name"
  dc:creator="Photographer Name"
  Iptc4xmpCore:Location="City, State"
  lr:hierarchicalSubject="Sport|Basketball|NBA" />
```

### JPEG / TIFF / HEIC
exiftool **embeds** metadata directly into a copy of the file:
```
original.jpg        ← exact uploaded bytes
tagged.jpg          ← exiftool-modified copy with IPTC/EXIF embedded
                       (this is what Lightroom imports)
```

Both copies are stored. The original is never deleted.

---

## 5. iOS Layer

### 5.1 UX Flow — Project First, Then Photos

> **Design decision (from review):** Name the project first. The project title
> is the umbrella; photos live under it.

```
[Photos Tab]
    │
    └──► [+ New Project]
              │
              ▼
         ┌─────────────────────────────────┐
         │  Project Setup Sheet            │
         │  ─────────────────────────────  │
         │  Title*       [Assignment name] │
         │  Destination  [email address]   │
         │  Notes        [optional]        │
         │                                 │
         │         [Add Photos →]          │
         └─────────────────────────────────┘
              │
              ▼
         PHPickerViewController (multi-select, images only, no video)
              │
              ▼
         Project Detail View
              ├── Photo grid (thumbnail + status badge)
              ├── Tap photo → Metadata Editor Sheet
              └── [Upload Project] button
```

Draft projects auto-delete after **7 days** of inactivity.

### 5.2 Format Resolution — `PHImageManager` Fast Path

```swift
// Get exact original file URL — zero copy, zero conversion
let options = PHContentEditingInputRequestOptions()
options.isNetworkAccessAllowed = true
options.canHandleAdjustmentData = { _ in false }

asset.requestContentEditingInput(with: options) { input, _ in
    guard let url = input?.fullSizeImageURL,
          let uti = input?.uniformTypeIdentifier else { return }
    // url → stream directly to upload task
    // uti → determines XMP vs embedded IPTC path on server
}
```

**Supported UTI → Extension map** (`PhotoFormatResolver.swift`):

| UTI | Ext | Brand |
|-----|-----|-------|
| `com.canon.cr2` | `.cr2` | Canon |
| `com.canon.cr3` | `.cr3` | Canon |
| `com.sony.arw` | `.arw` | Sony |
| `com.nikon.nef` | `.nef` | Nikon |
| `com.olympus.orf` | `.orf` | Olympus |
| `com.fuji.raf` | `.raf` | Fujifilm |
| `com.adobe.raw-image` | `.dng` | DNG |
| `com.apple.rawImage` | `.dng` | ProRAW |
| `public.tiff` | `.tiff` | — |
| `public.jpeg` | `.jpg` | — |
| `public.heic` | `.heic` | Apple |

### 5.3 `PhotoSidecar` — Metadata Struct

Extracted read-only via `ImageIO` on import; user edits flow back here.
Never written to the original device file.

```swift
struct PhotoSidecar: Codable {
    // EXIF (read from ImageIO, user may override)
    var dateCaptured: Date?
    var gpsLatitude: Double?
    var gpsLongitude: Double?
    var gpsAltitude: Double?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var focalLength: Double?
    var aperture: Double?
    var shutterSpeed: String?
    var iso: Int?

    // IPTC / Editorial (user-supplied)
    var caption: String?
    var headline: String?
    var byline: String?        // photographer credit
    var credit: String?        // agency / publication
    var copyright: String?
    var keywords: [String]
    var city: String?
    var stateProvince: String?
    var country: String?
    var instructions: String?
    var usageTerms: String?

    // System
    var originalUTI: String
    var originalFileSize: Int64
    var importedAt: Date
    var userModifiedAt: Date?
    var isRAW: Bool            // drives XMP vs embedded path on server
}
```

### 5.4 Metadata Editor UI

Sheet shown when user taps a photo in the project grid:

```
📷  Camera          [EXIF read-only — toggle to override]
    Make · Model · Lens · f/ · ISO · Shutter

📍  Location        [map preview — editable]
    GPS coords → [Auto-fill City/State/Country via CLGeocoder]

✍️  Editorial
    Caption · Headline
    Keywords [chip input]
    Copyright · Byline · Credit

📅  Date / Time     [picker — defaults to EXIF DateTimeOriginal]
```

### 5.5 `PhotoUploadService` — Upload Strategy

Two modes; user/server can negotiate:

**Mode A — Per-photo multipart POST** (simpler, easier per-file retry)
**Mode B — Zip batch POST** (experiment for reliability + grouping; preferred if it proves stable)

```swift
@MainActor @Observable
final class PhotoUploadService {
    var projectProgress: [UUID: Double] = [:]
    var photoStatuses: [UUID: PhotoUploadStatus] = [:]

    func upload(project: PhotoProject, token: String) async throws {
        // 1. POST /api/photos/projects  → get serverProjectId
        // 2. Zip project or upload per-photo (max 3 concurrent)
        //    Each photo: stream original bytes + sidecar JSON
        // 3. POST /api/photos/projects/:id/complete
        // 4. Server triggers exiftool + thumbnail jobs async
        // 5. App receives WebSocket or polling confirmation
    }
}
```

Background uploads use `URLSessionConfiguration.background` — same pattern as `VideoUploadService.swift`. Resume logic checks `photo-projects.json` on launch.

---

## 6. Transport Status Messaging

> **Design requirement:** Both sender and receiver must know exactly where
> their photos are at all times. Clear, human-readable messages at every stage.

### Status States (shown in UI + sent via notifications)

| State | Sender sees | Receiver gets |
|-------|-------------|---------------|
| `DRAFT` | "Not uploaded yet" | — |
| `UPLOADING` | "Sending · 3 of 12 photos" | — |
| `PROCESSING` | "Arrived · preparing files" | — |
| `READY_PENDING_NOTIFY` | "✅ Processed · sending notifications" | — |
| `READY` | "✅ Delivered · ready in Lightroom" | Email: "Your photos are ready" |
| `PARTIAL` | "⚠️ 2 of 12 failed — tap to retry" | — |
| `FAILED` | "❌ Upload failed — [reason]" | — |

### Status Semantics (Decision)

To avoid ambiguity:

- `technicalStatus`: `DRAFT | UPLOADING | PROCESSING | PARTIAL | FAILED | READY`
- `deliveryStatus`: `PENDING | NOTIFIED | FAILED`

Operational rule:

- Processing job completion sets `technicalStatus=READY` and `deliveryStatus=PENDING`
- Notification workers update `deliveryStatus=NOTIFIED` when sender/receiver alerts succeed
- UI label "Delivered" is shown only when `technicalStatus=READY` and `deliveryStatus=NOTIFIED`

### Notification Channels

**Email (P1 — transactional email provider):**
- Sender: upload complete confirmation with photo count + project title
- Receiver: "Project [Title] delivered — [N] photos ready to import"
  - Includes: thumbnail grid preview, download link (if applicable)

**SMS (P3 — Twilio, opt-in):**
- Delivery confirmation to receiver's mobile
- Upload failure alert to sender if upload stalls > 30 min

### Error Messages — Human-First Copy

```
❌ "IMG_4521.CR3 couldn't upload — file may be corrupted. Tap to retry."
❌ "Lost connection during upload. Your progress is saved — tap to resume."
❌ "Unsupported format: .x3f — Sigma RAW is not yet supported."
⚠️ "Slow connection detected. Upload will continue in the background."
✅ "12 photos delivered to desk@publication.com"
```

All errors log to server `ErrorLog` table (existing schema) with `source: 'photo-pipeline'`.

---

## 7. Server Layer

### 7.1 Catch Server Design

> **Decision:** Authenticated ingest endpoint + scoped download access.
> Minimal server overhead — no rendering, no transcoding.
> Receives bytes → writes to storage → queues post-processing jobs.

The catch server can be:
- A lightweight Fastify service on a VPS (DigitalOcean, Hetzner) — cheapest
- A separate Render service from the video backend
- Serverless (Cloudflare Workers + R2) — no server to maintain

Authentication: existing Fixer JWT (phone/PIN/org). The upload endpoint validates token + org scope but
otherwise does minimal work. All heavy processing (exiftool, Sharp) is queued.

### 7.2 Routes (`server/src/routes/photos.js`)

```
POST   /api/photos/projects              Create project
GET    /api/photos/projects              List (user scope)
GET    /api/photos/projects/:id          Detail + photo list
PATCH  /api/photos/projects/:id          Update title/notes
DELETE /api/photos/projects/:id          Soft delete

POST   /api/photos/upload                Per-photo multipart upload
POST   /api/photos/upload/batch          Zip/tar batch upload (P2 experiment)
GET    /api/photos/:id/download/original Stream original bytes (auth + org scoped)
GET    /api/photos/:id/download/tagged   Stream exiftool-processed copy (auth + org scoped)
GET    /api/photos/:id/thumbnail         800px JPEG thumbnail (auth + org scoped)
PATCH  /api/photos/:id/sidecar           Update sidecar (re-triggers exiftool job)

GET    /api/admin/photos/projects        ADMIN: own org only
GET    /api/admin/photos/projects/all    SUPER_ADMIN only (optional post-demo)
```

### 7.2A Access Policy — Org Scoping

| Role | Allowed scope |
|------|----------------|
| `USER` | Own projects/photos only (`userId === request.user.id`) |
| `ADMIN` | Any project/photo where `orgCode === request.user.companyCode` |
| `SUPER_ADMIN` | All orgs (not required for demo; future toggle) |

Non-negotiable rules:

- Admin org scope is enforced server-side, never from client query params.
- Cross-org resource IDs return 404 (not 403) to avoid data enumeration.
- Download links are either authenticated route access or short-lived signed URLs.

### 7.3 Upload Handler — Zero Buffering

```js
let storageKey = null;
let sidecar = null;
let fileCount = 0;

for await (const part of req.parts()) {
  if (part.type === 'file' && part.fieldname === 'file') {
    fileCount += 1;
    if (fileCount > 1) return reply.code(400).send({ error: 'Exactly one file part is required' });

    // Pipe directly to storage — never buffer an 80MB RAW file in memory
    const safeName = sanitizeFilename(part.filename);
| `READY_PENDING_NOTIFY` | "✅ Processed · sending notifications" | — |
| `READY` | "✅ Delivered · ready in Lightroom" | Email: "Your photos are ready" |
    const sniff = await sniffFileHeader(part.file); // magic-byte detection
    if (!isAllowedFormat(ext, sniff)) {
      return reply.code(415).send({ error: 'Unsupported or mismatched file format' });
    }

    storageKey = buildKey(projectId, photoId, safeName);
    await storage.writeStream(storageKey, part.file);
  } else if (part.fieldname === 'sidecar') {
    sidecar = JSON.parse(await part.toBuffer()); // JSON is small — OK to buffer
  }
}

if (!storageKey || !sidecar) {
  return reply.code(400).send({ error: 'file and sidecar are both required' });
}

// Queue async jobs — return 202 immediately
await jobQueue.add('process-photo', { photoId, storageKey, sidecar, orgCode, idempotencyKey });
reply.code(202).send({ photoId, status: 'PROCESSING' });
```

### 7.4 Hybrid Metadata Processing (`jobs/process-photo.js`)

This is the core post-upload job:

```js
import { exiftool } from 'exiftool-vendored';

async function processPhoto({ photoId, storageKey, sidecar }) {
  const localPath = await storage.download(storageKey);
  const isRAW = RAW_EXTENSIONS.has(path.extname(storageKey).slice(1).toLowerCase());

  if (isRAW) {
    // Write XMP sidecar — Lightroom standard for RAW
    const xmpPath = localPath.replace(/\.[^.]+$/, '.xmp');
    await exiftool.write(xmpPath, buildXMPFields(sidecar), ['-xmp:all=']);
    await storage.upload(xmpKey(storageKey), xmpPath);
  } else {
    // Embed IPTC into file copy — Lightroom reads embedded for JPEG/TIFF/HEIC
    const taggedPath = localPath + '.tagged' + path.extname(localPath);
    await fs.copyFile(localPath, taggedPath);
    await exiftool.write(taggedPath, buildIPTCFields(sidecar));
    await storage.upload(taggedKey(storageKey), taggedPath);
  }

  // Generate thumbnail — also validates file integrity (Sharp will throw on corrupt files)
  const thumb = await sharp(localPath).resize(800).jpeg({ quality: 85 }).toBuffer();
  await storage.upload(thumbKey(storageKey), thumb);

  await db.photo.update({ where: { id: photoId }, data: { status: 'READY_PENDING_NOTIFY' } });
  await notifyDelivery(photoId); // email sender + receiver (outbox + retries)
  await db.photo.update({ where: { id: photoId }, data: { status: 'READY' } });
}

function buildXMPFields(sidecar) {
  return {
    'XMP:Description':      sidecar.caption,
    'XMP:Title':            sidecar.headline,
    'XMP:Creator':          sidecar.byline,
    'XMP:Rights':           sidecar.copyright,
    'XMP:Subject':          sidecar.keywords,
    'XMP:City':             sidecar.city,
    'XMP:State':            sidecar.stateProvince,
    'XMP:Country':          sidecar.country,
    'EXIF:DateTimeOriginal': formatExifDate(sidecar.dateCaptured),
    'EXIF:GPSLatitude':     sidecar.gpsLatitude,
    'EXIF:GPSLongitude':    sidecar.gpsLongitude,
  };
}
```

### 7.5 Storage Layout

```
/storage/{orgCode}/{projectId}/
  manifest.json                 ← project title, createdAt, photo list
  {photoId}/
    original.cr3                ← exact uploaded bytes (never modified)
    original.xmp                ← Lightroom XMP sidecar (RAW only)
    tagged.jpg                  ← IPTC-embedded copy (JPEG/TIFF/HEIC only)
    thumb.jpg                   ← 800px JPEG preview
    sidecar.json                ← raw PhotoSidecar JSON (source of truth)
```

**Storage adapter** (`STORAGE_DRIVER` env var):

| Driver | Use case |
|--------|----------|
| `local` | Dev / self-hosted on same machine |
| `s3` | AWS S3 or Backblaze B2 |
| `r2` | Cloudflare R2 — no egress fees |
| `minio` | Self-hosted S3-compatible |

### 7.6 Format Allowlist

```js
const ALLOWED_EXTENSIONS = new Set([
  'jpg','jpeg','heic','heif','tif','tiff',
  'dng','cr2','cr3','arw','nef','orf','raf','rw2','pef','srw','png'
]);
const RAW_EXTENSIONS = new Set([
  'cr2','cr3','arw','nef','orf','raf','rw2','pef','srw','dng'
]);
// Extension guides expected family; magic-byte sniffing is enforcement.
```

### 7.7 Security Contract (Demo-Appropriate)

Minimum contract to implement before launch:

1. Auth model: phone+PIN+org JWT, validated on every photo route.
2. Org scope: all admin list/detail/download routes filtered by `request.user.companyCode`.
3. Least privilege:
  - No anonymous upload/download endpoints.
  - Admin cannot access cross-org IDs.
4. Download safety:
  - Option A: authenticated API streaming
  - Option B: signed URLs with short TTL (5-15 min)
5. Abuse controls:
  - Per-user and per-org upload rate limits
  - Per-file max size and max files per project
6. Audit logging:
  - Record userId, companyCode, projectId, photoId, action, requestId, IP.

### 7.8 Validation Contract (File + Metadata)

1. Validate extension allowlist and file signature (magic bytes).
2. Reject extension/signature mismatch.
3. Sidecar schema validation with limits:
  - max caption length
  - max keyword count
  - max keyword length
  - coordinate bounds
4. Normalize strings (trim, control-char stripping).
5. Preserve original bytes exactly; all writes happen to derivative files (`.xmp`, `tagged.*`, `thumb.jpg`).

### 7.9 Reliability Contract (Idempotency + Delivery)

1. Idempotency key per upload (`X-Upload-Id`) to prevent duplicate processing.
2. Optional checksum (`X-File-SHA256`) for integrity verification.
3. Queue retry policy + dead-letter queue for failed processing jobs.
4. Notification outbox table with retries/backoff.
5. `deliveryStatus` is independent from technical processing state.

---

## 8. Prisma Schema Additions

```prisma
model PhotoProject {
  id           String             @id @default(uuid())
  userId       String             @map("user_id")
  orgCode      String             @map("org_code")
  title        String
  notes        String?
  destEmail    String?            @map("destination_email")
  status       PhotoProjectStatus @default(DRAFT)
  deliveryStatus DeliveryStatus   @default(PENDING) @map("delivery_status")
  photoCount   Int                @default(0) @map("photo_count")
  expiresAt    DateTime?          @map("expires_at") // 7-day draft TTL
  createdAt    DateTime           @default(now()) @map("created_at")
  updatedAt    DateTime           @updatedAt @map("updated_at")
  deletedAt    DateTime?          @map("deleted_at")
  user         User               @relation(fields: [userId], references: [id])
  photos       Photo[]
  @@index([userId])
  @@index([orgCode, createdAt])
  @@map("photo_projects")
}

enum PhotoProjectStatus {
  DRAFT UPLOADING PROCESSING READY_PENDING_NOTIFY READY PARTIAL FAILED ARCHIVED
}

enum DeliveryStatus {
  PENDING NOTIFIED FAILED
}

model Photo {
  id               String      @id @default(uuid())
  projectId        String      @map("project_id")
  photoIndex       Int         @map("photo_index")
  originalFileName String      @map("original_file_name")
  originalUTI      String?     @map("original_uti")
  isRaw            Boolean     @default(false) @map("is_raw")
  fileSize         BigInt?     @map("file_size_bytes")
  storageKey       String?     @map("storage_key")
  xmpKey           String?     @map("xmp_key")       // RAW: XMP sidecar path
  taggedKey        String?     @map("tagged_key")    // JPEG/TIFF: embedded copy
  thumbnailKey     String?     @map("thumbnail_key")
  sidecar          Json?                             // PhotoSidecar JSONB
  status           PhotoStatus @default(UPLOADING)
  errorMessage     String?     @map("error_message")
  createdAt        DateTime    @default(now()) @map("created_at")
  updatedAt        DateTime    @updatedAt @map("updated_at")
  project          PhotoProject @relation(fields: [projectId], references: [id], onDelete: Cascade)
  @@index([projectId])
  @@map("photos")
}

enum PhotoStatus { UPLOADING PROCESSING READY_PENDING_NOTIFY READY ERROR }
```

---

## 9. RAW Preview on iOS

iOS 14.3+ natively renders RAW files via `AVFoundation` / `CoreImage`:

```swift
// Generate a quick preview thumbnail from RAW — no pixel decoding needed
let options = [kCGImageSourceThumbnailMaxPixelSize: 400,
               kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary
if let source = CGImageSourceCreateWithURL(rawURL as CFURL, nil),
   let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
    let preview = UIImage(cgImage: cgImage)
}
```

**Future feature (post-core):** RAW → JPEG export with size presets:

| Preset | Long edge | Target use |
|--------|-----------|------------|
| SM | 1200px | Web / social |
| MD | 2400px | Email / proof |
| LG | 4800px | Print-ready proof |
| XL | Full res | Archive quality JPEG |

User picks preset before export. Conversion runs on-device via `CIFilter` + `CIRAWFilter`.
**This is deferred to post-P3.**

---

## 10. Slack Integration (Socketed)

The delivery notification system is built with a pluggable notifier interface.
Slack is socketed in — implementation left to the user to connect their own workspace:

```js
// server/src/lib/notifiers/index.js
const notifiers = [
  new EmailNotifier(),          // P1 — transactional email provider
  new SMSNotifier(),            // P3 — Twilio (opt-in)
  new SlackNotifier(),          // P4 — user provides Bot Token + Channel ID
];

async function notifyDelivery(project, photos) {
  await Promise.allSettled(notifiers.map(n => n.onProjectReady(project, photos)));
}
```

Slack notifier sends a message with thumbnail grid to the configured channel.
User connects it by adding `SLACK_BOT_TOKEN` and `SLACK_PHOTO_CHANNEL` env vars.

---

## 11. Admin UI — Separate Photo Section

> **Decision:** Photos get a clean, dedicated admin UI — completely separate
> from the video asset table.

Admin dashboard additions:
- `/admin/photos` — project list, ADMIN sees own org only (SUPER_ADMIN all orgs optional)
- `/admin/photos/:id` — project gallery view (thumbnail grid), metadata panel
- Download buttons: original / tagged / XMP sidecar per photo
- Status badges: DRAFT / PROCESSING / READY_PENDING_NOTIFY / READY / ERROR
- Re-trigger exiftool job button (for fixing metadata after the fact)

---

## 12. Phase Breakdown

### P1 — Core Pipeline

- [ ] Keep existing phoneNumber + pin + org auth for all photo routes
- [ ] Enforce ADMIN org scoping on photo admin routes and downloads
- [ ] Implement Security Contract (§7.7)
- [ ] Implement Validation Contract (§7.8)
- [ ] Implement Reliability Contract (§7.9)
- [ ] `PhotoFormatResolver.swift`
- [ ] `PhotoSidecar.swift` + `ImageIO` extraction
- [ ] `PhotoProject.swift` models + 7-day expiry logic
- [ ] `PhotoProjectStore.swift` (`@Observable`)
- [ ] `PhotoUploadService.swift` (per-photo multipart, 3 concurrent, background, resume)
- [ ] `PhotosView.swift` — replace placeholder with project list
- [ ] Server: `routes/photos.js`, `lib/photoStorage.js`, `lib/photoValidation.js`
- [ ] Server: `jobs/process-photo.js` — exiftool XMP + IPTC + thumbnail
- [ ] Server: `lib/notifiers/EmailNotifier.js`
- [ ] Prisma schema + migration
- [ ] Error messaging copy (all states)

### P2 — Full Grouping UI

- [ ] `PhotoPickerView.swift` (PHPickerViewController wrapper)
- [ ] `PhotoProjectListView.swift`
- [ ] `PhotoProjectDetailView.swift` + photo grid
- [ ] `PhotoGridCell.swift` + status overlay
- [ ] Upload progress HUD

### P3 — Metadata Editor + SMS

- [ ] `PhotoMetadataEditorView.swift`
- [ ] `PhotoDetailView.swift` (full-screen preview)
- [ ] `CLGeocoder` reverse geocoding
- [ ] Keyword chip input
- [ ] Twilio SMS notifier (opt-in)

### P4 — Batch Upload + Admin UI + Slack

- [ ] Zip/tar batch upload endpoint + iOS client
- [ ] Admin photo section (`/admin/photos`)
- [ ] SlackNotifier (socketed, user-configured)

### P5 — S3 Storage + RAW Export

- [ ] `S3StorageAdapter` + R2 + MinIO options
- [ ] RAW → JPEG export with size presets (SM/MD/LG/XL)

---

## 13. Design Decision Log
| Decision | Choice | Rationale |
|---|---|---|
| End destination | Adobe Lightroom | XMP sidecars for RAW; embedded IPTC for JPEG/TIFF |
| Metadata write | Hybrid: server exiftool | Original untouched in transit; server bakes metadata post-arrival |
| RAW metadata | `.xmp` sidecar | Lightroom standard — it writes .xmp, so we write .xmp |
| JPEG/TIFF metadata | Embedded via exiftool | Lightroom reads embedded; no sidecar needed |
| Auth | Phone number + PIN + org code (demo) | Reuses current Fixer login model and minimizes migration risk |
| UX flow | Name project → pick photos | Project is the umbrella; photos live under it |
| Upload mode | Per-photo multipart (P1), zip batch (P4 experiment) | Per-photo allows granular retry; zip tested for reliability later |
| Thumbnails | Server-side Sharp, async | Validates file integrity; no battery hit on device |
| Draft TTL | 7 days auto-delete | Prevents stale drafts accumulating on device |
| Admin scope | Org-scoped by `companyCode` | Prevents cross-org access in demo and enterprise |
| Delivery semantics | Technical status + delivery status | Avoids showing "Delivered" before notifications actually succeed |
| Slack | Socketed notifier | User connects their own workspace; not a P1 dependency |
| Org quotas | Skipped | Handled by customer's own storage capacity |
| Admin UI | Separate from video | Photos deserve clean dedicated UX |
| RAW preview iOS | `CGImageSourceCreateThumbnailAtIndex` | Native, fast, no pixel decode |

---

## 14. What This Does NOT Touch

- Existing video pipeline (Mux, WebSocket, `ChatViewModel`, `Asset`/`Clip` tables)
- Existing phone/PIN auth for the video app
- `PhotosView.swift` is the only existing iOS file replaced

---

## 15. EXIF/IPTC Foundation (Practical Truth)

### 15.1 What metadata exists and where it lives

Think of three layers:

1. EXIF: camera/capture metadata (date/time, camera model, lens, exposure, GPS).
2. IPTC: editorial metadata (caption, headline, keywords, copyright, credit, location).
3. XMP: modern metadata container Adobe tools use; can carry IPTC and custom fields.

### 15.2 By file type

| File type | Can contain EXIF | Can contain IPTC/XMP embedded | Best practice for this plan |
|-----------|------------------|-------------------------------|-----------------------------|
| RAW (`.cr3`, `.nef`, `.arw`, etc.) | Yes (camera writes) | Sometimes readable, but direct writes are risky/inconsistent | Keep original untouched; write `.xmp` sidecar |
| JPEG | Yes | Yes | Embed IPTC/XMP into tagged copy |
| TIFF | Yes | Yes | Embed IPTC/XMP into tagged copy |
| HEIC | Yes | Limited/varies by ecosystem | Embed where supported, keep sidecar JSON as source of truth |

### 15.3 What can be added safely

- RAW: add editorial metadata via `.xmp` sidecar.
- JPEG/TIFF: add IPTC/XMP into file copy (`tagged.*`), preserve original.
- EXIF capture fields should usually be preserved; only allow controlled overrides (date/GPS correction) with audit trail.

### 15.4 How to read metadata without heavy coding

Use `exiftool` from terminal:

```bash
# All metadata, grouped, readable
exiftool -a -G1 -s /path/to/file.CR3

# Focused capture + editorial fields
exiftool -DateTimeOriginal -Make -Model -LensModel -ISO -ShutterSpeed -Aperture \
  -GPSLatitude -GPSLongitude -Headline -Caption-Abstract -Keywords -Copyright \
  /path/to/file.jpg

# Show XMP sidecar values
exiftool -a -G1 -s /path/to/file.xmp

# Compare original vs tagged output quickly
exiftool -a -G1 -s original.jpg > original.meta.txt
exiftool -a -G1 -s tagged.jpg > tagged.meta.txt
diff -u original.meta.txt tagged.meta.txt
```

No-code/low-code inspection options:

- Lightroom Classic Metadata panel (best practical view for editorial workflow).
- macOS Finder/Preview Inspector (basic EXIF only, limited IPTC visibility).
- ExifTool GUI wrappers if preferred, while keeping ExifTool as ground truth.

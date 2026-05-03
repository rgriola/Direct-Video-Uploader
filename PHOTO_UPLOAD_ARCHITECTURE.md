# Photo-Fixer — Upload Pipeline Architecture
- May 3 2026
- NOTES for me. I need to consider the upload feature, sidecars + interaction with Lightroom + Classic. Also a way to manage LR Classic catalogs + thumbnails ie; Are catalogs connected by year? Month? Can the dashboard using Adobe Extensions auto create and connect catalogs so search works across all the catalogs.  Also how can an AI implimentation on the Photo Dash assist search, vetting and scanning photos, using LR Facial Recognition, can this be done? Is this complicated?  Is there a way to make the upload process TEXT to Number > Dumps on Server (original Fixer idea for video). 



> **Product identity:** Photo-Fixer is an **organize → transport → deliver** app.
> The end destination is **Adobe Lightroom**. Every architectural decision must ask:
> "Will this photo land in Lightroom ready to catalog with correct metadata?"
>
> Status: Design phase — no implementation yet.
> Last updated: May 1, 2026

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

## 2. Authentication — Supabase Email Auth

Replace the phone/PIN model for Photo-Fixer with **Supabase email auth**:

- Simpler onboarding — email + password, magic link option
- Supabase handles JWTs, refresh tokens, password reset emails
- Row-level security ties projects to `auth.uid()`
- Pairs naturally with the email notification system (§6)
- Optional: SMS via Twilio for delivery confirmations (extra service, not P1)

> The existing video pipeline's phone/PIN auth is left untouched.
> Photo-Fixer can share the same Supabase project or run independently.

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
                        ▼ HTTPS (write-only public endpoint)
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
| `READY` | "✅ Delivered · ready in Lightroom" | Email: "Your photos are ready" |
| `PARTIAL` | "⚠️ 2 of 12 failed — tap to retry" | — |
| `FAILED` | "❌ Upload failed — [reason]" | — |

### Notification Channels

**Email (P1 — Supabase transactional email):**
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

> **Decision:** Write-only public endpoint on a protected IP.
> Minimal server overhead — no rendering, no transcoding.
> Receives bytes → writes to storage → queues post-processing jobs.

The catch server can be:
- A lightweight Fastify service on a VPS (DigitalOcean, Hetzner) — cheapest
- A separate Render service from the video backend
- Serverless (Cloudflare Workers + R2) — no server to maintain

Authentication: JWT from Supabase. The upload endpoint validates the token but
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
GET    /api/photos/:id/download/original Stream original bytes
GET    /api/photos/:id/download/tagged   Stream exiftool-processed copy
GET    /api/photos/:id/thumbnail         800px JPEG thumbnail
PATCH  /api/photos/:id/sidecar           Update sidecar (re-triggers exiftool job)

GET    /api/admin/photos/projects        All orgs — separate admin section
```

### 7.3 Upload Handler — Zero Buffering

```js
for await (const part of req.parts()) {
  if (part.type === 'file' && part.fieldname === 'file') {
    // Pipe directly to storage — never buffer an 80MB RAW file in memory
    const key = buildKey(projectId, photoId, part.filename);
    await storage.writeStream(key, part.file);
  } else if (part.fieldname === 'sidecar') {
    sidecar = JSON.parse(await part.toBuffer()); // JSON is small — OK to buffer
  }
}
// Queue async jobs — return 202 immediately
await jobQueue.add('process-photo', { photoId, key, sidecar });
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

  await db.photo.update({ where: { id: photoId }, data: { status: 'READY' } });
  await notifyDelivery(photoId); // email sender + receiver
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
// Extension is ground truth — MIME type is unreliable for RAW formats
```

---

## 8. Prisma Schema Additions

```prisma
model PhotoProject {
  id           String             @id @default(uuid())
  userId       String             @map("user_id")
  title        String
  notes        String?
  destEmail    String?            @map("destination_email")
  status       PhotoProjectStatus @default(DRAFT)
  photoCount   Int                @default(0) @map("photo_count")
  expiresAt    DateTime?          @map("expires_at") // 7-day draft TTL
  createdAt    DateTime           @default(now()) @map("created_at")
  updatedAt    DateTime           @updatedAt @map("updated_at")
  deletedAt    DateTime?          @map("deleted_at")
  user         User               @relation(fields: [userId], references: [id])
  photos       Photo[]
  @@index([userId])
  @@map("photo_projects")
}

enum PhotoProjectStatus {
  DRAFT UPLOADING PROCESSING READY PARTIAL FAILED ARCHIVED
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

enum PhotoStatus { UPLOADING PROCESSING READY ERROR }
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
  new EmailNotifier(),          // P1 — Supabase transactional email
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
- `/admin/photos` — project list, all orgs, searchable by title / sender / date
- `/admin/photos/:id` — project gallery view (thumbnail grid), metadata panel
- Download buttons: original / tagged / XMP sidecar per photo
- Status badges: DRAFT / PROCESSING / READY / ERROR
- Re-trigger exiftool job button (for fixing metadata after the fact)

---

## 12. Phase Breakdown

### P1 — Core Pipeline

- [ ] Supabase auth integration (email)
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
| Auth | Supabase email | Simpler for photo users vs. phone/PIN; transactional email built-in |
| UX flow | Name project → pick photos | Project is the umbrella; photos live under it |
| Upload mode | Per-photo multipart (P1), zip batch (P4 experiment) | Per-photo allows granular retry; zip tested for reliability later |
| Thumbnails | Server-side Sharp, async | Validates file integrity; no battery hit on device |
| Draft TTL | 7 days auto-delete | Prevents stale drafts accumulating on device |
| Slack | Socketed notifier | User connects their own workspace; not a P1 dependency |
| Org quotas | Skipped | Handled by customer's own storage capacity |
| Admin UI | Separate from video | Photos deserve clean dedicated UX |
| RAW preview iOS | `CGImageSourceCreateThumbnailAtIndex` | Native, fast, no pixel decode |

---

## 14. What This Does NOT Touch

- Existing video pipeline (Mux, WebSocket, `ChatViewModel`, `Asset`/`Clip` tables)
- Existing phone/PIN auth for the video app
- `PhotosView.swift` is the only existing iOS file replaced

# Video Production Feature Ideas

Future features for the Fixer ecosystem — ideas that extend the upload pipeline into broader production workflows.

---

## Build on What We Have

### 1. Auto-Transcription + Shot Log
Apple's on-device `Speech` framework transcribes audio in real-time or post-capture. Generate a searchable text log per clip. Producers search "earthquake" and find the clip instantly instead of scrubbing hours of footage. 

### 2. GPS Shot Map
Render a map view in the dashboard showing where every clip was shot — pin drops with thumbnails. For breaking news with 5 field crews, a producer instantly sees geographic coverage gaps.

### 3. Auto-Slate / Smart Metadata
Digital slate for each clip: timestamp, GPS, crew name, camera, story slug — all embedded in file metadata and pushed to Mediasource. Replaces physical slates and manual logging.

### 4. Proxy Generation on iOS
After uploading full-res, generate a lightweight proxy (720p H.264) on-device and push to a shared channel. Producers review proxies on their phones immediately while full-res processes. Like Apple's ProRes Proxy workflow, automated.

### 5. Live Shot Checklist
Before a live hit, the app walks the crew through: signal strength, battery, audio check, framing preview, IFB status. Each item gets ✅. The producer sees checklist status remotely on the dashboard.

---

## Bigger Swings

### 6. AI Scene Detection + Auto-Clip
Apple Vision framework detects scene changes, faces, text on screen. Auto-segment a 30-minute shoot into individual clips by scene. Tag each: "standup", "b-roll traffic", "interview male."

### 7. Field-to-Edit Bridge
Producer marks selects in the dashboard (in/out points on proxies). EDL markers sync to editor's NLE (Premiere/Avid) referencing full-res files. Zero re-logging.

### 8. Real-Time Bandwidth Dashboard
For the Mac streaming app — live network dashboard: per-path throughput, packet loss, signal strength per modem. A health monitor for upload connections. Desk knows before connection fails.

### 9. Collaborative Annotation
Producers annotate clips in the dashboard (draw on frames, notes at timecodes). Annotations sync to the field crew's app. "Re-shoot this — sign is out of frame." Two-way creative feedback.

### 10. Return Video to Field
Reverse the pipeline: desk sends a clip back to field crew's iPhone for review before air. Same WebSocket + chunk infrastructure, opposite direction.

---

## Priority Recommendations

**Start with:** #1 (transcription) + #2 (GPS map) — high value, use existing data, minimal new infrastructure.

**Next tier:** #4 (proxies) + #7 (field-to-edit bridge) — these connect the upload pipeline to the editing workflow.

---

## Server-to-Premiere Connection

### How Remote Media Connects to Adobe Premiere

Premiere doesn't stream from URLs — it needs file paths. Remote assets connect through one of these methods:

**Method 1: Premiere Panel Extension (what Mediasource likely does)**
- Build a CEP/UXP panel extension (HTML/JS/CSS) that runs inside Premiere
- Panel connects to server API, shows assets with thumbnails + metadata + search
- Editor clicks "Import" → panel downloads proxy to local cache → links in Premiere project
- For final edit (online), panel relinks proxy paths to full-res paths

```
Fixer Server API → Premiere Panel → Local Proxy Cache → Timeline
                                          ↓ (relink for finish)
                                     Full-Res on Server
```

**Method 2: Mounted Network Storage**
- Media lives on a NAS/SAN (shared storage)
- Editor's machine mounts the share (SMB/NFS)
- Premiere project references mounted paths (e.g., `/Volumes/MediaStore/clip001.mxf`)
- No download needed — Premiere reads directly from the mount

**Method 3: Project Sheet → Premiere Project File**
- Generate a `.prproj` file (XML-based) programmatically from the server
- The project file references media paths on shared storage
- Editor opens the generated project — all clips are already linked with metadata (bins, markers, labels)
- This is the "Project Sheet" workflow — the slug form data maps to Premiere bins and clip metadata

### What Fixer Could Do

Build a **Fixer Premiere Panel**:

1. **Search & Browse** — Panel shows all Fixer uploads with thumbnails, metadata, slug, status
2. **Import to Project** — Downloads proxy to local cache, creates Premiere bin with metadata
3. **Project Sheet** — Generate a Premiere project from the slug form: bins organized by story, clips labeled with type/priority/description
4. **Relink for Online** — When edit is complete, panel relinks proxies to full-res server paths
5. **Publish Back** — Export finished sequence metadata back to Fixer/Mediasource

### Tech for the Panel

| Component | Technology |
|---|---|
| **Panel framework** | Adobe UXP (modern) or CEP (legacy, more docs) |
| **Panel UI** | HTML + CSS + JavaScript (runs in Chromium inside Premiere) |
| **Premiere API** | ExtendScript (JSX) for project manipulation — import clips, create bins, set metadata |
| **Server connection** | Fetch API → Fixer server REST endpoints |
| **Proxy cache** | Download to `~/Library/Application Support/Fixer/proxies/` |
| **Project generation** | Server-side: build `.prproj` XML from asset database |

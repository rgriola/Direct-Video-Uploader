# Fixer Live Streaming — Full Plan

> **Status:** Draft — April 30, 2026
> **Builds on:** [EXTERNAL_CAMERA_PLAN.md](./EXTERNAL_CAMERA_PLAN.md), [MAC_STREAMING_APP_STACK.md](./MAC_STREAMING_APP_STACK.md)

Live video contribution from iPhone to TV station with low-latency SDI/HDMI output. A LiveU/TVU/Dejero replacement built on Fixer's existing infrastructure.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  FIELD (iPhone)                                                     │
│                                                                     │
│  AVCaptureSession → VideoToolbox H.264 → SRT (libsrt / HaishinKit) │
│       ↓                                                             │
│  Audio Source Picker ──→ Audio Metering (VU)                        │
│  (built-in / headset / USB mic)                                     │
└────────────────────────────┬────────────────────────────────────────┘
                             │  SRT over public internet
                             │  (encrypted, ARQ error recovery)
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STATION SERVER (on-prem or cloud at TV station)                    │
│                                                                     │
│  SRT Listener ──→ Decode ──→ WebSocket preview to Dashboard        │
│       │                                                             │
│       └──→ Stats: bitrate, RTT, packet loss, audio levels          │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STATION OUTPUT (Mac app)                                           │
│                                                                     │
│  SRT Decode → CVPixelBuffer → Blackmagic DeckLink SDK → SDI out    │
│                             → or HDMI via Elgato/AJA               │
│                                                                     │
│  Dashboard: live preview, audio meters, tally, routing controls     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Protocol Choice: SRT

| Factor | SRT | RTMP | WebRTC |
|--------|-----|------|--------|
| **Latency** | 200ms–2s (configurable) | 2–5s | <500ms |
| **Packet loss recovery** | ARQ built-in | None (TCP retransmit) | NACK + FEC |
| **Encryption** | AES-128/256 native | TLS wrapper | DTLS/SRTP |
| **Firewall traversal** | Rendezvous mode | Easy (port 1935) | STUN/TURN needed |
| **Broadcast adoption** | Industry standard (Haivision) | Legacy, being deprecated | Not broadcast standard |
| **iOS library** | HaishinKit.swift (mature) | HaishinKit.swift | WebRTC.framework |
| **SDI decode ecosystem** | Haivision, AJA, Magewell, software | FFmpeg only | None native |

**SRT wins** for this use case — it's the broadcast industry standard for contribution feeds, handles lossy cellular networks gracefully, and has a direct path to SDI output via hardware decoders or the DeckLink SDK.

---

## Component 1: iOS Live Streaming Module

### 1.1 Camera Capture

Build on the existing `AVCaptureSession` approach from [CAMERA_UPLOAD_PLAN.md](./CAMERA_UPLOAD_PLAN.md).

```swift
// Capture pipeline
let session = AVCaptureSession()
session.sessionPreset = .hd1920x1080  // sub-4K, broadcast standard

// Video input
let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
let videoInput = try AVCaptureDeviceInput(device: camera!)
session.addInput(videoInput)

// Video output → raw sample buffers for encoding
let videoOutput = AVCaptureVideoDataOutput()
videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
session.addOutput(videoOutput)
```

### 1.2 Quality Presets (Sub-4K)

| Preset | Resolution | FPS | Bitrate | Use Case |
|--------|-----------|-----|---------|----------|
| **HD Standard** | 1920×1080 | 30 | 5 Mbps | Default — clean, reliable |
| **HD High** | 1920×1080 | 60 | 8 Mbps | Sports, fast action |
| **720p Safe** | 1280×720 | 30 | 2.5 Mbps | Poor network, backup |
| **720p60** | 1280×720 | 60 | 4 Mbps | Action + constrained bandwidth |

Codec: **H.264** (not H.265) for live — wider decoder compatibility at the station, lower encode latency. H.265 can be a future toggle for bandwidth-constrained scenarios.

Adaptive bitrate: monitor SRT stats (RTT, loss rate), drop to lower preset automatically when network degrades.

### 1.3 Audio Source Selection

Enumerate all available inputs and present a picker in the streaming UI:

```swift
let audioSession = AVAudioSession.sharedInstance()
try audioSession.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
try audioSession.setActive(true)

// Enumerate available sources
let inputs = audioSession.availableInputs ?? []
// Returns: .builtInMic, .headsetMic, .usbAudio, .bluetoothHFP, etc.

// User selects source → apply
try audioSession.setPreferredInput(selectedInput)
```

**Supported sources:**

| Source | Port Type | Notes |
|--------|-----------|-------|
| iPhone mic | `.builtInMic` | Default, always available |
| Wired headset mic | `.headsetMic` | Lightning/USB-C headphones with mic |
| USB microphone | `.usbAudio` | USB-C audio interfaces, Rode, Shure |
| Bluetooth | `.bluetoothHFP` | AirPods, etc. — higher latency, avoid for broadcast |

Monitor `AVAudioSession.routeChangeNotification` for hot-plug events (user connects/disconnects a mic mid-stream).

### 1.4 Audio Meters

Real-time VU metering from the capture pipeline:

```swift
// In AVCaptureAudioDataOutput delegate
func captureOutput(_ output: AVCaptureOutput,
                   didOutput sampleBuffer: CMSampleBuffer,
                   from connection: AVCaptureConnection) {

    var audioBufferList = AudioBufferList()
    var blockBuffer: CMBlockBuffer?

    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, bufferListSizeNeededOut: nil,
        bufferListOut: &audioBufferList,
        bufferSize: MemoryLayout<AudioBufferList>.size,
        blockBufferAllocator: nil, blockBufferOut: &blockBuffer,
        flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment)
    )

    let abl = UnsafeMutableAudioBufferListPointer(&audioBufferList)
    for buffer in abl {
        guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size

        var sum: Float = 0
        var peak: Float = 0
        for i in 0..<count {
            let abs = Swift.abs(samples[i])
            sum += samples[i] * samples[i]
            if abs > peak { peak = abs }
        }

        let rms = sqrt(sum / Float(count))
        let dbRMS  = 20 * log10(rms + .ulpOfOne)   // average level
        let dbPeak = 20 * log10(peak + .ulpOfOne)   // peak level

        DispatchQueue.main.async {
            self.audioMeterRMS = dbRMS    // drive green bar
            self.audioMeterPeak = dbPeak  // drive peak indicator
        }
    }
}
```

**UI:** Vertical VU meter bar (green → yellow → red) with peak hold indicator. Standard broadcast-style meter showing dBFS. Visible at all times during live stream.

### 1.5 SRT Transport (HaishinKit)

```swift
import HaishinKit

let connection = SRTConnection()
let stream = SRTStream(connection: connection)

// Attach capture devices
stream.attachCamera(selectedCamera) { error in /* handle */ }
stream.attachAudio(AVCaptureDevice.default(for: .audio)) { error in /* handle */ }

// Connect to station server
// URL format: srt://station-ip:port?mode=caller&latency=500000&passphrase=secret
connection.connect(stationURL)

// Start publishing
stream.publish()
```

**Configuration exposed to user:**
- Server URL (admin-configurable or manual entry)
- Stream key / passphrase (AES-256 encryption)
- Latency buffer (200ms–2000ms slider, default 500ms)

### 1.6 iOS Streaming UI

```
┌──────────────────────────────────┐
│  ● LIVE  00:04:32     🔴 REC    │  ← Status bar: live indicator, duration, record toggle
│                                  │
│                                  │
│      [ Camera Preview ]          │  ← Full-screen live preview
│                                  │
│                                  │
│  ┃█████████░░░░┃ -12dB          │  ← Audio VU meter (horizontal)
│                                  │
│  🎤 USB Mic ▼   1080p30   5Mbps │  ← Audio source, quality, bitrate
│                                  │
│  📶 SRT: Connected  RTT: 45ms   │  ← Connection status
│  ↑ 4.8 Mbps   Loss: 0.1%        │  ← Upload speed, packet loss
│                                  │
│  [ GO LIVE ]  /  [ END STREAM ] │  ← Primary action
└──────────────────────────────────┘
```

---

## Component 2: Station Receive Server

### 2.1 Custom URL Configuration

Two configuration paths:

**A. Admin-set (per organization):**
Add to the Organization model:

```prisma
model Organization {
  // ... existing fields
  liveIngestUrl     String?   // e.g., "srt://station.example.com:9000"
  liveIngestKey     String?   // stream key / passphrase
  liveStreamEnabled Boolean   @default(false)
}
```

Admin dashboard → Org Settings → Live Streaming section. When configured, the iOS app auto-populates the server URL for users in that org.

**B. Manual entry:**
User can override or manually enter a receive URL. Useful for freelancers hitting different stations.

### 2.2 SRT Ingest Options

The station has two deployment choices:

**Option A: Software Server (self-hosted)**

A lightweight Node.js or Go service running at the station:

```
SRT Listener (port 9000)
    → FFmpeg decode pipeline
    → WebSocket → Dashboard preview (MJPEG or low-res WebRTC)
    → Raw frames → DeckLink SDK → SDI out
```

Technology: `libsrt` + FFmpeg for decode, or `GStreamer` pipeline.

**Option B: Hardware Decoder (plug-and-play)**

Dedicated hardware at the station — no software to manage:

| Device | Price | Input | Output | Notes |
|--------|-------|-------|--------|-------|
| **Magewell Pro Convert** | ~$500 | SRT/RTMP | SDI or HDMI | Compact, plug-and-play |
| **AJA Bridge Live** | ~$3,000 | SRT/RTMP | SDI + HDMI | Broadcast-grade, metadata pass-through |
| **Haivision Makito X4** | ~$5,000+ | SRT | SDI | Industry standard, lowest latency |

**Recommendation:** Start with **Magewell Pro Convert** for demo/proof-of-concept ($500, zero software). Graduate to software server for multi-feed dashboard + routing features.

### 2.3 Multi-Feed Support

Station may receive from multiple field crews simultaneously:

- Each feed gets a unique SRT StreamID
- Server routes feeds to different SDI outputs or dashboard tiles
- Admin assigns output mapping: "Camera 1 → SDI Out 1", "Camera 2 → SDI Out 2"

---

## Component 3: Station Dashboard

A web-based monitoring and routing interface running at the station.

### 3.1 Dashboard Features

```
┌────────────────────────────────────────────────────────────────────┐
│  FIXER LIVE — Station Dashboard                          [Admin ⚙]│
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ┌─────────────────────┐  ┌─────────────────────┐                 │
│  │ Feed 1: John Smith  │  │ Feed 2: Jane Doe    │                 │
│  │ ┌─────────────────┐ │  │ ┌─────────────────┐ │                 │
│  │ │  Live Preview   │ │  │ │  Live Preview   │ │                 │
│  │ │                 │ │  │ │                 │ │                 │
│  │ └─────────────────┘ │  │ └─────────────────┘ │                 │
│  │ 🔴 LIVE  00:12:45   │  │ 🔴 LIVE  00:03:22   │                 │
│  │ ┃████████░░┃ -14dB  │  │ ┃██████░░░░┃ -18dB  │                 │
│  │ 1080p30  5.1 Mbps   │  │ 720p30   2.8 Mbps   │                 │
│  │ RTT: 52ms  Loss: 0% │  │ RTT: 120ms Loss: 2% │                 │
│  │ → SDI OUT 1  [ROUTE]│  │ → SDI OUT 2  [ROUTE]│                 │
│  └─────────────────────┘  └─────────────────────┘                 │
│                                                                    │
│  ┌──────────────────────────────────────────────┐                 │
│  │ Output Routing                                │                 │
│  │  SDI 1: Feed 1 (John Smith)         [SWAP ↕] │                 │
│  │  SDI 2: Feed 2 (Jane Doe)           [SWAP ↕] │                 │
│  │  SDI 3: — (no feed assigned)        [ASSIGN] │                 │
│  │  HDMI 1: Feed 1 (confidence monitor)[SWAP ↕] │                 │
│  └──────────────────────────────────────────────┘                 │
│                                                                    │
│  Connection Health ──────────────────────────────                  │
│  ▸ Total bandwidth: 7.9 Mbps in                                   │
│  ▸ Active feeds: 2/4                                               │
│  ▸ System: DeckLink Quad 2 — 4× SDI out available                │
└────────────────────────────────────────────────────────────────────┘
```

### 3.2 Dashboard Tech Stack

| Component | Technology |
|-----------|-----------|
| **Frontend** | React (extends existing admin dashboard) or standalone Electron app |
| **Live preview** | Low-latency WebRTC or MJPEG snapshots via WebSocket |
| **SRT stats** | `srt_bistats()` API → WebSocket push to dashboard every 500ms |
| **Audio meters** | Server-side audio level extraction → WebSocket to dashboard |
| **Routing control** | REST API to assign feed → output mapping |
| **Auth** | Same Fixer auth system (org-scoped) |

### 3.3 Tally / Return Communication

- **Tally light:** Dashboard can signal "ON AIR" back to the field iPhone via the existing WebSocket. iPhone shows red tally indicator when their feed is routed to an SDI output.
- **IFB (Interruptible Foldback):** Future — return audio from station to field crew's earpiece. Requires a reverse audio channel (WebRTC ideal for this).

---

## Component 4: SDI / HDMI Output

This is the **critical station-side component** — getting the live feed onto broadcast infrastructure.

### 4.1 Architecture

```
SRT Stream In
    → libsrt receive (SRT Listener mode)
    → FFmpeg or VideoToolbox decode → CVPixelBuffer
    → Blackmagic DeckLink SDK (IDeckLinkOutput) → SDI physical output
    → Station router/switcher picks up SDI signal
    → ON AIR
```

### 4.2 Blackmagic DeckLink Output (Mac App)

A native macOS app running at the station on a Mac with a DeckLink card installed.

**Hardware options:**

| Card | Outputs | Price | Notes |
|------|---------|-------|-------|
| DeckLink Mini Monitor 4K | 1× SDI, 1× HDMI | ~$145 | Single feed, budget option |
| DeckLink Duo 2 | 4× SDI (bi-directional) | ~$345 | 2 feeds out + 2 in |
| DeckLink Quad 2 | 8× SDI (bi-directional) | ~$545 | 4 feeds out, production-grade |
| UltraStudio Monitor 3G | 1× SDI, 1× HDMI (Thunderbolt) | ~$155 | External, no PCIe slot needed |

**Implementation approach:**

1. **Bridging layer** — Objective-C++ wrapper around the DeckLink C++ SDK, exposed to Swift via bridging header
2. **`IDeckLinkOutput`** — Primary interface for pushing video frames to SDI
3. **`CVPixelBuffer` path** — Decode SRT stream → `CVPixelBuffer` → DeckLink's `IDeckLinkMacOutput` for zero-copy transfer via `IOSurface`
4. **Frame scheduling** — Implement `IDeckLinkVideoOutputCallback` to supply frames at the correct cadence (29.97fps / 59.94fps)
5. **Audio embedding** — Decode audio from SRT stream, interleave into SDI output via `IDeckLinkAudioOutput`

### 4.3 HDMI Alternative

For stations without SDI infrastructure or for confidence monitors:

- **Elgato Cam Link** (reverse use) — limited, not designed for output
- **AJA T-TAP Pro** (~$500) — Thunderbolt → HDMI/SDI output, works with DeckLink SDK
- **Blackmagic UltraStudio Monitor** (~$155) — Thunderbolt → SDI + HDMI, cheapest pro option
- **Direct HDMI** — macOS screen mirroring of the dashboard preview window (no special hardware, but adds latency)

### 4.4 Latency Budget

| Segment | Target | Notes |
|---------|--------|-------|
| Camera → encode | <50ms | VideoToolbox hardware encoder |
| SRT transport | 200–500ms | Configurable latency buffer |
| Decode | <30ms | VideoToolbox hardware decoder |
| DeckLink output | <1 frame (~33ms) | Hardware-scheduled |
| **Total glass-to-glass** | **~300ms–600ms** | Competitive with LiveU Solo |

---

## Component 5: Server-Side Integration

### 5.1 Fixer Server Changes

The existing Fixer server orchestrates stream management but does NOT relay video (SRT goes direct from iPhone to station).

```
iPhone ──SRT──→ Station Server (direct, no relay)
   ↕                    ↕
   └──WebSocket──→ Fixer Server ←──WebSocket──┘
        (control plane: status, routing, tally)
```

**New endpoints:**

```
POST   /api/live/start        — Register a new live stream session
PATCH  /api/live/:id/status   — Update stream status (connected/degraded/ended)
GET    /api/live/active        — List active streams for org
POST   /api/live/:id/route    — Assign stream to SDI output
DELETE /api/live/:id          — End stream session
GET    /api/live/:id/stats    — Real-time SRT stats
```

**New WebSocket events:**

```
live:started     — Field → Server → Dashboard (new stream available)
live:stats       — Station → Server → Dashboard (bitrate, RTT, loss)
live:routed      — Dashboard → Server → Field (tally — you're on air)
live:ended       — Field → Server → Dashboard (stream ended)
live:quality     — Field → Server → Dashboard (quality preset changed)
```

### 5.2 Database Schema

```prisma
model LiveStream {
  id            String    @id @default(uuid())
  userId        String
  orgCode       String
  status        LiveStatus @default(IDLE)
  srtUrl        String?   // station ingest URL used
  streamId      String?   // SRT StreamID for routing
  quality       String?   // "1080p30", "720p60", etc.
  startedAt     DateTime?
  endedAt       DateTime?
  createdAt     DateTime  @default(now())

  user          User      @relation(fields: [userId], references: [id])
}

enum LiveStatus {
  IDLE
  CONNECTING
  LIVE
  DEGRADED
  ENDED
}
```

---

## Phased Rollout

### Phase 1: iOS → SRT → Hardware Decoder (MVP)

**Goal:** iPhone streams to a Magewell Pro Convert box at the station. SDI out. Done.

- [ ] iOS: `AVCaptureSession` + HaishinKit SRT streaming
- [ ] iOS: Quality preset selector (1080p30 default)
- [ ] iOS: Audio source picker (`AVAudioSession.availableInputs`)
- [ ] iOS: Audio VU meter (dBFS, peak hold)
- [ ] iOS: Manual SRT URL entry
- [ ] iOS: Connection status overlay (bitrate, RTT, loss)
- [ ] Station: Magewell Pro Convert hardware decoder (~$500)
- [ ] Server: `LiveStream` model + basic CRUD endpoints

**No custom station software needed.** The Magewell box accepts SRT and outputs SDI/HDMI. Plug and play.

**Effort:** ~3–4 weeks iOS dev, ~1 week server, $500 hardware

### Phase 2: Admin Config + Dashboard Preview

**Goal:** Admin configures station URL per org. Web dashboard shows live preview + stats.

- [ ] Server: Org-level `liveIngestUrl` / `liveIngestKey` fields
- [ ] Admin dashboard: Live Streaming settings per org
- [ ] iOS: Auto-populate SRT URL from org config
- [ ] Dashboard: Live stream list with status indicators
- [ ] Dashboard: Low-res preview via MJPEG/WebRTC relay
- [ ] Dashboard: Audio level meters (server-extracted)
- [ ] Dashboard: SRT connection health graphs

**Effort:** ~2–3 weeks

### Phase 3: Software Decoder + Multi-Feed Routing

**Goal:** Custom Mac station app replaces hardware decoder. Multi-feed support with output routing.

- [ ] Mac app: SRT receive + VideoToolbox decode
- [ ] Mac app: Blackmagic DeckLink SDK integration (SDI output)
- [ ] Mac app: Multi-feed support (up to 4 simultaneous)
- [ ] Mac app: Output routing (assign feed → SDI output)
- [ ] Dashboard: Routing control panel
- [ ] iOS → Dashboard: Tally light (on-air indicator)
- [ ] Adaptive bitrate: auto-degrade quality on poor network

**Effort:** ~4–6 weeks

### Phase 4: Advanced (Future)

- [ ] Return video (station → field) for IFB/prompter
- [ ] Recording at station (simultaneous SDI out + file record)
- [ ] Bonded cellular (MPTCP multi-path for SRT)
- [ ] Mac companion app for external camera → SRT (from EXTERNAL_CAMERA_PLAN)
- [ ] Closed caption / SCTE-35 metadata pass-through

---

## Cost Comparison

| Solution | Hardware | Monthly | Latency | Feeds |
|----------|----------|---------|---------|-------|
| **LiveU Solo** | $5,000+ | $500+/mo data | ~500ms | 1 |
| **LiveU LU800** | $15,000+ | $500+/mo | ~400ms | 1 |
| **TVU One** | $4,000+ | $200+/mo | ~500ms | 1 |
| **Fixer Phase 1** (iPhone + Magewell) | ~$500 | $0 | ~400–600ms | 1 |
| **Fixer Phase 3** (iPhone + Mac + DeckLink) | ~$700 | $0 | ~300–500ms | 4 |

Fixer's competitive advantage: **$500–700 total hardware** vs. $5,000–15,000+ per unit, no monthly fees, uses equipment stations likely already own.

---

## Relationship to Existing Docs

| Document | Relationship |
|----------|-------------|
| [EXTERNAL_CAMERA_PLAN.md](./EXTERNAL_CAMERA_PLAN.md) | Phase 4 — external camera → Mac → SRT extends this plan from store-and-forward to live |
| [MAC_STREAMING_APP_STACK.md](./MAC_STREAMING_APP_STACK.md) | The station Mac app (Phase 3) inverts this — same tech stack but for **output** instead of capture |
| [CAMERA_UPLOAD_PLAN.md](./CAMERA_UPLOAD_PLAN.md) | Phase 1 shares the `AVCaptureSession` capture layer; live streaming replaces the upload pipeline with SRT |
| [VIDEO_PRODUCTION_IDEAS.md](./VIDEO_PRODUCTION_IDEAS.md) | #5 (Live Shot Checklist) and #8 (Bandwidth Dashboard) fold directly into the iOS streaming UI and station dashboard |

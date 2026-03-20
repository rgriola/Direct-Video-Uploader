# Mac Streaming App — Tech Stack

A standalone macOS app for capturing from professional cameras, encoding H.265, and uploading (store-and-forward) to a server. A processing box replacement.

---

## Pipeline

```
📹 Camera → SDI/HDMI → Blackmagic Capture → AVCaptureSession
     ↓
VideoToolbox H.265 → fMP4 fragments (1-5 sec each)
     ↓
Chunk scheduler → distributes across WiFi + Eth + LTE paths
     ↓
HTTPS PUT per chunk → Server receives + reassembles 
     ↓
Complete file → Mux/FFmpeg → Mediasource (use FFmpeg))
```

---

## Capture Layer

| Component | Technology |
|---|---|
| **Video input** | `AVCaptureSession` + `AVCaptureDeviceDiscoverySession` (detects HDMI/SDI/Thunderbolt capture devices) |
| **Capture cards** | Blackmagic UltraStudio / DeckLink (SDI), Elgato Cam Link (HDMI), or any UVC-compliant USB device |
| **Blackmagic SDK** | DeckLink SDK for direct SDI control, timecode, genlock — beyond what AVFoundation exposes |
| **Audio** | `AVCaptureAudioDataOutput` or CoreAudio for embedded audio from the camera feed |

---

## Encoding Layer

| Component | Technology |
|---|---|
| **Hardware encoder** | **VideoToolbox** (`VTCompressionSession`) — Apple Silicon H.265/HEVC hardware encoder. Near-zero CPU cost. |
| **Codec** | H.265 (HEVC) for bandwidth efficiency, H.264 fallback for compatibility |
| **Container** | fMP4 (fragmented MP4) — ideal for chunked streaming; each fragment is independently decodable |
| **Bitrate** | Adaptive — measure available bandwidth, adjust encoding quality in real-time |

---

## Transport Layer

| Component | Technology |
|---|---|
| **Chunked upload** | HTTP chunked transfer or **tus.io** (resumable upload protocol — open source, battle-tested) |
| **Bonding** | `Network.framework` MPTCP (`.aggregate`) across multiple interfaces |
| **Connection management** | `NWPathMonitor` — monitors all network interfaces, detects failures, measures bandwidth |
| **Protocol** | HTTPS + WebSocket for control channel (status, metadata, server commands) |

---

## Networking Layer (Bonding)

| Component | Technology |
|---|---|
| **Path discovery** | `NWPathMonitor` enumerates WiFi, Ethernet, USB modems |
| **Software bonding** | Custom chunk scheduler: measure RTT per path, distribute chunks to fastest available |
| **Fallback** | If bonding is overkill, simple priority: wired > WiFi > cellular |

---

## App Layer

| Component | Technology |
|---|---|
| **Framework** | **SwiftUI** (macOS native) |
| **Live preview** | `AVCaptureVideoPreviewLayer` in an `NSViewRepresentable` |
| **UI** | Source selector, encoding settings, connection status per path, upload progress, recording controls |
| **Settings** | Resolution, bitrate, codec, chunk size, server URL |

---

## Server (Receiving End)

| Component | Technology |
|---|---|
| **Chunk receiver** | Node.js/Fastify or Go — accept chunks, write to disk, track sequence |
| **Reassembly** | Concatenate fMP4 fragments by index → complete file |
| **Processing** | FFmpeg or Mux for transcoding, thumbnail generation |
| **Storage** | Cloudflare R2 / S3 |
| **Notifications** | WebSocket push back to app + Slack integration |

---

## What Makes This Different From OBS/Wirecast

| | OBS/Wirecast | This App |
|---|---|---|
| **Purpose** | Live streaming (RTMP) | Store-and-forward upload |
| **Network resilience** | Stream dies on dropout | Chunks retry, nothing lost |
| **Bonding** | No | Multi-path chunk distribution |
| **Target** | Twitch/YouTube | Mediasource/enterprise |
| **Field-optimized** | No (desktop tool) | Yes — designed for unstable cell connections |

The key differentiator: this isn't a live streaming app — it's a **reliable field upload tool** that captures from professional cameras. That distinction makes the engineering dramatically simpler than building a LiveU competitor.

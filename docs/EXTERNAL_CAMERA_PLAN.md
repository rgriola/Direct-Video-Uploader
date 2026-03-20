# External Camera Upload — Processing Box Replacement

Use an iPhone or MacBook as a replacement for professional video processing boxes (LiveU, TVU, Dejero) to capture, encode, and upload video from professional cameras directly to Mediasource via Fixer.

---

## Concept

```
📹 Pro Camera → HDMI/SDI → MacBook (or iPhone)
                              ↓
                    VideoToolbox H.265 encode
                              ↓
                    Chunked upload to server
                              ↓
                    Server reassembles → Mux
                              ↓
                    Mediasource ✅
```

---

## External Camera → iPhone

iPhones support **USB-C video capture devices** (HDMI capture dongles like Elgato Cam Link). iOS sees them as `AVCaptureDevice` external inputs.

1. `AVCaptureSession` picks up the external video input
2. **VideoToolbox** (hardware H.265 encoder on A-series chips) transcodes in real-time
3. Chunked upload streams encoded segments to server via HTTP or WebSocket
4. Server reassembles → Mux → Mediasource

iPhone already records 4K60 HEVC natively — transcoding external HDMI input is well within capability.

---

## External Camera → MacBook

A MacBook is the stronger option for field use:

| Factor | iPhone | MacBook |
|--------|--------|---------|
| **H.265 hardware encoder** | ✅ VideoToolbox (A-series) | ✅ VideoToolbox (Apple Silicon, even better) |
| **Network** | Cell + WiFi | Wired Ethernet + WiFi (more reliable) |
| **Power** | Battery limited | Plugged in |
| **Storage buffer** | Limited | Large SSD buffer for network hiccups |
| **Capture input** | USB-C dongle | USB-C, Thunderbolt, SDI via Blackmagic capture cards |
| **Processing headroom** | Good | Much more RAM/CPU for 4K+ |
| **Portability** | Pocket | Bag |

A MacBook with a **Blackmagic DeckLink or UltraStudio** capture card takes **SDI input** directly — same input as professional processing boxes. No HDMI adapter needed.

---

## What Processing Boxes Actually Do

LiveU, TVU, Dejero do three things:

1. **Capture** — SDI/HDMI input → hardware encode (H.264/H.265)
2. **Bond** — Aggregate multiple cellular modems + WiFi + ethernet for reliable bandwidth
3. **Transport** — Proprietary protocol with FEC (forward error correction) to survive packet loss

iPhone/MacBook can do **#1 and #3** natively. **#2 (bonding)** is what you're paying $15k+ for.

For Fixer's use case (file upload, not live broadcast), a single good connection with chunked upload + retry may be sufficient.

---

## 🔴 Bonded Cellular — TODO: Discuss Tomorrow

**Key questions to explore:**

- Can we replicate bonded cellular using multiple iPhone hotspots aggregated on a MacBook?
- Open-source bonding solutions: **Speedify**, **OpenMPTCProuter**, **MPTCP (Multipath TCP)** — iOS and macOS both have native MPTCP support
- Apple's **Network.framework** supports `multipathServiceType` (`.handover`, `.interactive`, `.aggregate`) — `.aggregate` bonds WiFi + cellular natively
- Could Fixer use `Network.framework` multipath to bond connections without hardware?
- What bandwidth is needed? 4K HEVC @ 30fps ≈ 20-40 Mbps sustained
- Cost comparison: LiveU $15-50k + monthly vs. Fixer + MacBook + capture card ($2-3k total)
- Is this file upload (store-and-forward) or live streaming? Bonding matters much more for live.

---

## macOS Companion App

SwiftUI is cross-platform — a **macOS version of Fixer** could share the same codebase, same server, same WebSocket connection. The MacBook becomes the processing box.

---

## How This Fits Fixer

The app (iOS or macOS) would:

1. Detect external capture device via `AVCaptureDevice.DiscoverySession`
2. Show live preview from the professional camera
3. Hit record → start H.265 encoding + chunked upload simultaneously
4. Stop recording → upload finishes seconds later
5. Same existing flow: form, metadata, Slack, archive

The entire backend (server, Mux, WebSocket, forms, Slack) stays untouched.

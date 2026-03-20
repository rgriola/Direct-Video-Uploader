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
2. **Bond** — Aggregate multiple cellular modems + WiFi + ethernet for reliable bandwidth <<< how do we do this part? >>>
3. **Transport** — Proprietary protocol with FEC (forward error correction) to survive packet loss

iPhone/MacBook can do **#1 and #3** natively. **#2 (bonding)** is what you're paying $15k+ for.

For Fixer's use case (file upload, not live broadcast), a single good connection with chunked upload + retry may be sufficient.

---

## Bonded Cellular — Deep Dive

### Why Bonding Is Hard (for Live)

The processing boxes (LiveU, TVU) solve five hard problems:

1. **Packet reordering** — Splitting traffic across 3+ modems means packets arrive out of order (different path latencies). Must buffer and resequence in <200ms for live.
2. **Per-path bandwidth estimation** — Each cellular connection constantly fluctuates. Must measure in real-time and distribute chunks proportionally.
3. **Path failover** — When a modem hits a dead zone, instantly redistribute to remaining paths without dropping frames.
4. **Server-side reassembly** — Packets arrive from multiple source IPs (different carriers). Must match to same session, reorder, deduplicate.
5. **NAT traversal** — Carrier-grade NAT on cellular networks complicates persistent connections.

### Why Store-and-Forward Makes This Easy

For Fixer's use case (file upload, not live broadcast), bonding is **dramatically simpler**:

| Live Bonding (LiveU) | Store-and-Forward (Fixer) |
|---|---|
| Packet-level splitting (~1500 bytes) | **Chunk-level splitting (~1-5 MB)** |
| Must reassemble in <200ms | **Can take seconds, no rush** |
| Frame drops = glitch on air | **Retry failed chunks, no data loss** |
| Needs custom relay server | **Existing Fixer server works** |
| Real-time bandwidth balancing | **Try fastest path first, fall back** |

For store-and-forward, you just need:
1. Chunk the encoded video into ~1-5 MB segments
2. Upload each chunk on whichever connection is fastest
3. If a chunk fails, retry on a different connection
4. Server reassembles chunks by index (trivial)

HD @ 30fps ≈ 1.2 Kbps sustained — even a single decent LTE connection handles this.

### iPhone Networking Capabilities

**WiFi + Cellular bonding: Yes, with limits.**

iOS has built-in Multipath TCP (MPTCP) via `Network.framework`:

```swift
let connection = NWConnection(host: "server.com", port: 443, using: .tcp)
connection.parameters.multipathServiceType = .aggregate  // bond both paths
```

Caveats:
- Server must also support MPTCP (Linux kernels do, needs config)
- Apple may throttle cellular if WiFi is strong (battery/data saving)
- **2 paths max**: phone's built-in cell radio + WiFi. No way to add a third.

**External data cards: No.** iPhones don't support USB cellular modems, USB Ethernet adapters, or external network interfaces. iOS locks this down.

### MacBook Networking Capabilities

| Capability | iPhone | MacBook |
|---|---|---|
| WiFi + Cell bonding | ✅ 2 paths max (MPTCP) | ✅ Via iPhone hotspot or USB tethering |
| USB cellular modem | ❌ Not supported | ✅ Works natively |
| USB Ethernet | ❌ Not supported | ✅ Works natively |
| Multiple USB modems | ❌ No | ✅ Yes — plug in 2-3 USB LTE dongles |
| Thunderbolt networking | ❌ No | ✅ Yes |
| Total bondable paths | **2** | **4-5+** |

A MacBook can run simultaneously:
- Built-in WiFi
- USB Ethernet (wired venue connection)
- 2-3 USB LTE/5G dongles (different carriers for redundancy)
- iPhone hotspot tethered via USB

That's 4-5 paths bonded — approaching LiveU territory for a fraction of the cost.

### Software Bonding Options

- **Apple `Network.framework`** — native MPTCP with `.aggregate` mode (free, built-in)
- **Speedify** — commercial app that bonds multiple connections ($15/mo)
- **OpenMPTCProuter** — open-source, runs on a VPS + local router
- **Custom chunk-level bonding** — simplest for store-and-forward; no MPTCP needed, just try each path and use the fastest

### Cost Comparison

| Solution | Cost | Paths |
|---|---|---|
| LiveU Solo | $15-50k + monthly | 4-6 modems |
| Fixer + MacBook + Blackmagic + 2 USB LTE dongles | ~$2-3k total | 4-5 paths |
| Fixer + iPhone only | $0 (existing hardware) | 2 paths |

### Practical Field Setup

- **iPhone (mobile quick-hit)**: WiFi + cell via MPTCP = 2 paths. Sufficient for HD store-and-forward on a decent connection.
- **MacBook (planned shoots)**: Multiple USB modems + WiFi + wired = serious bandwidth redundancy. This is the processing box replacement.

Both upload to the same Fixer server.

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

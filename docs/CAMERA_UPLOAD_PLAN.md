# iOS Camera Direct Upload — Feature Plan

Use the iOS camera within Fixer to record and upload video directly to Mediasource.

---

## Two Approaches

### Approach 1: Record-Then-Upload

```
📹 Recording... → ✅ Done → [trim?] → Stage → Upload → Mux
```

Camera saves a complete file, then the existing upload pipeline handles it. User can trim before sending.

**Implementation — Quick Path (`UIImagePickerController`)**

Wrap the system camera in a `UIViewControllerRepresentable`. Produces a temp video URL that feeds directly into the existing `stageVideo()` → `confirmStagedUpload()` flow.

```swift
struct CameraRecorderView: UIViewControllerRepresentable {
    var onRecorded: (URL) -> Void
    var onCancel: () -> Void
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.movie"]
        picker.videoQuality = .typeHigh     // full resolution
        picker.videoMaximumDuration = 600   // 10 min cap
        picker.delegate = context.coordinator
        return picker
    }
}
```

**Implementation — Pro Path (`AVCaptureSession`)**

Custom camera view with full control: custom record button, front/back toggle, flash/torch, ProRes/HEVC codec selection, live preview with branding. ~200-300 lines but gives a branded Fixer camera experience.

---

### Approach 2: Stream-While-Recording

```
📹 Recording + uploading simultaneously → ✅ Stop → Done (already uploaded!)
```

Upload begins the moment recording starts. By the time the journalist stops recording, the video is already in Mediasource (or nearly there).

**Implementation:**

1. Use `AVCaptureSession` + `AVAssetWriter` (not `AVCaptureMovieFileOutput`)
2. As the writer outputs data segments, pipe chunks to the server in real-time via WebSocket or chunked HTTP
3. Server reassembles chunks into a complete file and passes to Mux
4. Need chunk buffering + retry logic for network interruptions

---

## Comparison

| | Record-Then-Upload | Stream-While-Recording |
|---|---|---|
| **Complexity** | Low (existing pipeline) | High (chunk management, reassembly) |
| **Trim support** | ✅ Yes, before upload | ❌ Not practical — already uploaded |
| **Network resilience** | Upload retries on failure | Need chunk buffering + retry |
| **Battery** | Normal | Higher (camera + network simultaneous) |
| **Time to Mediasource** | Record time + upload time | ≈ Record time only |

---

## Integration Point

Both approaches produce a **video file URL** — the same output as `VideoLibraryView`. The existing upload pipeline is reused:

```
Camera → temp video URL → VideoTrimView (optional) → stageVideo() → confirmStagedUpload()
```

No changes needed to `createAsset`, `mux-upload`, WebSocket events, form, or archive flow.

---

## InputBar Hook

| Button | Current | With Camera |
|--------|---------|-------------|
| `📎 +` | Opens library picker | Opens library picker (unchanged) |
| `🎥` | Also opens library picker | **Opens camera** |

---

## Metadata Advantage

Camera capture provides **live EXIF data** (GPS, timestamp, device model) at the moment of recording. `AVCaptureMovieFileOutput` writes this into QuickTime metadata, so `VideoMetadataExtractor` picks it up automatically.

---

## Recommendation

Start with **Record-Then-Upload + `UIImagePickerController`** — minimal code, plugs into existing flow. Graduate to `AVCaptureSession` for branded camera UX, then stream-while-recording for the killer "instant delivery" demo.

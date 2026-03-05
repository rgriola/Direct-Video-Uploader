# Apple Speech Framework — Transcription Implementation

> **Purpose**: Add automatic video transcription to the upload workflow using Apple's native `Speech` framework. Zero third-party dependencies. On-device processing (iOS 17+).

---

## Overview

After a video is uploaded, the server (or iOS client) extracts the audio track and runs speech recognition to produce a text transcript. The transcript is saved to the database alongside the clip metadata and displayed in the Metadata sheet.

---

## 1. New File: `TranscriptionService.swift`

**Location**: `ios/DirectVideoUploader/Services/TranscriptionService.swift`

```swift
import Speech
import AVFoundation

/// On-device video transcription using Apple Speech framework.
/// Requires iOS 17+ for guaranteed on-device recognition.
@MainActor
@Observable
final class TranscriptionService {
    
    enum TranscriptionState {
        case idle
        case requesting      // Awaiting user permission
        case extractingAudio // Pulling audio track from video
        case transcribing    // SFSpeechRecognizer running
        case completed(String)
        case failed(String)
        case noSpeech        // Audio exists but no words detected
    }
    
    var state: TranscriptionState = .idle
    var progress: Double = 0  // 0.0–1.0 estimate
    
    // MARK: - Public API
    
    /// Transcribe the audio track of a video file.
    /// Returns the transcript string, or nil if no speech was detected.
    func transcribe(videoURL: URL) async -> String? {
        state = .requesting
        
        // 1. Check / request authorization
        let authorized = await requestAuthorization()
        guard authorized else {
            state = .failed("Speech recognition permission denied")
            return nil
        }
        
        // 2. Verify recognizer is available
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            state = .failed("Speech recognizer unavailable for this locale")
            return nil
        }
        
        // 3. Prefer on-device recognition (iOS 17+) to avoid network dependency
        if #available(iOS 17, *) {
            recognizer.supportsOnDeviceRecognition = true
        }
        
        // 4. Create recognition request pointing at the video file
        //    SFSpeechURLRecognitionRequest reads the audio track directly — no AVAssetExportSession needed.
        state = .transcribing
        progress = 0.1
        
        let request = SFSpeechURLRecognitionRequest(url: videoURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        
        // iOS 16+: request on-device only to guarantee privacy
        if #available(iOS 16, *) {
            request.requiresOnDeviceRecognition = true
        }
        
        do {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
                recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let result, result.isFinal {
                        continuation.resume(returning: result)
                    }
                }
            }
            
            let transcript = result.bestTranscription.formattedString
            
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state = .noSpeech
                progress = 1.0
                return nil
            }
            
            state = .completed(transcript)
            progress = 1.0
            return transcript
            
        } catch {
            // Error code 203 = "no speech detected" — not a real error
            let nsError = error as NSError
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 203 {
                state = .noSpeech
                progress = 1.0
                return nil
            }
            
            state = .failed(error.localizedDescription)
            progress = 1.0
            return nil
        }
    }
    
    // MARK: - Authorization
    
    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
```

---

## 2. Info.plist Key (Required)

Add to [project.yml](../ios/project.yml) under the target's `settings.base`:

```yaml
INFOPLIST_KEY_NSSpeechRecognitionUsageDescription: "Transcribe audio from your uploaded videos for searchable captions."
```

**Full diff** — add this line after the existing `NSLocationWhenInUseUsageDescription` entry:

```diff
  INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: "Attach GPS coordinates to your video upload."
+ INFOPLIST_KEY_NSSpeechRecognitionUsageDescription: "Transcribe audio from your uploaded videos for searchable captions."
  INFOPLIST_KEY_NSAppTransportSecurity_AllowsArbitraryLoads: YES
```

After editing, regenerate the Xcode project:

```bash
cd ios && xcodegen generate
```

---

## 3. Database Schema Change

Add a `transcript` column to the `clips` table. In [schema.prisma](../server/prisma/schema.prisma):

```diff
  model Clip {
    id               String     @id @default(uuid())
    assetId          String     @map("asset_id")
    ...
    fileSize         BigInt?    @map("file_size_bytes")
+   transcript       String?    @map("transcript")    // Speech-to-text output
    status           ClipStatus @default(UPLOADING)
    createdAt        DateTime   @default(now()) @map("created_at")
    ...
  }
```

Push schema:

```bash
cd server && npx prisma db push
```

---

## 4. iOS Model Change — `Clip` struct

In [Asset.swift](../ios/DirectVideoUploader/Models/Asset.swift), add `transcript` to the `Clip` struct:

```diff
  struct Clip: Codable, Identifiable {
      let id: String
      let clipIndex: Int?
      let originalFileName: String?
      let gpsLat: Double?
      let gpsLon: Double?
      let capturedAt: String?
      let deviceModel: String?
      let osVersion: String?
      let codec: String?
      let resolution: String?
      let orientation: String?
      let duration: Int?
      let fileSize: String?
+     let transcript: String?    // Speech-to-text from Apple Speech framework
      let status: String?
      let storageUrl: String?
      let streamUrl: String?
      let thumbnailUrl: String?
  }
```

---

## 5. Integration into Upload Flow

### Where it fits in `ChatViewModel.swift`

Transcription runs **after** the upload completes (in parallel with or after metadata extraction). The flow:

1. User picks video → iOS extracts `VideoMetadata` (existing)
2. iOS uploads video → server saves file, returns `upload:complete`
3. **NEW**: iOS runs `TranscriptionService.transcribe(videoURL:)` on the local file **before** cleanup
4. iOS sends transcript to server via new `PATCH /api/clips/:id/transcript`
5. Server stores transcript in `clips.transcript`

### Modified `confirmStagedUpload()` in `ChatViewModel.swift`

```diff
+ let transcriber = TranscriptionService()

  func confirmStagedUpload() async {
      guard let staged = stagedVideo else { return }
      
      let fileURL = staged.tempFileURL
      let fileName = staged.fileName
      let metadata = staged.metadata
      formThumbnail = staged.thumbnail
      lastStagedCreatedDate = staged.createdDate
      lastStagedHasLocation = metadata.gpsLat != nil
      stagedVideo = nil
      
      if let asset = await createAsset(fileName: fileName, fileURL: fileURL) {
          print("✅ Asset created: \(asset.slug)")
          await uploadVideo(assetId: asset.id, fileURL: fileURL, metadata: metadata)
          
+         // Transcribe audio while file is still on disk
+         if let transcript = await transcriber.transcribe(videoURL: fileURL) {
+             await sendTranscript(assetId: asset.id, transcript: transcript)
+         }
          
          // Clean up temp video file after upload AND transcription
          try? FileManager.default.removeItem(at: fileURL)
      }
  }
```

### New method: `sendTranscript()` in `ChatViewModel.swift`

```swift
/// Send the transcribed text to the server for the first clip in this asset.
func sendTranscript(assetId: String, transcript: String) async {
    // The server will look up the first clip for this asset
    var request = auth.authenticatedRequest(
        for: ServerConfig.baseURL.appendingPathComponent("/api/assets/\(assetId)/transcript"),
        method: "PATCH"
    )
    let body: [String: String] = ["transcript": transcript]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            print("✅ Transcript saved for asset \(assetId)")
        }
    } catch {
        print("⚠️ Failed to save transcript: \(error)")
        // Non-fatal — don't show error bubble for transcript failure
    }
}
```

---

## 6. Server Endpoint — `PATCH /api/assets/:id/transcript`

In [server/src/routes/assets.js](../server/src/routes/assets.js), add:

```javascript
// PATCH /api/assets/:id/transcript — Save speech-to-text transcript
fastify.patch('/:id/transcript', {
  preHandler: [fastify.authenticate],
}, async (request, reply) => {
  const { id } = request.params;
  const { transcript } = request.body;

  if (!transcript || typeof transcript !== 'string') {
    return reply.code(400).send({ error: 'transcript is required' });
  }

  // Find the first clip for this asset
  const clip = await fastify.prisma.clip.findFirst({
    where: { assetId: id },
    orderBy: { clipIndex: 'asc' },
  });

  if (!clip) {
    return reply.code(404).send({ error: 'No clip found for this asset' });
  }

  // Update transcript
  await fastify.prisma.clip.update({
    where: { id: clip.id },
    data: { transcript: transcript.slice(0, 10000) }, // Cap at 10K chars
  });

  return { ok: true, clipId: clip.id };
});
```

---

## 7. Display in MetadataView

In the existing `MetadataView.swift`, add a transcript section after the existing metadata rows:

```swift
// Transcript section
if let transcript = clip.transcript, !transcript.isEmpty {
    Divider()
        .background(Color.white.opacity(0.1))
    
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 4) {
            Image(systemName: "text.quote")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "007AFF"))
            Text("Transcript")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        
        Text(transcript)
            .font(.system(size: 13))
            .foregroundStyle(Color(hex: "98989D"))
            .lineLimit(20)
            .textSelection(.enabled)
    }
}
```

---

## 8. Display in Clip Viewer (Web)

In the clips route (`server/src/routes/clips.js`), include transcript in the HTML template when rendering the clip page. Add below the existing metadata section:

```html
${clip.transcript ? `
<div class="transcript-section">
  <h3>📝 Transcript</h3>
  <p class="transcript-text">${clip.transcript}</p>
</div>
` : ''}
```

---

## 9. ServerConfig Addition

Add a convenience URL builder in [ServerConfig.swift](../ios/DirectVideoUploader/Models/ServerConfig.swift):

```swift
/// PATCH /api/assets/:id/transcript
static func transcriptURL(_ assetId: String) -> URL {
    baseURL.appendingPathComponent("/api/assets/\(assetId)/transcript")
}
```

---

## Implementation Checklist

| # | Task | File(s) | Notes |
|---|------|---------|-------|
| 1 | Create `TranscriptionService.swift` | `ios/.../Services/` | New file — code in §1 above |
| 2 | Add `NSSpeechRecognitionUsageDescription` to `project.yml` | `ios/project.yml` | Then `xcodegen generate` |
| 3 | Add `transcript` column to Clip schema | `server/prisma/schema.prisma` | Then `npx prisma db push` |
| 4 | Add `transcript` to iOS `Clip` struct | `ios/.../Models/Asset.swift` | Optional `String?` |
| 5 | Add `TranscriptionService` call in `confirmStagedUpload()` | `ios/.../Services/ChatViewModel.swift` | After upload, before file cleanup |
| 6 | Add `sendTranscript()` method | `ios/.../Services/ChatViewModel.swift` | PATCH to server |
| 7 | Add `transcriptURL()` to `ServerConfig` | `ios/.../Models/ServerConfig.swift` | Convenience URL |
| 8 | Add `PATCH /api/assets/:id/transcript` route | `server/src/routes/assets.js` | Authenticated, caps at 10K chars |
| 9 | Show transcript in `MetadataView.swift` | `ios/.../Views/Metadata/` | Collapsible text block |
| 10 | Show transcript in clip web viewer | `server/src/routes/clips.js` | HTML section |

---

## Constraints & Edge Cases

| Scenario | Behavior |
|----------|----------|
| **No audio track** (screen recording, silent video) | `SFSpeechRecognizer` returns error code 203 → `state = .noSpeech`, transcript = nil |
| **Permission denied** | User sees no transcript; no error bubble. Fails silently. |
| **Video > 1 hour** | Apple Speech has a ~1 hour limit per request. For longer videos, split with `AVAssetExportSession` into segments. Not needed for this demo. |
| **Non-English audio** | `SFSpeechRecognizer(locale: Locale(identifier: "es-MX"))` — could be configurable per user. Default: device locale. |
| **Offline** | iOS 17+ on-device model works offline. If `requiresOnDeviceRecognition = true` is set, no network needed. |
| **Slow device** | Transcription runs async after upload. UI is not blocked. Progress indicator optional. |
| **Transcript too long** | Server caps at 10,000 characters. Could paginate or summarize later. |

---

## Testing

1. **Unit**: Mock `SFSpeechRecognizer` — verify state transitions (idle → transcribing → completed).
2. **Integration**: Upload video with clear speech on Simulator → confirm transcript appears in MetadataView.
3. **Edge**: Upload silent video → confirm "No speech detected" or transcript field is absent.
4. **Permission**: Deny Speech permission → confirm no crash, no transcript, no error bubble.

---

## Future Enhancements

- **Server-side transcription**: Run Whisper on the server (Node `@xenova/transformers` or Python sidecar) for clips uploaded from non-iOS clients.
- **Searchable transcripts**: Full-text search index on `clips.transcript` via PostgreSQL `tsvector`.
- **Timestamped segments**: Use `result.bestTranscription.segments` to get per-word timestamps for subtitle generation (VTT/SRT).
- **Language detection**: Auto-detect spoken language and store as `clips.transcript_language`.

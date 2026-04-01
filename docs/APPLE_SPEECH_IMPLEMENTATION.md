# Apple Speech Framework — Transcription Implementation

> **Purpose**: Add automatic video transcription to the upload workflow using Apple's native `Speech` framework. Zero third-party dependencies. On-device processing (iOS 17+).
>
> **Status**: ✅ IMPLEMENTED (March 25, 2026) — Dual-attempt strategy (server-based → on-device fallback), `addsPunctuation` for sentence formatting, `contextualStrings` for newsroom vocabulary.

---

## Overview

After a video is uploaded, the iOS client runs on-device speech recognition to produce a text transcript with per-word timestamps. The transcript is saved to the database alongside the clip metadata and displayed in the Archive view, Metadata sheet, and web clip viewer.

---

## 1. New File: `TranscriptionService.swift`

**Location**: `ios/DirectVideoUploader/Services/TranscriptionService.swift`

```swift
import Speech
import AVFoundation

/// Timestamped word segment from speech recognition.
struct TranscriptSegment: Codable {
    let word: String
    let start: Double    // seconds from video start
    let end: Double      // start + duration
    let confidence: Float
}

/// Result from transcription — plain text + per-word timestamps.
struct TranscriptionResult {
    let text: String
    let segments: [TranscriptSegment]
}

/// On-device video transcription using Apple Speech framework.
/// Requires iOS 17+ for guaranteed on-device recognition.
@MainActor
@Observable
final class TranscriptionService {

    enum TranscriptionState {
        case idle
        case requesting      // Awaiting user permission
        case transcribing    // SFSpeechRecognizer running
        case completed(TranscriptionResult)
        case failed(String)
        case noSpeech        // Audio exists but no words detected
    }

    var state: TranscriptionState = .idle
    var progress: Double = 0  // 0.0–1.0 estimate

    // MARK: - Public API

    /// Transcribe the audio track of a video file.
    /// Returns text + timestamped segments, or nil if no speech.
    func transcribe(videoURL: URL) async -> TranscriptionResult? {
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

        // 3. Create recognition request pointing at the video file
        //    SFSpeechURLRecognitionRequest reads the audio track directly.
        state = .transcribing
        progress = 0.1

        let request = SFSpeechURLRecognitionRequest(url: videoURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        // iOS 16+: on-device only — works offline, no data leaves the phone
        if #available(iOS 16, *) {
            request.requiresOnDeviceRecognition = true
        }

        do {
            // Safety: guard against callback firing twice
            var hasResumed = false

            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
                recognizer.recognitionTask(with: request) { result, error in
                    guard !hasResumed else { return }
                    if let error {
                        hasResumed = true
                        continuation.resume(throwing: error)
                        return
                    }
                    if let result, result.isFinal {
                        hasResumed = true
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

            // Extract per-word timestamps from segments
            let segments = result.bestTranscription.segments.map { seg in
                TranscriptSegment(
                    word: seg.substring,
                    start: seg.timestamp,
                    end: seg.timestamp + seg.duration,
                    confidence: seg.confidence
                )
            }

            let transcriptionResult = TranscriptionResult(text: transcript, segments: segments)
            state = .completed(transcriptionResult)
            progress = 1.0
            return transcriptionResult

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

Add `transcript` and `transcript_segments` columns to the `clips` table. In [schema.prisma](../server/prisma/schema.prisma):

```diff
  model Clip {
    id               String     @id @default(uuid())
    assetId          String     @map("asset_id")
    ...
    fileSize         BigInt?    @map("file_size_bytes")
+   transcript          String?    @map("transcript")             // Plain text for display + search
+   transcriptSegments  Json?      @map("transcript_segments")    // [{word, start, end, confidence}, ...]
    status           ClipStatus @default(UPLOADING)
    createdAt        DateTime   @default(now()) @map("created_at")
    ...
  }
```

`transcript` = plain readable text (searchable via PostgreSQL full-text).
`transcriptSegments` = JSON array of per-word timestamps from `SFSpeechRecognition.segments`.

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
+     let transcript: String?
+     let transcriptSegments: [TranscriptSegment]?  // Per-word timestamps for timecode jumping
      let status: String?
      let storageUrl: String?
      let streamUrl: String?
      let thumbnailUrl: String?
  }
```

---

## 5. Transcription Opt-In Toggle

Transcription is **opt-in per upload**. A toggle button appears in the `VideoPreviewBubble` alongside the Send/Cancel buttons. Default: **off** (no transcription). The user taps it before hitting Send.

### `VideoPreviewBubble.swift` — Add toggle

```swift
// Inside VideoPreviewBubble, add alongside the Send button:
@State private var transcribeEnabled = false

// Toggle button — sits next to the send arrow
Button {
    transcribeEnabled.toggle()
} label: {
    HStack(spacing: 4) {
        Image(systemName: transcribeEnabled ? "mic.fill" : "mic.slash")
            .font(Theme.iconFont)
        Text("Transcribe")
            .font(Theme.captionFont)
    }
    .foregroundStyle(transcribeEnabled ? Theme.blue : .white.opacity(0.4))
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(transcribeEnabled ? Theme.blue.opacity(0.15) : Color.clear)
    .clipShape(Capsule())
    .overlay(Capsule().stroke(transcribeEnabled ? Theme.blue.opacity(0.4) : .white.opacity(0.2), lineWidth: 1))
}
```

The `onSend` callback passes `transcribeEnabled` to the view model:

```swift
// Updated callback signature
var onSend: (_ transcribe: Bool) -> Void
```

### `ChatViewModel.swift` — Store the flag

```swift
var transcribeOnUpload: Bool = false  // Set by VideoPreviewBubble toggle
```

---

## 6. Integration into Upload Flow

### Where it fits in `ChatViewModel.swift`

Transcription runs **after** the upload completes, **only if the user opted in**. The flow:

1. User picks video → iOS extracts `VideoMetadata` (existing)
2. User sees preview bubble → toggles "Transcribe" on/off
3. User taps Send → iOS uploads video
4. **If transcribe = on**: iOS runs `TranscriptionService.transcribe(videoURL:)` on the local file before cleanup
5. iOS sends transcript + timestamped segments to server via `PATCH /api/assets/:id/transcript`
6. Server stores transcript text in `clips.transcript` and segments JSON in `clips.transcript_segments`

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
          print("✅ Asset created: \(asset.mediasourceId ?? asset.id)")
          await uploadVideo(assetId: asset.id, fileURL: fileURL, metadata: metadata)

+         // Only transcribe if user opted in via the toggle
+         if transcribeOnUpload {
+             if let result = await transcriber.transcribe(videoURL: fileURL) {
+                 await sendTranscript(assetId: asset.id, result: result)
+             }
+             transcribeOnUpload = false  // Reset for next upload
+         }

          // Clean up temp video file after upload AND transcription
          try? FileManager.default.removeItem(at: fileURL)
      }
  }
```

### New method: `sendTranscript()` in `ChatViewModel.swift`

```swift
/// Send transcript text + timestamped segments to the server.
func sendTranscript(assetId: String, result: TranscriptionResult) async {
    var request = auth.authenticatedRequest(
        for: ServerConfig.transcriptURL(assetId),
        method: "PATCH"
    )
    // Send both plain text and per-word timestamp segments
    let segmentsData = try? JSONEncoder().encode(result.segments)
    let segmentsJSON = segmentsData.flatMap { try? JSONSerialization.jsonObject(with: $0) }

    let body: [String: Any] = [
        "transcript": result.text,
        "segments": segmentsJSON ?? []
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            print("✅ Transcript saved for asset \(assetId) (\(result.segments.count) segments)")
        }
    } catch {
        print("⚠️ Failed to save transcript: \(error)")
        // Non-fatal — don't show error bubble for transcript failure
    }
}
```

---

## 7. Server Endpoint — `PATCH /api/assets/:id/transcript`

In [server/src/routes/assets.js](../server/src/routes/assets.js), add:

```javascript
import prisma from "../lib/prisma.js"; // Use direct import (matches existing routes)

// PATCH /api/assets/:id/transcript — Save transcript + timestamped segments
fastify.patch(
  "/api/assets/:id/transcript",
  {
    preHandler: [fastify.authenticate],
  },
  async (request, reply) => {
    const { id } = request.params;
    const { transcript, segments } = request.body;

    if (!transcript || typeof transcript !== "string") {
      return reply.code(400).send({ error: "transcript is required" });
    }

    // Find the first clip for this asset
    const clip = await prisma.clip.findFirst({
      where: { assetId: id },
      orderBy: { clipIndex: "asc" },
    });

    if (!clip) {
      return reply.code(404).send({ error: "No clip found for this asset" });
    }

    // Update transcript text + segments JSON
    await prisma.clip.update({
      where: { id: clip.id },
      data: {
        transcript: transcript.slice(0, 10000), // Cap plain text at 10K chars
        transcriptSegments: Array.isArray(segments) ? segments : undefined, // [{word, start, end, confidence}]
      },
    });

    return { ok: true, clipId: clip.id, segmentCount: segments?.length ?? 0 };
  },
);
```

---

## 8. Display in MetadataView

In the existing `MetadataView.swift`, add a transcript section after the existing metadata rows:

```swift
// Transcript section
if let transcript = clip.transcript, !transcript.isEmpty {
    Divider()
        .background(Color.white.opacity(0.1))

    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 4) {
            Image(systemName: "text.quote")
                .font(Theme.iconMediumFont)
                .foregroundStyle(Theme.tint)
            Text("Transcript")
                .font(Theme.captionBoldFont)
                .foregroundStyle(.white)
        }

        Text(transcript)
            .font(Theme.captionFont)
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(20)
            .textSelection(.enabled)
    }
}
```

---

## 9. Transcript in Archive View

In `ArchiveRowView.swift`, add a scrollable transcript panel inside the expanded detail section. It goes **after the metadata grid** (line ~202 in current file) and **before the action buttons** (line ~204).

### Data Flow

The `fetchAssets()` call in `ArchiveListView` already loads clips via `GET /api/assets/me`. The server needs to include `transcript` in the clip response — add it to the `select` or `include` in the assets route.

### `ArchiveRowView.swift` — Transcript Section

```swift
// After the metadata grid (resolution, codec, duration, etc.)
// Before the action buttons

// Transcript panel
if let clip = asset.clips?.first,
   let transcript = clip.transcript, !transcript.isEmpty {
    Divider()
        .background(Theme.separator)

    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
            Image(systemName: "text.quote")
                .font(Theme.iconFont)
                .foregroundStyle(Theme.tint)
            Text("Transcript")
                .font(Theme.captionBoldFont)
                .foregroundStyle(.white)

            Spacer()

            // Copy button
            Button {
                UIPasteboard.general.string = transcript
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(Theme.iconSmallFont)
                    .foregroundStyle(Theme.secondaryText)
            }
        }

        // Scrollable transcript text
        ScrollView {
            Text(transcript)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.metaText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)  // Capped height, scrollable
        .padding(10)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

### Server — Include transcript in asset response

In `assets.js`, ensure the `GET /api/assets/me` route includes `transcript` in the clip select:

```diff
  clips: {
    select: {
      id: true,
      clipIndex: true,
      originalFileName: true,
      // ... existing fields ...
+     transcript: true,
+     transcriptSegments: true,
    }
  }
```

---

## 10. Display in Clip Viewer (Web)

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

## 11. ServerConfig Addition

Add a convenience URL builder in [ServerConfig.swift](../ios/DirectVideoUploader/Models/ServerConfig.swift):

```swift
/// PATCH /api/assets/:id/transcript
static func transcriptURL(_ assetId: String) -> URL {
    baseURL.appendingPathComponent("/api/assets/\(assetId)/transcript")
}
```

---

## Implementation Checklist

| #   | Task                                                       | File(s)                                | Notes                              |
| --- | ---------------------------------------------------------- | -------------------------------------- | ---------------------------------- |
| 1   | Create `TranscriptionService.swift`                        | `ios/.../Services/`                    | New file — code in §1 above        |
| 2   | Add `NSSpeechRecognitionUsageDescription` to `project.yml` | `ios/project.yml`                      | Then `xcodegen generate`           |
| 3   | Add `transcript` + `transcriptSegments` to Clip schema     | `server/prisma/schema.prisma`          | Then `npx prisma db push`          |
| 4   | Add `transcript` to iOS `Clip` struct                      | `ios/.../Models/Asset.swift`           | `String?` + `[TranscriptSegment]?` |
| 5   | Add transcribe toggle to `VideoPreviewBubble`              | `ios/.../Views/Chat/`                  | Opt-in mic button, default off     |
| 6   | Add `TranscriptionService` call in `confirmStagedUpload()` | `ios/.../Services/ChatViewModel.swift` | Only if toggle on                  |
| 7   | Add `sendTranscript()` method                              | `ios/.../Services/ChatViewModel.swift` | PATCH text + segments to server    |
| 8   | Add `transcriptURL()` to `ServerConfig`                    | `ios/.../Models/ServerConfig.swift`    | Convenience URL                    |
| 9   | Add `PATCH /api/assets/:id/transcript` route               | `server/src/routes/assets.js`          | Authenticated, caps at 10K chars   |
| 10  | Include transcript in `GET /api/assets/me` response        | `server/src/routes/assets.js`          | Add to clip select                 |
| 11  | Show transcript in `ArchiveRowView.swift`                  | `ios/.../Views/Archive/`               | Scrollable panel + copy button     |
| 12  | Show transcript in `MetadataView.swift`                    | `ios/.../Views/Metadata/`              | Collapsible text block             |
| 13  | Show transcript in clip web viewer                         | `server/src/routes/clips.js`           | HTML section                       |

---

## Constraints & Edge Cases

| Scenario                                            | Behavior                                                                                                                                     |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **No audio track** (screen recording, silent video) | `SFSpeechRecognizer` returns error code 203 → `state = .noSpeech`, transcript = nil                                                          |
| **Permission denied**                               | User sees no transcript; no error bubble. Fails silently.                                                                                    |
| **Video > 1 hour**                                  | Apple Speech has a ~1 hour limit per request. For longer videos, split with `AVAssetExportSession` into segments. Not needed for this demo.  |
| **Non-English audio**                               | `SFSpeechRecognizer(locale: Locale(identifier: "es-MX"))` — could be configurable per user. Default: device locale.                          |
| **Offline**                                         | Dual-attempt: server-based first (more accurate, needs network), on-device fallback (works offline). If both fail, no transcript.            |
| **Slow device**                                     | Transcription runs async after upload. UI is not blocked. Progress indicator optional.                                                       |
| **Transcript too long**                             | Server caps at 10,000 characters. Could paginate or summarize later.                                                                         |
| **Punctuation**                                     | `addsPunctuation = true` on `SFSpeechRecognitionRequest` enables automatic period/comma/question mark insertion (iOS 16+).                   |
| **Domain vocabulary**                               | `contextualStrings` biases recognizer toward newsroom terms: mediasource, b-roll, slug, standup, Fixer, breaking.                            |
| **Swift 6 concurrency**                             | `recognitionTask` callback runs on background queue. `nonisolated` methods + `ResumeGuard` class (`@unchecked Sendable`) prevent data races. |

---

## Testing

1. **Unit**: Mock `SFSpeechRecognizer` — verify state transitions (idle → transcribing → completed).
2. **Integration**: Upload video with clear speech on Simulator → confirm transcript appears in MetadataView.
3. **Edge**: Upload silent video → confirm "No speech detected" or transcript field is absent.
4. **Permission**: Deny Speech permission → confirm no crash, no transcript, no error bubble.

---

## Future Enhancements

- **Server-side transcription**: Run Whisper on the server (Node `@xenova/transformers` or Python sidecar) for clips uploaded from non-iOS clients.
- **Searchable transcripts**: Full-text search index on `clips.transcript` via PostgreSQL `tsvector` + GIN index.
- **Subtitle generation**: Convert `transcriptSegments` to VTT/SRT format for video player captions.
- **Timecode search in dashboard**: Producer types a word → dashboard highlights matching segments with clickable timecodes that jump to that point in the video player.
- **Language detection**: Auto-detect spoken language and store as `clips.transcript_language`.
- **Field-to-Edit bridge**: Export timestamped transcript as Premiere markers — editor sees the transcript as clip markers in the timeline, clicks a word to jump to that frame.

---

## Agent Prompts

Copy-paste these prompts to an AI coding agent to implement each phase. Run them in order — each builds on the previous.

---

### Prompt 1: Foundation — TranscriptionService + Schema + Models

```
Implement the foundation for Apple Speech transcription in the Direct Video Uploader project.

References:
- Plan: docs/APPLE_SPEECH_IMPLEMENTATION.md (Sections 1-4)
- Existing models: ios/DirectVideoUploader/Models/Asset.swift
- Schema: server/prisma/schema.prisma
- Project config: ios/project.yml

Tasks:
1. Create `ios/DirectVideoUploader/Services/TranscriptionService.swift` with:
   - `TranscriptSegment` struct (Codable: word, start, end, confidence)
   - `TranscriptionResult` struct (text + [TranscriptSegment])
   - `TranscriptionService` class (@MainActor, @Observable) with:
     - `transcribe(videoURL:)` async method using SFSpeechURLRecognitionRequest
     - On-device only (requiresOnDeviceRecognition = true)
     - Continuation safety guard (hasResumed flag)
     - Error 203 handling for "no speech detected"
     - Per-word timestamp extraction from bestTranscription.segments

2. Add `NSSpeechRecognitionUsageDescription` to `ios/project.yml` after the existing NSLocationWhenInUseUsageDescription entry. Value: "Transcribe audio from your uploaded videos for searchable captions."

3. In `server/prisma/schema.prisma`, add to the Clip model (after fileSize, before status):
   - `transcript String? @map("transcript")`
   - `transcriptSegments Json? @map("transcript_segments")`
   Then run: cd server && npx prisma db push

4. In `ios/DirectVideoUploader/Models/Asset.swift`, add to the Clip struct (after fileSize, before status):
   - `let transcript: String?`
   - `let transcriptSegments: [TranscriptSegment]?`

Do NOT modify ChatViewModel, VideoPreviewBubble, or any views yet. Just the foundation.
After completing, run `cd ios && xcodegen generate` and verify the project builds.
```

---

### Prompt 2: Opt-In Toggle + Upload Flow Integration

```
Add the transcription opt-in toggle to VideoPreviewBubble and integrate TranscriptionService into the upload flow.

References:
- Plan: docs/APPLE_SPEECH_IMPLEMENTATION.md (Sections 5-6)
- VideoPreviewBubble: ios/DirectVideoUploader/Views/Chat/VideoPreviewBubble.swift
- ChatViewModel: ios/DirectVideoUploader/Services/ChatViewModel.swift
- ChatView: ios/DirectVideoUploader/Views/Chat/ChatView.swift
- Theme: ios/DirectVideoUploader/App/Theme.swift

Prerequisites: TranscriptionService.swift must already exist (Prompt 1).

Tasks:
1. In VideoPreviewBubble.swift:
   - Add `@State private var transcribeEnabled = false`
   - Add a capsule toggle button next to the Send arrow button in the HStack:
     - Icon: mic.fill (on) / mic.slash (off)
     - Text: "Transcribe"
     - Blue highlight when on, dimmed when off
     - Use Theme tokens for all fonts and colors
   - Change `onSend` callback to `var onSend: (_ transcribe: Bool) -> Void`
   - Pass `transcribeEnabled` when calling onSend

2. In ChatViewModel.swift:
   - Add `var transcribeOnUpload: Bool = false`
   - Add `let transcriber = TranscriptionService()` property
   - In `confirmStagedUpload()`, after `uploadVideo()` and before file cleanup:
     - Check `if transcribeOnUpload`
     - Call `transcriber.transcribe(videoURL: fileURL)`
     - If result returned, call `sendTranscript(assetId:result:)`
     - Reset `transcribeOnUpload = false`
   - Add `sendTranscript(assetId:result:)` method:
     - PATCH to ServerConfig.transcriptURL(assetId)
     - Body: {"transcript": result.text, "segments": [encoded segments]}
     - Non-fatal: print warning on failure, no error bubble

3. In ServerConfig.swift:
   - Add: `static func transcriptURL(_ assetId: String) -> URL`

4. Update ChatView.swift to pass the transcribe bool from VideoPreviewBubble.onSend to viewModel.transcribeOnUpload.

Verify the project builds. Do NOT modify server code yet.
```

---

### Prompt 3: Server Endpoint + Asset Response

```
Add the server-side transcript endpoint and include transcript data in asset responses.

References:
- Plan: docs/APPLE_SPEECH_IMPLEMENTATION.md (Sections 7, 9 Archive data flow, 10)
- Assets route: server/src/routes/assets.js
- Clips route: server/src/routes/clips.js
- Prisma schema: server/prisma/schema.prisma (must already have transcript + transcriptSegments columns)

Prerequisites: Schema migration from Prompt 1 must be done.

Tasks:
1. In server/src/routes/assets.js, add a new route:
   - `PATCH /api/assets/:id/transcript` (authenticated)
   - Accepts body: { transcript: string, segments: array }
   - Validates transcript is a non-empty string
   - Finds the first clip for the asset (orderBy clipIndex asc)
   - Updates clip with transcript (capped at 10000 chars) and transcriptSegments (JSON)
   - Returns { ok: true, clipId, segmentCount }
   - Use `import prisma from '../lib/prisma.js'` (direct import, NOT fastify.prisma)

2. In the GET /api/assets/me route (same file), add `transcript: true` and `transcriptSegments: true` to the clips select/include so the iOS Archive view receives transcript data.

3. In server/src/routes/clips.js, for the clip viewer HTML page, add a transcript section below the existing metadata:
   - Only render if clip.transcript exists
   - Show a "📝 Transcript" heading and the transcript text in a paragraph
   - Add appropriate CSS styling

Verify: Start the server with `npm run dev` and test the PATCH endpoint with curl.
```

---

### Prompt 4: Display in Archive + MetadataView

```
Display transcripts in the Archive expanded row and MetadataView.

References:
- Plan: docs/APPLE_SPEECH_IMPLEMENTATION.md (Sections 8, 9)
- ArchiveRowView: ios/DirectVideoUploader/Views/Archive/ArchiveRowView.swift
- MetadataView: ios/DirectVideoUploader/Views/Metadata/MetadataView.swift
- Theme: ios/DirectVideoUploader/App/Theme.swift

Prerequisites: Clip struct must have transcript field (Prompt 1). Server must include transcript in GET /api/assets/me response (Prompt 3).

Tasks:
1. In ArchiveRowView.swift, inside the `if isExpanded` block:
   - After the metadata grid (resolution, codec, duration, etc.) and BEFORE the action buttons section
   - Add a transcript panel that only shows if `asset.clips?.first?.transcript` is non-nil and non-empty:
     - Header: "text.quote" icon + "Transcript" label (Theme.captionBoldFont) + copy button (doc.on.doc icon)
     - Copy button copies transcript to UIPasteboard.general
     - Body: ScrollView with Text, max height 200px, dark background (Color.black.opacity(0.3)), rounded corners
     - Use Theme tokens for all fonts and colors
     - Text selection enabled

2. In MetadataView.swift:
   - After the existing metadata rows, add a transcript section:
     - Only shows if clip.transcript is non-nil and non-empty
     - Divider + "text.quote" icon + "Transcript" header
     - Text with lineLimit(20), textSelection enabled
     - Use Theme.iconMediumFont, Theme.captionBoldFont, Theme.captionFont, Theme.secondaryText, Theme.tint

Verify the project builds and review the layout in Xcode previews or simulator.
```

---

### Prompt 5: End-to-End Testing

```
Test the full transcription feature end-to-end.

References:
- Plan: docs/APPLE_SPEECH_IMPLEMENTATION.md (Testing section)
- All files modified in Prompts 1-4

Test these scenarios on a physical device or simulator:

1. HAPPY PATH: Upload a video with clear speech.
   - Enable the Transcribe toggle in the preview bubble
   - Tap Send
   - Verify: transcript appears in the console log ("✅ Transcript saved...")
   - Go to Archive, expand the asset, verify transcript panel appears with scrollable text and copy button
   - Open MetadataView, verify transcript section appears
   - Open the web clip viewer, verify transcript section renders in HTML

2. TOGGLE OFF: Upload a video WITHOUT enabling Transcribe.
   - Verify: no transcription runs, no PATCH request sent
   - Archive shows no transcript panel for this upload

3. SILENT VIDEO: Upload a video with no speech (b-roll, screen recording).
   - Enable Transcribe toggle
   - Verify: no crash, no error bubble, no transcript saved (error 203 handled gracefully)

4. PERMISSION DENIED: Deny Speech Recognition permission in Settings.
   - Verify: no crash, no error bubble, transcription silently skipped

5. REGRESSION: Upload a video normally (single clip, no transcribe).
   - Verify: entire existing flow works identically — upload, form, Mux ready, archive

Report any issues found with file names and line numbers.
```

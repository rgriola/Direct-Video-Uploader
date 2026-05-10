# ChatViewModel Refactor Plan

Safe cleanup of dead code, performance fixes, and optional file splitting. **Zero behavioral changes.**

## Proposed Changes

### 1. Remove dead `formType` / `formDescription` / `formPriority` fields

You removed these from `ConversationSummaryBubble` earlier today. They're now parsed from the server, stored in state, and passed to `MessageContent` — but **never displayed anywhere**.

> [!IMPORTANT]
> These fields are still sent by the server in `form:confirmed` and `mux:ready` events. Removing them from the iOS side is safe — unused JSON keys are silently ignored by Swift's `Codable`. The server payloads don't need changes.

#### [MODIFY] [ChatViewModel.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/ChatViewModel.swift)
- Remove `formType`, `formDescription`, `formPriority` from `ArchiveState` (L20-22)
- Remove parsing of these 3 fields in `onFormConfirmed` handler (L156-158, L173-175)
- Remove parsing & assignment in `onMuxReady` handler (L188-190, L202-204, L222-224)

#### [MODIFY] [ChatMessage.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Models/ChatMessage.swift)
- Remove `formType`, `formDescription`, `formPriority` from `MessageContent` struct (L53-55)
- Remove from `init` parameters (L89-91) and assignments (L112-114)

**Risk:** None. Grep confirms no view reads these fields after the `ConversationSummaryBubble` cleanup.

---

### 2. Shared ISO8601 date formatter

`ISO8601DateFormatter()` is allocated **12 times** across ChatViewModel alone. This is a thread-safe, reusable formatter.

#### [MODIFY] [ChatViewModel.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/ChatViewModel.swift)
- Add a private static constant:
  ```swift
  private static let isoFormatter = ISO8601DateFormatter()
  ```
- Replace all 12 instances of `ISO8601DateFormatter().string(from: Date())` with `Self.isoFormatter.string(from: Date())`

> [!NOTE]
> `DVUDateFormatting` already has a `private static let isoBasic = ISO8601DateFormatter()` — we could expose that as `DVUDateFormatting.isoNow()`, but keeping it inside ChatViewModel is simpler and avoids coupling.

**Risk:** None. `ISO8601DateFormatter` is thread-safe and the class is `@MainActor` anyway.

---

### 3. Clear `slackThumbnails` on new conversation

#### [MODIFY] [ChatViewModel.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/ChatViewModel.swift)
- Add `slackThumbnails.removeAll()` to `startNewConversation()` (after L850)

**Risk:** None. Images from old conversations shouldn't leak to new ones.

---

### 4. Remove redundant `MainActor.run` in `downloadSlackThumbnail`

#### [MODIFY] [ChatViewModel.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/ChatViewModel.swift)
- `downloadSlackThumbnail` (L890-902): The class is `@MainActor`, so the `Task` closure already runs on MainActor. Replace:
  ```swift
  await MainActor.run { self.slackThumbnails[messageId] = image }
  ```
  with:
  ```swift
  self.slackThumbnails[messageId] = image
  ```

**Risk:** None. Verified the class is `@MainActor @Observable`.

---

### 5. Clear `form.submitError` on successful submission

#### [MODIFY] [ChatViewModel.swift](file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/ios/DirectVideoUploader/Services/ChatViewModel.swift)
- In `submitForm`, add `form.submitError = nil` before `showFormSheet = false` (L571)

> [!NOTE]
> ChatView already clears this when opening the form sheet (L107), so this is belt-and-suspenders. But it's cleaner to clear on success too.

**Risk:** None.

---

### 6. Optional: Split ChatViewModel into extensions

Currently 905 lines. Could split into focused extensions for readability:

| File | Methods moved | ~Lines |
|---|---|---|
| `ChatViewModel+Upload.swift` | `createAsset`, `uploadVideo`, `confirmStagedUpload`, `cancelUpload`, `stageVideo`, `prepareStagedContext`, `savePHAssetIdentifier`, `cleanupTempFile`, `cancelStagedVideo` | ~200 |
| `ChatViewModel+Transcription.swift` | `transcribeAndReport`, `sendTranscript`, `updateTranscriptionBubble` | ~80 |

> [!WARNING]
> Swift extensions on `@Observable` classes must stay in the same module, and all methods that access `@Observable` properties must be visible. Since we're just moving methods into `extension ChatViewModel` in separate files (same target), this is safe. **No public/internal changes needed.**

**Risk:** Low. All methods stay as `extension ChatViewModel` in the same build target. Properties don't move.

---

## Files Touched Summary

| File | Changes |
|---|---|
| `ChatViewModel.swift` | Remove dead fields, shared formatter, clear thumbnails, fix MainActor, clear error |
| `ChatMessage.swift` | Remove 3 dead properties from `MessageContent` |
| `ChatViewModel+Upload.swift` | **[NEW]** Optional — extension file |
| `ChatViewModel+Transcription.swift` | **[NEW]** Optional — extension file |

## Verification Plan

### Automated
- Xcode build succeeds with no warnings

### Manual
- Upload a video → confirm form → verify confirmation bubble still shows text + MS# + Metadata button
- mux:ready → verify ConversationSummaryBubble still renders correctly
- Start new conversation → verify no stale Slack thumbnails appear
- Submit form with simulated error → reopen → verify error shows, then submit successfully → verify error clears

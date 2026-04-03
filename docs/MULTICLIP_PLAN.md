# Multiclip Upload Feature — Implementation Plan

Enable users to select, trim, and upload **multiple video clips** in a single session. Users toggle between **Single Clip** and **Multiclip** modes via the input bar.

---

## Upload Mode Toggle

The mode lives in the **InputBar** as a toggle next to the attach button. Default is **Single Clip** (current behavior). When toggled to **Multiclip**, the `PhotosPicker` allows up to 10 selections.

```
┌──────────────────────────────────────────────────┐
│  [📎]  [1 ↔ Multi]  [Message...   🎥]  [↑]     │
└──────────────────────────────────────────────────┘
           ↑ toggle
```

---

## Slug Form Strategy: Shared Form

One slug/description per asset (batch). The slug names the *story/event*, not an individual clip. No schema migration needed — the existing `Asset → Clip[]` and `Asset → FormResponse` relationships support multiclip as-is. Per-clip description overrides can be added later without a breaking migration.

---

## Proposed Changes

### iOS — Mode Toggle

| File | Change |
|------|--------|
| **[NEW] `UploadMode.swift`** | Enum: `.single`, `.multiclip`. Stored as `@State` in `ChatViewModel`. |
| **`InputBar.swift`** | Add toggle pill next to `+` button. Pass current mode via `onAttach`. |

### iOS — Video Selection

| File | Change |
|------|--------|
| **`VideoLibraryView.swift`** | Accept `uploadMode` param. `maxSelectionCount` = 1 or 10. Replace single-video state with arrays. Sequential trim flow. 10-min cap enforcement. `onConfirm` callback: `([StagedVideo]) -> Void`. |

### iOS — Staged Preview + Upload

| File | Change |
|------|--------|
| **`VideoPreviewBubble.swift`** | Accept `[StagedVideo]` array. Single clip = current layout. Multiclip = horizontal thumbnail scroll + clip count badge. |
| **`ChatView.swift`** | Pass `uploadMode` to picker. Use `vm.stagedVideos` array. |
| **`ChatViewModel.swift`** | Add `uploadMode`, `stagedVideos: [StagedVideo]`, `currentClipIndex`, `totalClipCount`. `confirmStagedUpload()` creates 1 asset, uploads clips sequentially. |
| **`SentUploadBubble.swift`** | Add `clipIndex`/`totalClipCount`. Progress: "Uploading clip 2 of 5…". |

### Server — Upload & Processing

| File | Change |
|------|--------|
| **`assets.js`** | `POST /api/assets/:id/mux-upload`: accept `clipIndex` from body. Aggregate `totalDuration` (sum, not replace). |
| **`mux-webhooks.js`** | "All clips ready" gate: only emit `mux:ready` when every clip for the asset is `READY`. Add `clip:ready` event for per-clip checkmarks. |

---

## Key Code — All Clips Ready Gate

```javascript
// In mux-webhooks.js → video.asset.ready handler:
const allClips = await prisma.clip.findMany({ where: { assetId: clip.assetId } });
const allReady = allClips.every(c => c.status === 'READY');
if (allReady) {
  await prisma.asset.update({ where: { id: clip.assetId }, data: { status: 'READY' } });
  // emit mux:ready with aggregate data
}
```

---

## TestFlight Build Workflow

1. Open `ios/DirectVideoUploader.xcodeproj` in Xcode
2. Select "Any iOS Device (arm64)" as build destination
3. Increment build number (General → Build)
4. Product → Archive
5. Distribute App → App Store Connect → Upload
6. App Store Connect → TestFlight → select build → add to test group
7. Testers receive TestFlight notification

> CI/CD with GitHub Actions + Fastlane can be added later to automate this.

---

## Verification Checklist

- [ ] **Single-clip regression** — default mode unchanged 
- [ ] **Mode toggle** — switches picker between single/multi select
- [ ] **Multi-select + trim** — sequential trim view per clip
- [ ] **Sequential upload** — 1 asset, N clips with correct `clip_index`
- [ ] **Progress UI** — "Uploading clip 2 of 5…"
- [ ] **Shared form** — one form per asset, one `FormResponse` row
- [ ] **All-ready gate** — summary bubble after all Mux webhooks
- [ ] **10-min enforcement** — trimmer auto-launches for long clips

---

## Notes

- **10-minute per-clip iOS limitation** enforced at selection time
- Default mode is Single Clip — multiclip is explicit opt-in
- No Prisma schema migration required for MVP

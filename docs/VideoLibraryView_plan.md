# VideoLibraryView — Code Evaluation & Improvement Plan (v2)

## Overall Assessment

The file is **solid and intentional**. The PHAsset fast-path, the transferable
fallback, and the temp-file cleanup are all well-reasoned. The main issues are:
one **real bug** (continuation leak), one **retry loop that can spin forever**,
and several **maintainability rough edges**. Nothing is broken in the happy
path, but the edge cases will bite.

---

## 🐛 Bug — `resolveVideoURL` continuation can be resumed twice

**Location:** L300–309

```swift
return await withCheckedContinuation { continuation in
    PHImageManager.default().requestAVAsset(...) { avAsset, _, _ in
        let url = (avAsset as? AVURLAsset)?.url
        continuation.resume(returning: url)   // ← may be called >1×
    }
}
```

Apple's `requestAVAsset(forVideo:)` **can** call its result handler more than
once — first with a degraded/proxy result, then the final one. Resuming a
`CheckedContinuation` twice crashes in Debug and is undefined in Release.

> **Mitigating factor:** The code uses `isNetworkAccessAllowed = false` +
> `.fastFormat`, which makes a double-call unlikely for local assets. But the
> API contract doesn't guarantee single invocation regardless, so this is still
> a real crash risk for edge cases (e.g. recently-synced iCloud assets that are
> technically "local" but have a low-res cached proxy).

**Fix:** Add a `resumed` guard flag:
```swift
return await withCheckedContinuation { continuation in
    var resumed = false
    let options = PHVideoRequestOptions()
    options.isNetworkAccessAllowed = false
    options.version = .current
    options.deliveryMode = .fastFormat
    PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, info in
        guard !resumed else { return }
        resumed = true
        let url = (avAsset as? AVURLAsset)?.url
        continuation.resume(returning: url)
    }
}
```

---

## 🐛 Bug — `pendingConfirm` retry loop can spin forever on failure

**Location:** L229–234 and L181–192

The previous plan said this "silently calls `onDismiss()`" — **that's wrong**.
Here's what actually happens when loading fails while `pendingConfirm` is true:

1. `defer` sets `isLoadingMetadata = false`, clears `pendingConfirm`, calls `handleConfirm()`
2. `handleConfirm()`: `selectedItems` is not empty, `isVideoReady` is false, `loadedVideoURL` is nil
3. Enters `else if isLoadingMetadata || loadedVideoURL == nil` → true (URL is nil)
4. Sets `pendingConfirm = true` again
5. Since `!isLoadingMetadata` and item exists → calls `handleSelectionChange` again
6. `handleSelectionChange` hits the same error → goto step 1

**This is an infinite retry loop.** The user tapped confirm once, the load
failed, and the system retries endlessly with no escape hatch and no user
feedback beyond the error banner (which may flash on/off as `loadError` is
cleared and re-set each cycle). The spinner also keeps spinning.

**Fix:** After `defer` in L229–234, only call `handleConfirm()` if loading *succeeded*:
```swift
defer {
    isLoadingMetadata = false
    if pendingConfirm {
        pendingConfirm = false
        if loadedVideoURL != nil {
            handleConfirm()
        }
        // On failure: pendingConfirm is cleared, error banner stays visible,
        // user can tap confirm again manually.
    }
}
```

---

## ⚠️ Issues

### 1 — `codecName` is duplicated with divergent cases

**Files:** `VideoLibraryView.swift` L369–386 and `VideoMetadataExtractor.swift` L104–125

The Extractor has `VP9` and `MPEG-4` cases that the View's copy is missing.
If a user picks a VP9 video, the fast path will return the raw FourCC string
`"vp09"` while a fallback-path pick of the same video returns `"VP9"`.

**Fix:** Delete `codecName` from `VideoLibraryView`. Call
`VideoMetadataExtractor.codecName(from:)` instead (make it `internal` or
`static` as needed).

---

### 2 — `PHAsset.fetchAssets` called 3× for one selection

For a single video pick, the same `identifier` triggers three separate fetches:
1. L286 — `resolveOriginalFilename`
2. L297 — `resolveVideoURL`
3. L317 — `extractMetadataFromPHAsset`

**Fix:** Resolve the `PHAsset` once at the top of `handleSelectionChange`,
then pass it as a parameter to all three helpers.

---

### 3 — `deliveryMode: .fastFormat` may return a lower-quality proxy

**Location:** L304

For a video uploader, you want the original quality. `.fastFormat` can
return a transcoded proxy. With `isNetworkAccessAllowed = false` the risk is
low (local files are usually the original), but switching to
`.highQualityFormat` guarantees the original is returned.

> **Note:** Switching delivery mode may slightly increase load time for some
> assets. If you notice a slowdown, this can be revisited.

---

### 4 — `ISO8601DateFormatter()` scattered across the codebase

`DVUDateFormatting.swift` already exists with cached `isoFull` and `isoBasic`
formatters and a `parseISO(_:)` helper (String→Date). But **4 other files**
still allocate their own `ISO8601DateFormatter()` instances:

| File | Lines | Pattern |
|---|---|---|
| **VideoMetadataExtractor.swift** | L63 | `ISO8601DateFormatter().string(from: dateValue)` — new instance each call |
| **VideoLibraryView.swift** | L327 | `ISO8601DateFormatter().string(from: $0)` — same |
| **ChatViewModel.swift** | L39 | `private static let isoFormatter` — its own cached copy |
| **ArchiveListView.swift** | L14, L18, L27, L32 | Local formatter + inline fallback `ISO8601DateFormatter()` |
| **ArchiveRowView.swift** | L34, L36, L541, L543 | Same local + fallback pattern |

**Fix (3 steps):**
1. Add a `Date→String` method to `DVUDateFormatting` (it only has `String→Date` today):
   ```swift
   static func isoString(from date: Date) -> String {
       isoBasic.string(from: date)
   }
   ```
2. Replace all standalone `ISO8601DateFormatter()` calls across the 4 files:
   - Date→String calls → `DVUDateFormatting.isoString(from:)`
   - String→Date calls → `DVUDateFormatting.parseISO(_:)`
3. Delete `ChatViewModel.isoFormatter` — it's a private duplicate of what
   `DVUDateFormatting` already provides.

---

### 5 — `VideoTransferable` temp filename collision

**Location:** L402–403

Two different library videos can share the same camera filename (e.g.
`IMG_0001.MOV` after a restore or from a shared library). The second pick
would silently overwrite the first temp file.

**Fix:** Write into a UUID-named subdirectory of `temporaryDirectory`:
```swift
let subdir = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: subdir, ...)
let tempURL = subdir.appendingPathComponent(originalName)
```

---

### 6 — `cleanUpLoadedVideo` does sync disk I/O on the main thread

**Location:** L268–281

`FileManager.removeItem` at L274 runs synchronously. For a temp video file
that could be hundreds of MB, this can cause a visible UI hitch.

**Fix:** Capture the URL and dispatch deletion to a background task:
```swift
if url.path.hasPrefix(tempDir) {
    Task.detached(priority: .utility) {
        try? FileManager.default.removeItem(at: url)
    }
}
```

---

## Dropped from plan

> **ViewModel extraction** — The original plan suggested moving all Photos
> logic to a `VideoLibraryViewModel`. While architecturally clean, this is a
> large refactor with no immediate user-facing benefit and high risk of
> introducing new bugs. Deferring in favor of targeted fixes.

---

## Summary Table

| # | Severity | Issue | Location |
|---|---|---|---|
| Bug 1 | 🔴 High | Continuation double-resume crash | L300 |
| Bug 2 | 🔴 High | Infinite retry loop on load failure | L229 |
| 1 | 🟠 Medium | `codecName` duplicated, VP9/MPEG-4 missing | L369, Extractor L104 |
| 2 | 🟡 Low-Med | 3× redundant `PHAsset.fetchAssets` per pick | L286, L297, L317 |
| 3 | 🟡 Low | `.fastFormat` may serve proxy, not original | L304 |
| 4 | 🟡 Low | `ISO8601DateFormatter()` scattered — 5 files ignoring `DVUDateFormatting` | L327 + 4 other files |
| 5 | 🟡 Low | Temp filename collision in `VideoTransferable` | L402 |
| 6 | ⚪ Cosmetic | Sync `removeItem` on main thread | L274 |

---

## Recommended Execution Order

1. **Fix Bug 1** — `resolveVideoURL` continuation guard (5 min)
2. **Fix Bug 2** — `pendingConfirm` retry loop break on failure (5 min)
3. **Consolidate `codecName`** — delete from View, use Extractor's version (5 min)
4. **Collapse triple PHAsset fetch** — resolve once, pass to helpers (15 min)
5. **Switch to `.highQualityFormat`** — one-line change (1 min)
6. **Consolidate `ISO8601DateFormatter`** — add `isoString(from:)` to `DVUDateFormatting`, replace all 5 files (10 min)
7. **UUID subdirectory for `VideoTransferable`** (5 min)
8. **Async file deletion in `cleanUpLoadedVideo`** (2 min)

**Total: ~40 min of focused work, no structural refactors.**

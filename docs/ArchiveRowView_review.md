# ArchiveRowView.swift — Code Review

**File:** `ios/DirectVideoUploader/Views/Archive/ArchiveRowView.swift`
**Size:** 653 lines

---

## Summary Table

| # | Severity | Issue | Lines |
|---|---|---|---|
| 1 | 🔴 High | `phAssetToTempFile` continuation has no double-resume guard | L618–641 |
| 2 | 🟠 Medium | `handleReupload` uses `loadTransferable` — loads full video into memory | L549 |
| 3 | 🟠 Medium | `isReuploadingVideo = false` scattered across 6 exits, no `defer` | L492, 496, 551, 568, 579, 602 |
| 4 | 🟡 Low | `handleReupload` temp file has no UUID subdirectory — filename collision risk | L555–557 |
| 5 | 🟡 Low | `parseISO8601` is now a dead wrapper — 1 line, calls `DVUDateFormatting.parseISO` | L538–540 |
| 6 | 🟡 Low | `buildFormFields()` duplicated — exact copy exists in `ChatViewModel` | L420–427 |
| 7 | 🟡 Low | `submitFormFromArchive` does raw `URLRequest` — bypasses `AuthService.authenticatedRequest` | L429–451 |

---

## Issue 1 — 🔴 `phAssetToTempFile` continuation has no double-resume guard

**Location:** L618–641 (top-level private function outside the struct)

`PHImageManager.requestAVAsset` can call its completion handler more than once (e.g.
for iCloud assets it fires with a low-quality preview first, then again with the
full quality file). The current code calls `continuation.resume(...)` unconditionally
on every invocation — the second call is a **guaranteed crash** (`EXC_BAD_INSTRUCTION`).

```swift
// ❌ CURRENT — no guard
PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, _ in
    guard let urlAsset = avAsset as? AVURLAsset else {
        continuation.resume(throwing: ReuploadError.videoExportFailed)  // crashes on 2nd call
        return
    }
    ...
    continuation.resume(returning: tempURL)  // crashes on 2nd call
}

// ✅ FIX — same pattern we applied to VideoLibraryView
var resumed = false
PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, _ in
    guard !resumed else { return }
    resumed = true
    ...
}
```

> **Note:** This affects the auto-reupload path (`handleAutoReupload`). For manual
> `PhotosPicker` reupload the risk is lower since `loadTransferable` doesn't use
> `requestAVAsset`. But it should still be fixed.

---

## Issue 2 — 🟠 `handleReupload` loads full video into memory

**Location:** L549

```swift
// ❌ CURRENT — copies entire video into a Data object in RAM, then writes to disk
guard let videoData = try await item.loadTransferable(type: Data.self) else { ... }
let tempURL = ...
try videoData.write(to: tempURL, options: .atomic)
```

For a 4K video this can be **1–2 GB in memory simultaneously**. This is the same issue
we fixed in `VideoLibraryView` with `PHImageManager.requestAVAsset`. The fix is the
same: use `phAssetToTempFile` (which already exists in this file) instead of
`loadTransferable`.

```swift
// ✅ FIX — use the PHAsset fast path that's already here
if let phId = item.itemIdentifier {
    let result = PHAsset.fetchAssets(withLocalIdentifiers: [phId], options: nil)
    if let phAsset = result.firstObject {
        PHAssetIdentifierStore.save(assetId: asset.id, phAssetIdentifier: phAsset.localIdentifier)
        let tempURL = try await exportVideoToTemp(phAsset: phAsset)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await performUpload(fileURL: tempURL)
        return
    }
}
throw ReuploadError.videoExportFailed
```

This also means `handleReupload` becomes almost identical to the PHAsset strategy in
`handleAutoReupload` — both just find a `PHAsset` and call `exportVideoToTemp`.

> **Note:** `PhotosPickerItem.itemIdentifier` can technically be `nil` for cross-process
> pickers. In practice it's always present for local Photos library items, but the fix
> throws `ReuploadError.videoExportFailed` as a safe fallback.

---

## Issue 3 — 🟠 `isReuploadingVideo = false` scattered across 6 exits

**Locations:** L492, 496, 551, 568, 579 (error paths) + L602 (success path in `performUpload`)

The flag is manually reset in every error branch and on the success path. If a new
code path is added and the reset is missed, the UI gets stuck in the "uploading" state
forever. A single `defer` at the top of each function would be cleaner and safer:

```swift
// ❌ CURRENT — 6 scattered resets across 3 functions
reuploadError = "Could not find original video..."
isReuploadingVideo = false   // ← easy to forget in a new branch
...
reuploadError = "Re-upload failed..."
isReuploadingVideo = false   // ← same flag, manual
```

```swift
// ✅ FIX — add defer at top of each calling function
private func handleAutoReupload() async {
    isReuploadingVideo = true
    reuploadProgress = 0
    reuploadError = nil
    defer { if reuploadError != nil { isReuploadingVideo = false } }
    ...
}
```

> **Note:** `performUpload` sets `isReuploadingVideo = false` on the success path
> (L602). The cleanest approach is to let the caller's `defer` handle error resets
> and keep `performUpload`'s success-path reset as-is.

---

## Issue 4 — 🟡 `handleReupload` temp file has filename collision risk

**Location:** L555–557

```swift
// ❌ CURRENT — two different users picking "IMG_0001.MOV" overwrite each other
let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent(asset.originalFileName ?? "reupload.mov")
```

We fixed this exact pattern in `VideoLibraryView`'s `VideoTransferable`. Same fix applies:

```swift
// ✅ FIX — UUID subdirectory
let subdir = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
let tempURL = subdir.appendingPathComponent(asset.originalFileName ?? "reupload.mov")
```

> **Note:** This is lower priority here since `handleReupload` is only invoked for
> one asset at a time per `ArchiveRowView`. But it still creates a predictable path
> that could collide across app launches.

---

## Issue 5 — 🟡 `parseISO8601` is dead wrapper code

**Location:** L538–540

After the formatter consolidation we did earlier, this function is now:

```swift
private func parseISO8601(_ str: String) -> Date? {
    DVUDateFormatting.parseISO(str)  // ← 100% identical, no added value
}
```

**Fix:** Delete it. Replace the one call site at L477 directly:
```swift
// L477 — before
let capturedDate = parseISO8601(capturedAtStr)

// after
let capturedDate = DVUDateFormatting.parseISO(capturedAtStr)
```

---

## Issue 6 — 🟡 `buildFormFields()` duplicated

**Location:** L420–427

Exact same implementation exists in `ChatViewModel`. If a field is added in one place
it'll be missed in the other.

**Fix:** Move to a `static` method on `FormField` or a `FormFieldBuilder` helper so
both call the same source of truth:

```swift
// In FormField.swift or a new FormFieldBuilder.swift
extension FormField {
    static func defaultVideoFields() -> [FormField] {
        [
            FormField(id: "slug", label: "Slug / Title", type: "text", value: nil),
            FormField(id: "type", label: "Content Type", type: "select", options: ["Raw", "Cut"]),
            FormField(id: "description", label: "Description / Notes", type: "textarea"),
            FormField(id: "priority", label: "Priority", type: "select", value: "Low",
                      options: ["Low", "Medium", "High", "Critical"]),
        ]
    }
}
```

Then both call sites become `FormField.defaultVideoFields()`.

---

## Issue 7 — 🟡 `submitFormFromArchive` builds raw `URLRequest`

**Location:** L429–451

```swift
// ❌ CURRENT — manually sets Authorization header
var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
```

`AuthService` already has `authenticatedRequest(for:method:)` which sets the
Authorization header, Content-Type, and any other standard fields in one place.
If the auth scheme changes (e.g., moving to cookies or refresh tokens), this
call site would be silently missed.

```swift
// ✅ FIX
var request = auth.authenticatedRequest(for: ServerConfig.formURL(asset.id), method: "POST")
request.httpBody = try? JSONSerialization.data(withJSONObject: formData)
```

---

## Prioritized Fix Order

1. **Bug 1** — Continuation guard in `phAssetToTempFile` (crash risk, 5 min)
2. **Bug 2** — Replace `loadTransferable` with `phAssetToTempFile` in `handleReupload` (10 min)
3. **Cleanup** — Delete `parseISO8601` wrapper; use `auth.authenticatedRequest` in form submit (5 min)
4. **Cleanup** — UUID subdir in `handleReupload`; consolidate `buildFormFields` into extension (10 min)
5. **Refactor** — `defer`-based `isReuploadingVideo` reset (low risk, 10 min)

**Total:** ~40 min, no structural changes.

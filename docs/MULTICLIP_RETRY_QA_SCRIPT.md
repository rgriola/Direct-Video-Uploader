# Multiclip Retry QA Script
- Last updated: May 11, 2026 - 2:10pm - GitHub Copilot (GPT-5.3-Codex)

## Scope

Validate multiclip reliability and grouped-form submission behavior for:

- Relaunch-retry flow (app killed mid-batch)
- Partial-failure-retry flow (only failed items retried)
- Grouped-form submit count per asset during QA

## Enable Grouped-Form Debug Logs

Use either method below in Debug builds.

1. Xcode scheme environment variable:
- Key: `DVU_DEBUG_GROUPED_FORM_SUBMITS`
- Value: `1`

2. UserDefaults flag (from LLDB console while app is running):
```swift
expr UserDefaults.standard.set(true, forKey: "dvu_debug_grouped_form_submits")
```

Expected console lines when enabled:
- `[GroupedFormDebug] submit attempt #<n> assetId=<id> slug="..."`
- `[GroupedFormDebug] submit success assetId=<id> attempt=<n> status=2xx`
- `[GroupedFormDebug] ws form:request suppressed assetId=<id> attempts=<n>`

## Test A: Relaunch-Retry Flow

### Preconditions

- Logged in as a normal USER account
- At least 3 videos available in Photo Library
- Stable network at start
- Debug logs enabled (section above)

### Steps

1. Open chat and pick 3 to 5 videos from Library.
2. Tap Upload and submit one grouped context form.
3. Wait until at least one item has moved into upload/apply-form state.
4. Force-quit the app from app switcher.
5. Relaunch the app.
6. Observe batch bubble state and failed-item summary.
7. Tap Retry Failed.
8. Let queue finish.

### Expected Results

- On relaunch, interrupted non-complete items appear as failed with restart message.
- Batch state is actionable (`partialFailed`) and shows Retry Failed.
- Retry only processes previously failed items.
- Previously completed items do not re-upload.
- Debug logs show one grouped-form submit attempt per asset for this retry run.

### Pass/Fail Rules

- Pass: No duplicate grouped-form submits for any asset unless user explicitly retried that asset.
- Fail: Same asset shows multiple submit attempts without retry action.

## Test B: Partial-Failure-Retry Flow

### Preconditions

- Logged in as USER
- 4 to 6 videos selected
- Debug logs enabled

### Steps

1. Start a multiclip upload with grouped form submit.
2. During active uploads, break network briefly (Airplane mode or disable Wi-Fi), then restore.
3. Let queue settle into partial failure state.
4. Confirm some items are complete and some are failed.
5. Tap Retry Failed.
6. Wait for terminal state.

### Expected Results

- Completed items remain complete and are not retried.
- Only failed items move through create/upload/apply-form/complete.
- Final state becomes complete if retries succeed, otherwise remains partialFailed.
- Debug logs increment submit attempt count only for retried failed assets.

## Evidence To Capture

Capture these for each run:

1. Screenshot of batch bubble before retry.
2. Screenshot after retry.
3. Console snippet showing grouped-form debug lines for all affected assets.
4. Note of any assetId with attempt count > 1 and whether retry was pressed.

## Quick Triage Guide

- Duplicate grouped-form suspicion:
  - Check for repeated `submit attempt` lines for same `assetId` without retry action.
- Relaunch recovery not actionable:
  - Verify interrupted items become failed and batch enters `partialFailed` (not stuck uploading).
- Retry touches completed items:
  - Verify coordinator execution order includes only `.failed` items during retry.

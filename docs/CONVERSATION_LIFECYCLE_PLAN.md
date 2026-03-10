# Conversation Lifecycle: "Closed After Follow-Up"

> Plan for: Fun Follow-Up closes the conversation. User taps + to start a new one.

---

-- issue when user navs away and back greeting pops up. should check if its there so its not repeated. OR!!!! update message

## -- time zone issue, make sure time is displayed in the right time zone to the local user not UTC.

## New state: `conversationComplete` (bool on ChatViewModel)

### Step 1 — Mark conversation complete

- After the fun follow-up message is appended, set `conversationComplete = true`
- This is the single gate for the rest of the logic

### Step 2 — Lock the + button behavior

- When `conversationComplete == false`: + button opens VideoLibraryView (current behavior)
- When `conversationComplete == true`: + button calls a new `startNewConversation()` method instead of opening the picker

### Step 3 — `startNewConversation()`

- Clears `messages`, `sentUploadThumbnails`, `sentUploadFileNames`, `sentUploadDates`, `sentUploadHasLocation`, `formThumbnail`, `lastClip`, `lastAsset`, `currentAssetId`
- Sets `conversationComplete = false`
- Sends a fresh `message:connect` to the server to trigger a new greeting
- Chat is now empty + greeting arrives — user is back to square one

### Step 4 — Disable the input bar during closed state

- When `conversationComplete == true`: hide or disable the text input and the + button's "pick video" path
- The + button itself stays visible but its tap action changes (Step 2)
- Alternatively: keep the input bar active only for `#slack` commands (so user can still type `#team-alerts @carrie` to Slack the clip)

### Step 5 — Visual signal

- The fun follow-up already says "Remember you can #Slack the clip from here"
- Optionally dim the input bar or show subtle "Tap + to start new upload" placeholder text
- The View and Metadata buttons on the High Five bubble remain functional

---

## What stays the same

- Server doesn't need changes — it doesn't track conversation boundaries
- WebSocket stays connected (no disconnect/reconnect needed)
- Archive tab history is unaffected — it's a separate concern

## What this avoids

- No complex state machine — just one bool flipped at one moment
- No server-side conversation IDs needed (yet)
- No risk of orphaned uploads — the + button is the only entry point for new video, and it resets cleanly

## Edge case to decide

- If user is mid-upload and app backgrounded/relaunched: `conversationComplete` would need to be derived from the last message type, or persisted to UserDefaults. For demo phase, deriving it from whether the messages array contains a follow-up message is simplest.

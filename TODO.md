# TODO — Direct Video Uploader

> Full project audit — March 3, 2026 · Updated March 7
> **25 of 25 issues fixed. ✅ All clear.**

---

## Completed — March 7

| #      | Feature / Fix                                                                    | Status |
| ------ | -------------------------------------------------------------------------------- | ------ |
| **26** | MessageBubble rewrite — dedicated views per message type + ChatBubbleShape       | DONE   |
| **27** | ContextFormView dismiss prevention — blocks close without slug + description     | DONE   |
| **28** | Server slug/description fallback — uses user.name if form fields arrive empty    | DONE   |
| **29** | Dashboard "missing form" alerts — red border + ⚠️ badge on READY assets w/o form | DONE   |
| **30** | Clip viewer "missing form" alerts — red 🚨 banner on server-rendered page        | DONE   |
| **31** | Admin dashboard rebuilt — fresh Vite build to server/public/                     | DONE   |

---

## Critical — ALL FIXED

| #     | Issue                                                                   | Status |
| ----- | ----------------------------------------------------------------------- | ------ |
| **1** | fileSize type mismatch — Changed Clip.fileSize from Int64? to String?   | DONE   |
| **2** | Infinite WS reconnect loop — Added exponential backoff (max 10 retries) | DONE   |
| **3** | URLSession leak on reconnect — Added invalidateAndCancel()              | DONE   |
| **4** | No auth on admin routes — Added preHandler to all 7 routes              | DONE   |
| **5** | XSS in clip viewer — Added escapeHtml() helper                          | DONE   |
| **6** | Hardcoded JWT secret — Now generates crypto.randomBytes(64)             | DONE   |

---

## Dashboard & Performance

| #      | Issue                                                                        | Status   |
| ------ | ---------------------------------------------------------------------------- | -------- |
| **7**  | Dashboard over-invalidation — Selective query invalidation by event type     | DONE     |
| **8**  | 5s triad polling — Changed to 15s                                            | DONE     |
| **9**  | 6 sequential DB calls in upload — Merged to 3 calls                          | DONE     |
| **10** | N+1 queries in clip viewer — Mitigated by new indexes                        | DEFERRED |
| **11** | Missing DB indexes — Added 3 indexes on FK columns                           | DONE     |
| **12** | Broken mediasource ID sequence — Simplified to CREATE SEQUENCE IF NOT EXISTS | DONE     |

---

## Server ↔ iOS Inconsistencies — ALL FIXED

| #      | Issue                                                                | Status |
| ------ | -------------------------------------------------------------------- | ------ |
| **13** | greeting dead code — Removed onGreeting callback and handler         | DONE   |
| **14** | form:submit dead code — Removed sendFormSubmit() method and call     | DONE   |
| **15** | slack:post event loop — Removed all Slack handlers (Phase 3)         | DONE   |
| **16** | Unsafe JSON in WS sends — sendVideoUpload now uses JSONSerialization | DONE   |
| **17** | pingTimeout less than pingInterval — Swapped to 25000/20000          | DONE   |

---

## Lower Priority

| #      | Issue                                                                    | Status |
| ------ | ------------------------------------------------------------------------ | ------ |
| **18** | Temp video files never deleted after upload                              | DONE   |
| **19** | VideoUploadService URLSession leak — Added finishTasksAndInvalidate()    | DONE   |
| **20** | Upload progress 100ms polling — Now event-driven via URLSession delegate | DONE   |
| **21** | pool.on error silently swallows errors                                   | DONE   |
| **22** | No rate limiting on login — Added @fastify/rate-limit (5/min)            | DONE   |
| **23** | GET /api/assets/:id no auth                                              | DONE   |
| **24** | CORS origin: true in production — Locked to rodgriola.com (HTTP + WS)    | DONE   |
| **25** | Admin ChatHistory shows only own messages — Added /api/admin/messages    | DONE   |

## USER TODO do not modify below this line >>>>>>>>>>>>>>>>>>>>>>>>>

iOS APP

- Conversation Button - List of Previous Conversations [see image conversation-list.png]
  - Should show Video Thumnail - Upload Date - Time - Location ie Boston, MA; Syracuse, NY

- [] When opening app + server not available need app messaging to notiffy user.
  - iOS should know if its connectivity or server issue or credentials

**_ TASK _**

- Change default iOS Text-Area Behavior when user opens iOS.

**_ Context _**

- Default Text Area, Conversation is too busy with old text messages.

**_ Instructions _**

- One Conversation = One Upload (for now)
- Always open to new conversation (since this is one server)
- When user opens App - Conversation UI should have 1 message. "Good Morning [User First Name]..." This is continget with iOS and Server handshake. - if waiting for connection use "..." Icon - then Change to Greeting like a actual text message.
- Previous Messages should be removed - One conversation = One Upload.

- [] When iOS opens the chat-view should be clear of previous texts - this keeps chat-area UI clean/focused.
- always starts with > "Good [Morning] [David]. I'm ready for your video" {Greeting}

- Names of Specific Server Chats and User Response. {Name of Text Type}
  Text Flow

- Updates to User Video Choice in Library View - Similar to iOS 26.3

**_ TASK _**

- Add iOS 26.3 UX to Library View when user chooses video.
  **_ CONTEXT _**
- User needs a familiar UX and UI for choosing videos. Currently we are missing some UI buttons and UX.

**_ INSTUCTIONS _**

- Library UI needs a "Clear" and "Confirm" (check) Buttons at top of Panel. Similar to iOS 26
  - add a "Clear" Button; action should clear video choices from Library UI allowing user to start again. a reset.
  - add Confirm "Check Icon" Button; action should 1) Add Video to Text Chat for Preview (remove auto send to server) 2. Close the Library, return to chat, if No Video is Selected. Similar to iOS 26 UX.
  - User will confirm upload to server in text message, like a actual text flow.
  - Bottom of Library UI should note the # of Videos Selected and if locations are included in the video.
  - Text Preview should show Video Thumbnail + Original File name and Created Date.

- User

"Good [Morning] [David]. I'm ready for your video" {Greeting}

                                   [USER ACTION] {User Clicks + Chooses Video}
                                                       {Upload}
                                   [TEXT VIEW] User should see video send preview with universal cancel "X" button

"Got it!! Processing your upload..." {Confirm 1}

                                                  [USER GETS METAFORM] {Sheet}

"Here are your Video Details"
[Shows Metadata]

- [x] User should see a clear Blue Check on the Video Thumnail > then use Confirm Button to start the upload (this is currently a select and shoot method)

- [x] Between "Good Morning... " and "Got it!" ... The user needs to See their upload Thumbnail and Metadata. The User always needs to know where they are in the communication chain.

- [x] Selecting a Video in the Library should show Video Only for now.

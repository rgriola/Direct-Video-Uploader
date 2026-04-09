First, I am really excited about this app. I believe Fixer can solve several workflow issues and, if successful, eventually offer additional features for CNN journalists.

About the Fixer app:

Fixer is an iOS app designed for uploading video directly to Mediasource. It solves several key workflow issues:
    •    Direct Uploads: Enables video transfers directly to Mediasource, removing the current three-step manual process in Slack -> Mediasource. 
    •    Original Quality: Video is sent lossless in original iPhone quality, avoiding the compression Slack applies during manual uploads.
    •    Automated Metadata: Reads all EXIF data and merges it automatically with the Mediasource sheet.
    •    Simplified Input: The user only needs to add a Slug and Description.
    •    Slack Integration: Metadata can be directly sent to channels i > #storms - or producer > @carrie.smith. The direct alert provides the upload Mediasource ID > a “copy" button, and a "View Clip” button > the Mediasource URL.

Added Features:
Clip editing - Long clips can cut down and then uploaded.
Transcribe - Optional Transcribe feature will add the transcription to the metadata form.

The piece I am missing is the Mediasource API endpoint—specifically, the protocol for how Mediasource receives video, generates IDs, and tracks/coordinates assets. 

The Fixer dev setup utilizes a Mediasource stand-in via Mux, a process server on Render/Postgres(managing Mux events and the database), and a connection between the Fixer Dashboard and the iOS app. My current stack and workflow represent an educated guess as to how the production backend works with Mediasource.

    •    Repo: github.com/rgriola/Direct-Video-Uploader.git
    •    Live Dashboard: ms-fixer.com
    •    iOS: Available on TestFlight

Known Issues:
    •    Server/App Connection: The connection resets visually in the Chat Area. This occurs during a reconnect when a user opens the app or switches back from another application.
    •    Archive: Requires a UI update.
    •    Chat Area: Experiencing inconsistent messaging and UI refresh issues.
    •    The demo app currently uses basic authentication (test account phone number + PIN)

Future:

- Start/Stop handling for unfinished uploads or cancelling uploads.
- Mediasource iOS search.
- Managing User Assets
- iOS viewer for clips
- Archive conversations (uploads)
- Apple Audio Translation for Video - iOS native.
- Multiclip Uploads (10 Min Upload per clip) iOS limitation.
- External Chip Upload w/o iCloud
- URL Uploads
- Profile, Permissions avatars
- WBD Auth managed phone tracking logins
- Text alert, email alert
- Badge Alert
- Background Upload

Tracking

- iOS version tracking, error tracking, feature use tracking

Retained Features:

- Pick and Edit Clip
- Single Clip Feature

TEXT UI

- Text Messaging is a stanard communication tool, it is a social interaction, its use here is intended to add a personality and connection.
- Fixer talks the user through the upload process with step by step guidence like a partner in the process.
- When a user emotionally connects with tech it is embraced more, this is a basic product design principle and should be implimented in enterprise products.
- The goal is adoption and self guided training of this app - people want to use it.
- Slack integration is critical because most editoral communication happens on Slack channels and threads. Our previous video control methods take us out of the Slack UI and connection - no bueno. Good idea's wrong platform.

**_ Task _**

- on iOS app conform video confirmed bubble font sizes to the same as the other message bubbles
- Mediasource number should look like the High Five Text witgh the Link Icon.
- Move View button to float to the right placing it on the same line as the Mediasource Link.

### known issues

### to the agent

- this file is not to be edited. I use this to track issues I find and catalog them. 
- I may add notes about my thinking on this project but these are not cannonical just working through details.
- I share this with you because I want you to be successful.

# Issues
Apr 30 2026
- Add Photo Pipeline and File Pipeline
- Add custom url and instructions for connecting to customer storage, list requirements for successful storage.  Create instructions to create AWS S3 Bucket, or other storage platforms.
- Add feature to upload video cards directly from the camera, this would require reading metadata, idenifying files structure and naming conventions for specific camera brands ie Sony, Canon.  This is part security feature to protect the integrity of the footage, ie Cameras are registered to specific photographers, even cards have serial numbers.
- Filter videos for video feeds. 

- While there is an active the server and iOS continue to handshake. This process is ok however we need to add logic to 
supress the handshake message while there is an active upload in progress, that is bits being transfered to the video server.
this creates a continous stream of messages when the user is just going back and forth between apps. 

*** Upload/Error State is handled by server but does not sufficiently represent video upload state and messages can be mixed up. This is only solved by one system server or iOS controlling the messages ie; Controls the order and serves the correct message, if the video is already processed sends a modified metadata chat.
- Timing issues with messages

*** Chat UI Reset ***
For a better UX the chat UI should reset after a video is selected. We could use a Panel Noting "This conversation moved to Archieve". This clears the UI, new greeting message "You are working hard today Rod...ready for video bits." This will give a better Experience.  

*** Fixer Chatting
- The entire chat chain is stateless, so it doesn’t know what the previous message was.   This can be addressed after resources are opened
- ideally the entire text chain is moved to iOS with the server only sending codes to display specfic messages. this will accomplish a important points
1) centralize the text message styling to one system. Currently the server has messages styled by web markup intermixed with swift markup. Once centralized styling. 
2) Simplify Upload stage management. Because messages are centralized and triggered by server codes iOS can contain the logic to either display or suppress or alert codes. 


*** Trim View ***
- Improve trim controls:
1) add time position for play head. Currenly there is a Time for beginning 00 - End ie 17:00, but the playhead position is not displayed. 
2) a way to display timecode, this is helpful to add notes. 
3) A button to add time marker
4) Option to save clip as a new clip leaving the orginal untouched. 
5) option to bypass entirely the trim feature 

*** Video Queued + GPS remain in the Library Photo Picker even if video is deselected *** 
- We worked on this before and there was some improvement. What remains is the "video queued" and "GPS" text when the user deslects a clip entirely. What should happen is these text are reset to the orginal state like when the library panel opened. 

### Features Future 
- Photo upload path
    1) Context Form Fields : Assignment, File Meta, Timestamp, Username, Phone, Email for chain of custody. Each Photo Gets Metadata, Caption. 
    2) Grid Display for Picker - Filters Photos only. 
    3) Processes Photos to JPEG if not already JPEG

- Audio upload path 
    both set by Admin Panel to control send feature. Grid display, May need custom for audio. No Compression to keep integrity of files. Context Form for Assignment. 

- SD/HD File upload path. Choose multiple files, alow individual clip editing if file is supported. MXF anyone? 
- Estimated time upload so user knows not to close APP.

- Camera to Server

- Mediasource Search
- Mediasource Viewer (for feeds)

*** issue ***
- Apple Developer Account Distribution Approval Rejection
- The Fixer, this iOS app, is being rejected by the App store for distribution. 
- This is the following reason they specifically provided:
[apple email]

- Can you review this app, dashboard and try and determine what changes need to be mad to allow wide public distribution?

- I believe allowing users to sign up for an account using their own credentials (email/password) account creation. 
- Allowing a user to sign up as an enterprise user (email/password) account creation. 
- allowing users to provide their own URL's for cold video storage (AWS S3, Google Cloud Storage, etc.) and URL for Streaming Processing similar to Mux.com but using their own credentials and storage, not my account. 
- Allowing Free Use for 7 days trial period. 
- Allowing Pro account after this period per seat for a fee

- Issue with the above. The app was designed for a Test Case and interface with MUX and its webhooks.  
- How would our biz logic change for iOS. We could bypass just to help upload video to cold storage for example and create a context form file to be placed on their storage with the two pieces linked, same name but different extension.

- Any guidence would be apprecitated I am open to suggestions.
- Or would it be better just to move this to enterprise? Or should I just nail down the testflight path before I get larger company asssets .   
- I need to demo this for staff not in my city over Zoom and I want to give them access but have and impossible time walking people through the testflight > demo app process. 
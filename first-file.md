### SPEC

### to the any agent

- this file is not to be edited. I use this to build out prompts for you.
- I may add notes about my thinking on this project but these are not cannonical just working through details.
- I share this with you because I want you to be successful.

**_ TASK _**
Spec out a project for Video direct to Server Upload with Context using Cellphone (iOS).

**_ DETAILS _**

- Use standard phone number 800-123-4567
- Upload Video immediately
- Server Sends you back a form to click and fill out, you send back to the server Upload done.
- Server REJECTS any access from unregistered phones.
- Background work - phone uses its own uploading to send to server catch with Phone data - Work Phones are known devices and hard to fake (I think)
- Server grabs user data and pre populates a farm which is sent back to the phone.
- User can change and add some data
- Server Will read Meta from video file ie GPS, TIME STAMPS, PHONE DATA, RECORD TYPE adding meta to the form
- User gets a confirmation text with URL to Specific Clip.
- Clip confirmations and errors are handled with text to phone, email to user and current media handlers and/or others (can be sent to a @team or #slack)

...

PROJECT_SPEC.md
The only difference is this process starts by using the Texting App - Messages. literally using the server phonenumber > opening the iOS image library to send the video to the server the same way I would send a video person to person. Does this change the this spec plan? I do like the stream to server option as well.

....

Open file:///Users/rodczaro/Desktop/00-Vibecode/Direct-Video-Uploader/chat-demo.html.

1. Look at the conversation flow. Check if the bubbles look correctly spaced and aligned.
2. Specifically look at the "Mediasource Fixer" header and the messages.
3. Click "View Metadata 📊" in the last message. Does the sheet look correct? Are all values visible?
4. Click "Here is your video" (the green button). Does that sheet look correct?
5. Look for any overlapping text or weird gaps.
   ...

**_ Task _**

- Review the PROJECT_SPEC.md and make sure it is up to date with the latest changes.

**_ Instructions _**

- Update PROJECT_SPEC.md with the latest changes.
- prepare to a phased planning document to build out a live demo of this project. We are going to discuss it and you will help me plan it out.
- Auth - for the demo we can use a simple auth system.

**_ tech stack issue _**

- We need to socket the server connection not hard code it.
- What tech do we need for our demo server to respond with confirmation messages, forms and links to the clip? I do not want you to build out a video server for this since there are already services for that. Just a live proof of concept demo. I am open to a streaming service since we are not going full prodcution like cloudflare.
- at some point we will need an Admin UI to manager the app backend and user data.
- What host servce do we need to run this demo? I have Vercel and Render hosting right now. If this cannot have a serverless database we will use render.
- I would like an iOS demo of this project.
- minimum web app to show the clip and metadata.

...
**_ response to dashboard questions _**

1. Are all 4 stat cards showing data? Yes
2. Are users listed correctly? Yes (3 total)
3. Are assets listed? (Dashboard showed assests uploading but did not show them on the server)
4. Is the WebSocket connected (green dot)? (yes)
5. Is the activity log showing entries? (yes, again does not show assets on the server - confrimed upload)
6. Do the Quick Action buttons work? (yes)

...

Xcode project setup — Do you already have Xcode installed and ready?
YES installed.

I can scaffold a SwiftUI project via command line, or would you prefer to create it in Xcode and I'll populate the files?
XCODE CLI should be installed. Do as much set up as possible before I need to get involved.

Socket.IO vs native WS — The spec recommends Socket.IO Swift (matches our server).

That means adding a Swift Package dependency (socket.io-client-swift). Are you good with that?
YES - although I am thought we are using native WS, I am open to using Socket.IO Swift if it is better.

Scope for today — Do you want me to:
(A) Scaffold the full Xcode project structure with all files (Views, Models, Services) and build incrementally
YES

Target — iPhone only? Or also iPad?
This is iOS iPhone for now.

...

**_ issue _**

- This demo had a coordination issue.

**_*context*_**

- This project requires the database, server, admin page working in concert. I will call these parts "the triad". The user, me, must push a build for the working iOS app for testing.

  **_ instructions _**

- for the Demo create one - npm run dev - command that coordinates the launch of the triad.
  a) this should include any migrations or prisma schema updates. b) This command should check if there are instances of each running if yes shut them down so the final command can launch all three parts together.

- The triad should have neutral fallbacks if a service is not available, the console log and/or terminal reflect the state ie; If there is no current iOS app connected to the server it should state this in the terminal and dashboard log. This action should be applied to all services that are not available. This is about understanding what works and what does not.

- Dashboard current state must be live - not simulated - ie; if there are no logged in users it should state this, if there are assests uploading the dashboard should state show this. Currently it shows 3 active demo users but 2 have never logged in.

- Remove all simulated actions from the dashboard so we can see accurately assess the current state of the triad.

**Outcome**

- Clean and accurate triad so both user and agent can understand the state of the project.
  ....
  TBD
  **_ Minor Change to Respone _** In the message chain "I can't text just yet... " I would like that response to Insert the Users name ie; "Hi David, I can't text just yet..." In production would the repsonses work better if they were on the device as part of the App build? Then the server sends a code response rather than data or is this irrelevant.
  ...

**_ Issue _**

- Dashboard data is stale at times and not coordinated with the server.

**_ context _**

- we have made many changes since creating a demo yesterday. Some panels are out of date or not updating

**_ Instructions _**

- Evaulate the dashboard to find relevant UI panels
- make sure those panels are still showing fresh data
- remove any simulation checks, buttons UI. Only real data.
- Look specifically at Quick Actions some buttons do not show data ie; Chat History shows a toast but does NOT show the actual text history. This may be the result of updates we made.
- this is important becuase both you and I need to know what works and what does not.

...

**_ Issue _**

- drill down the server responses

**_ Context _**

- The responses represent the Video Upload workflow.
- the User knows texting and expected responses in their life.

- The upload flow here starts with "Hello David..." To the user this acknowledges the relationship. For Business this should only mean "The Device and Upload Server see each other and are talking." rather than just a general greeting.

- We should build in to the server response tolerance. So should the user type "Hi" or a message the server should wait incase the user uploads a video then supress the general "I cannot text ..." response. A user could overwhelm the server. This may be more complicated however we want beable to absorb odd texts.
- We Could add a "Hi David... I cant' text but I'm ready for your video.

> > > this assumes authenticated user <<<
> > > [Server] 🙋‍♂️ Good Morning David! I am ready for your video.
> > > [USER] >>> Uploads Video Video-1234.mov <<
> > > [iOS UI] {Shows Video in Text Chain}

--- SOME OF THIS COULD BE DONE iOS APP A FORM of front end SECURITY ie; not a video file, or badguy upload virus check, no exif no video type data, no mime type etc, no phone id.

> > > [SERVER] [PERFORMS SECURITY CHECK is this video? YES/NO] >> passes >>
> > > [Checks for METADATA]
> > > [PULLS METADATA]
> > > [ADDS METADATA TO Mediasource Form]
> > > [RETURNS FORM to USER in iOS Text]
> > > [VIDEO PROCESSING BEGINS]
> > > [USER] Fills out form >>
> > > [iOS] Validates Requied Fields >> Sanitizes Text Inputs
> > > [USER] SENDS FORM
> > > [SERVER] Validates Requied Fields >> Sanitizes Text Inputs >> PROCESSES >> Turns Form into Media Source ASSET Sheet >> Generates Mediasource Number
> > > [SERVER] Texts back Mediasource Nummber in URL Link to Asset. note: The Media Source Sheet becomes the web interface for the Asset with the video asset in the a Window to be viewed. This should be handled by the Mediasource system but we can create a mock up in Admin
> > > [USER] Optional > Texts @ or # to post Mediasource URL to their slack workspace - this assumes USER is logged into thier workspace. in the Context of this Text Chain the @ or # would use the Mediasource URL in the Chain. (SLACK INTEGRATION should add red/green light on iOS APP Slack is connected to avoid USER needing to do this Mid Text OR a NOTICE on LOGIN ASKING if they want to LOGIN to Slack)
> > > [SERVER] TEXT RESPONSE With Full Picture FINAL Confirmation the Processing in Done.

...

**_ Task _**
Review and Update >>>

MetadataView sheet, ContextFormView, metadata extraction, and Slack button are all wired but untested on device.

MetadataView sheet — After a video is uploaded, the server extracts technical details from the clip (GPS coordinates, capture date, device model, codec, resolution, orientation, duration, file size). In the iOS app, tapping "View Metadata" on a confirmation message slides up a dark-themed sheet (MetadataView.swift) displaying all of that as a formatted card — like a fact sheet for the video file itself. This is read-only; the user sees it but doesn't edit it.

[SERVER TEXT] Should be sent with button to show Metadata VIDEO DETAILS (read-only).

**_ Task _**

- Update MetadataView sheet and ContextFormView

** Instructions **

- metadata extraction - get all the meta we can off of a file and save it to the database and populate the form.
- Update to Metadata View - Screenshot 2026-03-03 at 5.08.43.png The Server Upload Response Look 1) USER Name 2 ) Original File Name (not processed UUID) 3) mediasource 9 digit number assigned incrementally. We should have on our DB a mediasourceID field where we pull this from when creating the video asset. Eventually this number will be populated from the company system 4) Highlight Metadata: GPS Coordinates, Created Date (date the file itself was created most likely always the production date), Video Codec ie; 4k, 1080p, 720p - Original File Metadata. But we should capture all available metadata on the video file.

- The ADD DETAILS button Change that to SHOW DETAILS and show all Metadata Available. 99% of users will never look at it but its cool to have and add.
- We need to have a plan for Video Files with no Metadata aside from Time Stamps and a Filename. In this case MetadataView should Say "No Meta Found" add in Mediasource.

- ContextFormView — After the server processes the video and extracts metadata, it pushes a form:request event back to the iOS app. This triggers a slide-up form sheet (ContextFormView.swift) with two sections (kill the first section and simplify the second seciton. The Reason is the Metadata is more for backend use rather than the point the user is uploading)

User Input [Editable] - This should be simple like Sceenshot 2026-03-03 at 5:10.14.png

1. Layout like the attached png at the top: Thumbnail left - Original File Name - Created Date
2. Slug Name
3. Type of Video Raw or Cut
4. Description
5. Keep Priority for now.

Slack Button
Remove this feature. We will have the USER do this in the text.

The user fills in the editable fields and taps Submit. This is the "context" the newsroom needs — what is this video, and how urgent is it?

...

**_ Task _** (done )

- review the project and develop tests for the project.

**Context**

- We have a working demo of the project.
- We have not run substantial testing any specific areas.
- I am looking for speed improvements for the Dashboard, Server i/o, and improving reliability.

**_ Instructions _**

- Show me a plan for agent testing the project, place into a markdown, no coding.
- review copilot-instructions.md for technical guidence,
- Review TRIAD.md, PROJECT_SPEC.md, PROJECT_STATUS.md
- We cannot make technical changes yet unless those would improve produciton.
- this target for concurrent users is 1000.
- I am open to suggestions.

....
**_ TASK _** (done)

- Change default iOS Text-Area Behavior when user opens iOS.

**_ Context _**

- Default Text Area, Conversation is too busy with old text messages.

**_ Instructions _**

- One Conversation = One Upload (for now)
- Always open to new conversation (since this is one server)
- When user opens App - Conversation UI should have 1 message. "Good Morning [User First Name]..." This is continget with iOS and Server handshake. - if waiting for connection use "..." Icon - then Change to Greeting like a actual text message.
- Previous Messages should be removed - One conversation = One Upload.

... actual flow Needs to flip

1. User picks video in iOS app
2. iOS → POST /api/assets → Server creates Asset (UPLOADING) + Clip shell
3. iOS → POST /api/assets/:id/upload → Server saves file, creates Clip (READY),
   marks Asset = READY
4. Server → WS upload:complete → iOS shows metadata
5. Server → WS form:request → iOS opens the form sheet
6. iOS → POST /api/assets/:id/form → Server saves FormResponse, confirms
7. Server → WS form:confirmed → iOS shows "High Five" confirmation

Actuall Form
Upload starts → Form shown immediately (parallel)
↓ ↓
Video processing User fills form
↓ ↓
Both complete → Asset finalized
error handling
...

**_ TASK _**

- Changes to iOS Add Details Form

  **_*CONTEXT*_**

- Add Detail User Form is Almost Ready

  **_ Instructions _**

- Change all text to white on form.
- Form background can be 50% lighter in color. - looks like chat area, need to visially show state change.
- Add thumbnail image to clip detail - should come from video info - i believe or apple process.
- Slug and Description are requried fields. The Form should not submit without these fields being validated.

- add a red asterisk to SLUG* and DESCRIPTION*
- Slug and Description must be sanitized only allowing Letters Numbers - .
- Priority should default to Low.

.. add
**_ TASK _**

- User Upload Card should stay in the Text Chain Flow as confirmation to the user and action has taken place, the Up Arrow can be a "Sent" or Green Check Mark.
- The server message "Got It! Processing ..." should show some basic Metadata like the mediasource number and link, file name, Creation Data. Again a confirmation of the process working. This should only be trigged once the Form is submitted.

In the Text Flow Right After the greeting my Upload should be in the Text Chain. This shows the upload at least was started. -> then once the upload and form are submitted >> Got It!!! Message.

**_ TASK _**

- iOS App add 2 buttons to the High Five last message "View" and "Metadata" Green and blue.

**_ INSTRUCTION _**

- View button should link redirect to the asset to the browser viewer ie; http://localhost:3000/clips/img-6278-f11519 rather than mediasource.com (which is not affiliated with this project) localhost:3000/ << this is dev only not production >>
- Metadata Button should show a form woth all the Meta for the clip starting with slug, type, description.

.....

**_ Issue _**

- iOS URL on final text confirmation chat is incorrect.

**_ Context _**

- This is iOS url and is incorrect. Found on "High Five" bubble
  > > > https://rodgriola.com/clips/Spill%20
- Url in the dashboard which is correct and resolves
  > > > https://rodgriola.com/clips/img-6278-eec88a

**_ Instructions _**

- Find the root of the issue
- I think for the iOS app these url's are hard coded by view or function. These paths and how they are appended need to be in a unified location and imported properly - reused.
- Doing this will make maintenence easier
  .....

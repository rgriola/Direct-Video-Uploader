### known issues

### to the agent

- this file is not to be edited. I use this to track issues I find and catalog them. 
- I may add notes about my thinking on this project but these are not cannonical just working through details.
- I share this with you because I want you to be successful.

# Issues
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
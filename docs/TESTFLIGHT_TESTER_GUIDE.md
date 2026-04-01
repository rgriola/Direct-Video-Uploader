# TestFlight Tester Guide — Email Template

> Copy-paste the email below. Replace `[YOUR INVITE LINK]` with the actual TestFlight link from App Store Connect.

---

## Subject Line

**Action needed: Install Fixer test app on your iPhone (3 min)**

---

## Email Body

Hey team,

I need you to test the **Fixer** app on your iPhone. It takes about 3 minutes. **Do all of these steps on your iPhone** — not your Mac or iPad.

### Step 1: Install TestFlight (1 min)

TestFlight is Apple's official app for testing apps before they go to the App Store. It's free.

👉 **Tap this link ON YOUR iPHONE:**
https://apps.apple.com/us/app/testflight/id899247664

Tap **Get** → install it. If you already have TestFlight, skip to Step 2.

### Step 2: Accept the Invite (30 sec)

👉 **Tap this link ON YOUR iPHONE:**
[YOUR INVITE LINK]

This will open TestFlight automatically. Tap **Accept** → then tap **Install**.

> ⚠️ **If the link opens in Safari and shows a code:** You may see a redemption code on the webpage. Tap "Start Testing" on that page — it will redirect you into TestFlight. If prompted, paste the code into TestFlight.

### Step 3: Open the App

Once installed, you can open Fixer two ways:

- Tap **Open** in TestFlight, or
- Find the **Fixer** app icon on your home screen (it will have an orange dot indicating it's a test build)

### Your Login

- **Phone:** (your phone number)
- **PIN:** 1234

---

### Troubleshooting

**"Link doesn't work" or opens a blank page**
→ Make sure you're tapping the link on your **iPhone**, not your Mac. The link only works on iOS.

**"Unable to Install"**
→ Your iPhone needs **iOS 17 or later**. Check: Settings → General → About → iOS Version. If you're on iOS 16 or earlier, update first.

**"TestFlight says the build expired"**
→ Builds expire after 90 days. Let me know and I'll push a new one.

**"I don't see the app after accepting"**
→ Open the **TestFlight** app directly. The app should appear in your list. Tap **Install** next to it.

**"It says I need to be invited"**
→ I need to add your Apple ID email to the tester list. Reply with the email address you use for your Apple ID (the one on your iPhone at Settings → tap your name at the top → it's shown under your name).

---

### Quick Reference: How Updates Work

When I push a new version, you'll get a notification from TestFlight. Open TestFlight → tap **Update**. That's it.

Thanks for helping test!

---

## Notes for You (Rod) — Don't Include in Email

### Adding Testers in App Store Connect

1. Go to https://appstoreconnect.apple.com
2. Select **Fixer** → **TestFlight** tab
3. Under **Internal Testing** (for your team, up to 100 people):
   - Click the **+** next to your group → add their Apple ID email
   - They'll get an automatic email from Apple with an invite link
4. Under **External Testing** (if you want a shareable link):
   - Create a group → Add testers or enable **Public Link**
   - Public link: anyone with the URL can join (no email needed, up to 10,000)

### Internal vs. External Testing

|          | Internal                            | External                             |
| -------- | ----------------------------------- | ------------------------------------ |
| Who      | App Store Connect users (your team) | Anyone with an email/link            |
| Limit    | 100 testers                         | 10,000 testers                       |
| Review   | No App Review needed                | First build requires Beta App Review |
| Best for | Co-workers                          | Wider beta                           |

### If Co-Workers Still Struggle

The #1 issue is people opening the link on their Mac. If someone is stuck:

1. Tell them to **text themselves the link** and open it from Messages on their iPhone
2. Or tell them to **long-press the link** in the email on their iPhone → **Open in Safari** → it will redirect to TestFlight

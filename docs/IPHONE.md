# Cadence for iPhone

The iPhone app (`iOS/`, Xcode target **CadenceMobile**, bundle ID `com.ryanpark.cadence.ios`) shares the Mac app's data model and sync code (`Sources/Model`, `SyncService`), so it uses the same account as the Mac and the website.

It has five tabs:

- **Today:** tasks, habits, items kept until done, and the day's schedule.
- **Habits:** the tracker grid, streaks, and "never miss twice".
- **Week:** a 7-day agenda.
- **Focus:** timed sessions with points and levels.
- **More:** To-Do, Reflections, Account (including **Delete account**) and Settings.

Reminders are planned ahead as local notifications. There's also a morning check-in and a badge on the app icon showing what's left today.

Google Calendar, Calendly, Google Tasks, booking and screen time are set up on the Mac or the website. Whatever they bring in syncs to the iPhone.

---

## 1. Run it in the simulator

```bash
cd ~/AI_project_2026june/cadence
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project Cadence.xcodeproj -target CadenceMobile -sdk iphonesimulator26.5 -configuration Debug \
  SYMROOT=$PWD/build/ios ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets build
xcrun simctl boot "iPhone 15 Pro"
xcrun simctl install booted build/ios/Debug-iphonesimulator/Cadence.app
xcrun simctl launch booted com.ryanpark.cadence.ios
open -a Simulator
```

`EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets` only works around this Mac having no simulator runtime that matches the iOS 26.5 SDK. Real builds keep the icon.

Debug-only launch options:

| Option | What it does |
|---|---|
| `-demo` | Loads sample data, used for the screenshots |
| `-server <url>` | Points sync at another server |
| `-login <user> <pass>` | Signs in on launch |
| `-tab <0–4>` | Opens a tab |
| `-open edit\|reflect\|newhabit` | Opens a sheet |
| `-noNotifyPrompt` | Skips the notification permission prompt |

To let Claude open the live simulator panel, point the command-line tools at Xcode once:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

---

## 2. Put it on your own iPhone, free

A free Apple ID can install apps on your own devices. The catch is that the app stops opening after **7 days**, and then you plug in and press Run again. You can have at most 3 apps installed this way.

1. In Xcode, open **Settings › Components** and download the **iOS 26.5** platform. It's free, and it's needed for real devices and for uploading.
2. In Xcode, open **Settings › Accounts**, click **+**, and sign in with your Apple ID. This creates a "Personal Team".
3. Open `Cadence.xcodeproj`. Select the **CadenceMobile** target, then **Signing & Capabilities**.
   - Tick *Automatically manage signing* and set **Team** to *Your Name (Personal Team)*.
   - If Xcode says the bundle ID is taken, change it to something unique, e.g. `com.yourname.cadence`.
4. Plug in your iPhone and unlock it.
   - On the iPhone, turn on **Settings › Privacy & Security › Developer Mode**. The phone restarts.
   - Tap **Trust** when the phone asks.
5. In Xcode, pick your iPhone as the run destination and press **Run (⌘R)**.
6. The first time, iOS blocks the app. Allow it in **Settings › General › VPN & Device Management**: tap your Apple ID, then **Trust**.

For other people, also free: they can open https://cadenceplanner.vercel.app in Safari, tap **Share › Add to Home Screen**, and use the web app like an app.

---

## 3. Publish on the App Store ($99/year)

There's no free way onto the App Store. It requires the **Apple Developer Program** at US$99/year. Apple waives the fee only for nonprofits, accredited schools and government bodies.

### a. Enroll
1. Go to https://developer.apple.com/programs/enroll/ and sign in with an Apple ID that has two-factor authentication.
2. Enroll as an **Individual** using your legal name; it's shown as the seller on the store.
3. Pay the fee. Approval usually takes 1–2 days.

### b. Create the app record
1. Open https://appstoreconnect.apple.com and go to **Apps › + › New App**.
2. Fill it in:
   - **Platform:** iOS
   - **Name:** "Cadence". If that's taken, try something like "Cadence: Habits & Reflection".
   - **Primary language:** English (US)
   - **Bundle ID:** `com.ryanpark.cadence.ios`. Xcode registers it the first time you build with your paid team.
   - **SKU:** anything, e.g. `cadence-ios`
3. In **App Information**, set:
   - **Category:** Productivity
   - **Privacy Policy URL:** https://cadenceplanner.vercel.app/privacy
   - **Content rights:** no third-party content
4. Complete the **Age rating** questionnaire. Everything is "None", which gives 4+.
5. In **Pricing and Availability**, choose Free.

### c. App Privacy ("nutrition label")
In **App Privacy**, click **Get Started** and answer that data **is collected**:

- **User Content › Other User Content:** your tasks, habits, reflections and focus sessions. Linked to the user, used for App Functionality, not used for tracking.
- **Identifiers › User ID:** your Cadence username. Linked to the user, used for App Functionality, not used for tracking.
- Nothing else: no tracking, no analytics, no ads.

This matches `iOS/PrivacyInfo.xcprivacy`, which is already in the app.

### d. Version page
- **Screenshots:** upload `docs/app-store-screenshots/iphone-6.7-1…4.png`. They're 1290 × 2796, which App Store Connect accepts for the 6.7"/6.9" iPhone slot.
- **Promotional text:** Plan your day, build habits that stick, and reflect on what you finish.
- **Description:**

  > Cadence is a daily planner that keeps you honest. Check off your list, and every time you do, write a short reflection — they add up to a record of how you work best.
  >
  > • Today: your tasks, habits and schedule in one place
  > • Habits that stick: stack new habits on old ones, replace bad ones, keep streaks, and never miss twice
  > • A habit tracker grid and identity "votes" inspired by Atomic Habits
  > • Tasks that stay on your list until they're done, with due dates
  > • Focus mode: set a timer, race your list, earn points and level up
  > • Reminders that find you, plus a morning check-in
  > • Syncs with Cadence on the Mac and the web
- **Keywords:** planner,habits,habit tracker,checklist,to-do,reflection,journal,focus,routine,productivity
- **Support URL:** https://cadenceplanner.vercel.app
- **Copyright:** 2026 your name

### e. Build and upload
1. In Xcode, select the **CadenceMobile** target. Under **Signing & Capabilities**, set **Team** to your paid team.
2. Set the run destination to **Any iOS Device (arm64)**.
3. Choose **Product › Archive**.
4. When the Organizer opens, choose **Distribute App › App Store Connect › Upload**.
5. The build shows up in App Store Connect after 10–30 minutes. Optionally, send it to TestFlight first to try it on your phone.
6. On the version page, pick the build.
   - Under **App Review Information**, give the reviewer a test account you created on the website (username and password).
   - Add a note: "Sign in under More › Account to see syncing; the app also works without an account."
7. Click **Add for Review**, then **Submit**. Review usually takes 1–3 days.

### Review rules the app already handles
- **Account deletion (5.1.1(v)):** More › Account › Delete account.
- **Minimum functionality (4.2):** it's a native app, not a website wrapper.
- **Sign in with Apple:** not required, because Cadence uses its own accounts and no third-party login.
- **Export compliance:** set to HTTPS only (`ITSAppUsesNonExemptEncryption = NO`), so there are no export questions.
- **Privacy manifest:** `PrivacyInfo.xcprivacy` is included.

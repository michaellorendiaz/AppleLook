<p align="center"><img src="Resources/AppIcon.png" width="128" alt="AppleLook icon"></p>

<h1 align="center">AppleLook</h1>

<p align="center">Copy your Outlook work calendar into an iCloud calendar you can share with family.</p>

<p align="center">
  <a href="https://github.com/michaellorendiaz/AppleLook/releases/latest/download/AppleLook.zip"><img src="https://img.shields.io/badge/Download%20AppleLook-for%20Mac-2EA043?style=for-the-badge&logo=apple&logoColor=white" alt="Download AppleLook for Mac"></a>
</p>

<p align="center">
  <a href="https://github.com/michaellorendiaz/AppleLook/releases/latest"><img src="https://img.shields.io/github/v/release/michaellorendiaz/AppleLook?label=version" alt="Latest version"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-555555" alt="Apple Silicon and Intel">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

> **Never used GitHub?** Click the green **Download AppleLook** button above, then follow [Install AppleLook](#2-install-applelook) below. You don't need a GitHub account.

AppleLook is a small Mac menu-bar app that copies Outlook calendar events into an iCloud calendar. Why not just subscribe to the Outlook link in Calendar, you ask? Well, a subscribed calendar can't be shared through iCloud Family Sharing. A real iCloud calendar can, which is exactly what this app makes. Paste the Outlook calendar sharing link for your calendar, pick an iCloud calendar, and AppleLook keeps that calendar up to date every 15 minutes. Share the iCloud calendar with your family in the Calendar app, and they see when you're in meetings. You can choose whether they see the meeting names, "Busy", or a custom label.

> **Have an always-on Linux machine or Home Assistant?** [AppleLook Server](server/) does the same job from a Docker container with a web settings page, and keeps syncing while your Mac sleeps.

> **Early preview.** This works on the developer's Mac but hasn't been widely tested yet. It only ever changes events it added itself, so it can't damage your own calendar.

## What you need

- A Mac running macOS 14 (Sonoma) or later, signed in to iCloud with **Calendars** turned on (System Settings → your name → iCloud → Calendars).
- An Outlook / Microsoft 365 work calendar you can open in a web browser.

## 1. Get your Outlook calendar link

1. Open [Outlook on the web](https://outlook.office.com/calendar) and sign in.
2. Click the gear (Settings) → **Calendar** → **Shared calendars**.
3. Under **Publish a calendar**, choose your calendar and **Can view all details**, then click **Publish**.
4. Copy the **ICS** link. (If you copy the HTML link by mistake, AppleLook fixes it for you.)

> Treat this link like a password: anyone who has it can see your calendar. If it ever leaks, click **Reset links** on the same screen and paste the new link into AppleLook.

## 2. Install AppleLook

1. Click the green **Download AppleLook** button at the top of this page. Open **AppleLook.zip** from your Downloads folder to unzip it.
2. Drag **AppleLook** into your **Applications** folder, then double-click it.
3. The first time, macOS says it can't verify the app. That's because AppleLook isn't registered with Apple yet. Click **Done**, then:
   - Open **System Settings → Privacy & Security**.
   - Scroll down to the message about AppleLook and click **Open Anyway**, then enter your Mac password.
   - Click **Open** when asked again.

You only do this once.

## 3. Set it up

A settings window opens the first time:

1. Paste your Outlook link.
2. Click **Allow Calendar Access**, then **Allow** in the message that appears.
3. Choose the calendar to copy into, or type a name and click **Create New Calendar**. A separate calendar is best.
4. Choose what others will see: a label (like "Work"), whether to show meeting titles and locations, and whether to include meetings marked Tentative or Free.
5. Click **Preview** to check, then **Save and Sync**.

Your meetings appear in that calendar within a minute. To share it, open Calendar, right-click the calendar in the sidebar, and choose **Share Calendar**.

AppleLook now lives in the menu bar (a calendar icon) and starts when you log in. Click the icon to sync right away or change settings.

## Good to know

- **Your Mac has to be awake** to sync. Changes made while it's asleep or off show up shortly after it wakes.
- **Outlook is the source.** If you delete a copied event in iCloud, it comes back on the next sync. Change or decline it in Outlook instead.
- **Which meetings are copied:** busy and out-of-office time from 7 days ago to 90 days ahead, plus, if you turn them on in Settings, meetings marked Tentative or Free. Cancelled meetings are always skipped.
- **How AppleLook recognizes its own events:** each one has a link starting with `applelook://` in its details. Events without that link are never touched.
- **The log** is at `~/Library/Logs/AppleLook.log`.

## Updating

AppleLook checks for new versions once a day. When one is out, **Update Available** appears at the top of its menu. You can also click the menu-bar icon → **Check for Updates…** at any time.

To update:

1. Click **Download** in the update message (or the green button above).
2. Click the menu-bar icon → **Quit AppleLook**.
3. Open the downloaded **AppleLook.zip** and drag the new **AppleLook** into **Applications**, choosing **Replace**.
4. Open AppleLook. As on the first install, macOS asks you to confirm it in **System Settings → Privacy & Security → Open Anyway**.

Your settings (Outlook link, calendar and options) are kept.

On GitHub, you can also click **Watch → Custom → Releases** at the top of this page to get an email for each new version.

## Removing AppleLook

1. Click the menu-bar icon → **Settings…** → **Remove AppleLook Events…** to delete the copies.
2. Click the icon → **Quit AppleLook**.
3. Drag AppleLook from Applications to the Trash.

## Troubleshooting

**"Outlook says the calendar link no longer works"**: the link was reset or unpublished. Publish again, copy the new ICS link, and paste it in Settings.

**"AppleLook isn't allowed to use your calendars"**: open System Settings → Privacy & Security → Calendars and turn AppleLook on (choose Full Access).

**My iCloud calendars aren't in the list**: check that iCloud Calendars is on for this Mac (System Settings → your name → iCloud).

**Times are off**: tell us which time zone your Outlook calendar uses. Outlook writes Windows time zone names, and AppleLook converts them; an unknown one is noted in the log.

## For developers

AppleLook is a Swift package with three parts:

| Target | What it is |
|---|---|
| `AppleLookCore` | Reads .ics feeds (including Outlook's Windows time zone names), expands repeating meetings, applies the filters, and plans each sync. No EventKit or UI, fully unit-tested. |
| `AppleLook` | The menu-bar app. Writes through EventKit, so it uses the Mac's own iCloud account: no app-specific password. |
| `applelook-cli` | `swift run applelook-cli check-feed <link-or-file>` lists what would be copied, without touching any calendar. |

```bash
scripts/test.sh        # unit tests (works with just the Command Line Tools)
scripts/build-app.sh   # build/AppleLook.app and build/AppleLook.zip (Apple Silicon + Intel)
```

Builds are signed with a self-signed certificate (`scripts/make-signing-cert.sh` creates it once) so that macOS keeps users' Calendar permission across updates. To publish a release, bump `CFBundleShortVersionString` in `Resources/Info.plist`, build, and attach `build/AppleLook.zip` to a GitHub Release tagged `v<version>`. The download button and the in-app update check both follow the latest release.

AppleLook grew out of [outlook-icloud-bridge](https://github.com/michaellorendiaz/outlook-icloud-bridge), a Python script that does the same job from the command line. The feed logic matches it event for event.

## License

MIT

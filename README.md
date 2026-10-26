# AppleLook

Copy your Outlook work calendar into an iCloud calendar you can share with family.

AppleLook is a small Mac menu-bar app. You paste the link Outlook gives you for your calendar, pick an iCloud calendar, and it keeps that calendar up to date every 15 minutes. Share the iCloud calendar with your family in the Calendar app, and they see when you're in meetings. You choose whether they see the meeting names or just "Busy".

Why not just subscribe to the Outlook link in Calendar? A subscribed calendar can't be shared through iCloud Family Sharing. A real iCloud calendar can.

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

1. Download **AppleLook.zip** and double-click it to unzip.
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
4. Choose what others will see: a label (like "Work"), and whether to show meeting titles and locations.
5. Click **Preview** to check, then **Save and Sync**.

Your meetings appear in that calendar within a minute. To share it, open Calendar, right-click the calendar in the sidebar, and choose **Share Calendar**.

AppleLook now lives in the menu bar (a calendar icon) and starts when you log in. Click the icon to sync right away or change settings.

## Good to know

- **Your Mac has to be awake** to sync. Changes made while it's asleep or off show up shortly after it wakes.
- **Outlook is the source.** If you delete a copied event in iCloud, it comes back on the next sync. Change or decline it in Outlook instead.
- **Which meetings are copied:** busy, tentative (optional) and out-of-office time from 7 days ago to 90 days ahead. Meetings marked Free and cancelled meetings are skipped.
- **How AppleLook recognizes its own events:** each one has a link starting with `applelook://` in its details. Events without that link are never touched.
- **The log** is at `~/Library/Logs/AppleLook.log`.

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

AppleLook grew out of [outlook-icloud-bridge](https://github.com/michaellorendiaz/outlook-icloud-bridge), a Python script that does the same job from the command line. The feed logic matches it event for event.

## License

MIT

# AppleLook Server

AppleLook for an always-on Linux machine: a Docker container that copies your Outlook calendar into an iCloud calendar every 15 minutes, with a web page for the same settings as the Mac app. Unlike the Mac app, it keeps syncing while your laptop is closed.

It runs two ways:

- **As a Home Assistant add-on**: opened from the Home Assistant sidebar, behind Home Assistant's own login. Needs Home Assistant OS or Supervised.
- **As a plain Docker container**: a page on your home network with its own login password.

## What you need

- An Outlook calendar ICS link (Outlook on the web: Settings → Calendar → Shared calendars → Publish a calendar, then copy the **ICS** link).
- Your Apple ID and an **app-specific password**: [account.apple.com](https://account.apple.com) → Sign-In and Security → App-Specific Passwords. Unlike the Mac app, a server can't use your Mac's iCloud sign-in, so it needs this password to reach iCloud Calendar.

## Option 1: Home Assistant add-on

1. In Home Assistant: **Settings → Add-ons → Add-on Store**, then **⋮ → Repositories**, and add `https://github.com/michaellorendiaz/AppleLook`.
2. Find **AppleLook** in the store, click **Install**, then **Start**. Turn on **Show in sidebar**.
3. Open **AppleLook** from the sidebar and fill in the settings.

## Option 2: Docker Compose

Put this in a `docker-compose.yml` (or add the service to one you already have), with your own password and time zone:

```yaml
services:
  applelook:
    image: ghcr.io/michaellorendiaz/applelook:latest
    container_name: applelook
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      APPLELOOK_PASSWORD: "a-long-password-you-choose"
      TZ: "America/New_York"
    volumes:
      - applelook-data:/data

volumes:
  applelook-data:
```

Then run `docker compose up -d`, open `http://<this-machine>:8080`, log in with `APPLELOOK_PASSWORD`, and fill in the settings. If port 8080 is taken, change the left number, like `"8090:8080"`.

To update: `docker compose pull && docker compose up -d`. Settings are kept in the `applelook-data` volume. The image runs on Intel and ARM (including Raspberry Pi). To pin a version instead of `latest`, use a tag like `ghcr.io/michaellorendiaz/applelook:0.3.1`.

Keep the page on your home network. Don't forward port 8080 from your router: it holds your calendar link and iCloud password.

## The settings page

1. **Outlook link.** If you paste the HTML link by mistake, it's switched to the ICS one.
2. **iCloud account.** Apple ID and app-specific password. The password is stored in the data folder, readable only by the app, and never shown again.
3. **Calendar.** Pick from your iCloud calendars, or create a new one. Changing it later moves AppleLook's events to the new calendar.
4. **What others see.** The event title, locations, and whether to include Tentative and Free meetings.

**Preview** shows what a sync would add, change and remove, without saving. **Save and Sync** saves and syncs right away; after that it syncs at :00, :15, :30 and :45. **Remove Events…** deletes everything AppleLook added to the calendar.

## Configuration

| Variable | Default | What it does |
|---|---|---|
| `APPLELOOK_AUTH` | `password` | `password`: login page. `ingress`: Home Assistant add-on (set for you). `none`: no login, only for trying it on your own computer. |
| `APPLELOOK_PASSWORD` | (none) | The login password, required with `APPLELOOK_AUTH=password`. |
| `ICLOUD_APP_PASSWORD` | (none) | Supply the app-specific password from the environment instead of the page. |
| `TZ` | UTC | Your time zone, for times shown on the page. |
| `APPLELOOK_PORT` | `8080` | Port to listen on. |
| `APPLELOOK_DATA` | `/data` | Where settings and secrets are kept. |

Logs go to the container's output: `docker logs applelook`, or the add-on's **Log** tab.

## Development

To build the image yourself instead of pulling it, clone the repo and in `server/` change `image:` to `build: .` in `docker-compose.yml`, then `docker compose up -d --build`. Publishing a GitHub release builds and pushes the image (`.github/workflows/server-image.yml`).

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m unittest discover tests
APPLELOOK_AUTH=none APPLELOOK_DATA=/tmp/applelook APPLELOOK_HOST=127.0.0.1 .venv/bin/python -m applelook_server
```

The sync engine (`applelook_server/engine.py`) is outlook-icloud-bridge's `bridge.py`, keeping its event IDs and tag, plus a Free-meetings option. It picks the same events as bridge.py and the Mac app.

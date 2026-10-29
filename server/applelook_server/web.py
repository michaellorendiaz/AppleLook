"""AppleLook Server: a settings page plus a background sync every 15 minutes.

Access control (APPLELOOK_AUTH):
  password  (default) a login page; the password is APPLELOOK_PASSWORD
  ingress   Home Assistant add-on: no login of our own, and only Home Assistant's
            ingress proxy may connect (Home Assistant has already logged the user in)
  none      no login at all; only for trying it out on your own computer

Every link and form uses a relative URL, so the page also works under Home
Assistant's ingress path prefix.
"""

import datetime as dt
import hmac
import logging
import os
import secrets
import sys
import threading
import time
from collections import deque
from urllib.parse import urlparse

from flask import Flask, abort, flash, redirect, render_template, request, session

from . import __version__, engine, store

INGRESS_PROXY = "172.30.32.2"   # Home Assistant's ingress gateway
INTERVAL_MIN = 15
AUTH_RETRY_WAIT = 30    # seconds before retrying a sign-in iCloud turned away
AUTH_FAILS_TO_BLAME = 3  # syncs in a row before blaming the password

log = logging.getLogger("applelook")


# --- Status and the background sync -------------------------------------------

class Status:
    def __init__(self):
        self.lock = threading.Lock()        # one sync at a time
        self.last_run = None
        self.last_result = None
        self.last_error = None
        self.next_run = None
        self.auth_fails = 0                 # sign-in rejections in a row
        self.activity = deque(maxlen=30)    # (time, message), newest last

    def note(self, message):
        self.activity.append((dt.datetime.now().astimezone(), message))


status = Status()
_calendar_cache = {"key": None, "names": [], "at": 0.0}
_previews = {}  # token -> preview; kept server-side because a cookie holds only ~4 KB


def run_sync(dry_run=False, retry_wait=AUTH_RETRY_WAIT):
    """Sync (or preview) with the saved settings. Returns the result or raises SyncError."""
    cfg = store.load_settings()
    if not store.is_complete(cfg):
        raise engine.SyncError("Finish the settings first.")
    with status.lock:
        try:
            try:
                result = engine.sync(cfg, store.icloud_password(), dry_run=dry_run)
            except engine.AuthError:
                # iCloud now and then rejects a good password; one retry usually works
                log.warning("iCloud turned the sign-in away; retrying in %ds", retry_wait)
                time.sleep(retry_wait)
                result = engine.sync(cfg, store.icloud_password(), dry_run=dry_run)
        except engine.AuthError:
            status.auth_fails += 1
            if status.auth_fails >= AUTH_FAILS_TO_BLAME:
                message = (f"iCloud didn't accept the Apple ID and app-specific password "
                           f"{status.auth_fails} syncs in a row. Create a new app-specific password "
                           f"at account.apple.com and enter it again.")
            else:
                message = ("iCloud turned the sign-in away, which happens now and then. "
                           "AppleLook will try again at the next sync.")
            return _failed(message, dry_run)
        except engine.SyncError as exc:
            return _failed(str(exc), dry_run)
        except Exception as exc:  # network trouble, iCloud hiccups: keep the scheduler alive
            log.exception("sync failed")
            return _failed(f"Unexpected error: {exc}", dry_run, logged=True)
        status.auth_fails = 0
        if not dry_run:
            status.last_run, status.last_result, status.last_error = dt.datetime.now().astimezone(), result, None
            status.note(f"Synced: {result['desired']} events, added {result['created']}, "
                        f"changed {result['updated']}, removed {result['deleted']}")
        return result


def _failed(message, dry_run, logged=False):
    """Record a failed sync (on the page and in the container log) and raise it."""
    if not logged:
        log.warning("sync failed: %s", message)
    if not dry_run:
        status.last_run, status.last_error = dt.datetime.now().astimezone(), message
        status.note(f"Sync failed: {message}")
    raise engine.SyncError(message)


def next_slot(now):
    """The next :00/:15/:30/:45."""
    minute = (now.minute // INTERVAL_MIN + 1) * INTERVAL_MIN
    return now.replace(minute=0, second=0, microsecond=0) + dt.timedelta(minutes=minute)


def scheduler():
    time.sleep(5)  # let the web server come up first
    while True:
        if store.is_complete(store.load_settings()):
            try:
                run_sync()
            except engine.SyncError:
                pass  # recorded in status
        status.next_run = next_slot(dt.datetime.now().astimezone())
        time.sleep(max(1, (status.next_run - dt.datetime.now().astimezone()).total_seconds()))


# --- Web app ----------------------------------------------------------------

def normalize_link(raw):
    """Outlook shows an HTML and an ICS link side by side; accept either, and webcal://."""
    s = (raw or "").strip()
    if s.lower().startswith("webcal://"):
        s = "https://" + s[len("webcal://"):]
    if s.endswith("/calendar.html"):
        s = s[: -len(".html")] + ".ics"
    u = urlparse(s)
    return s if u.scheme in ("http", "https") and u.netloc else None


def settings_from_form(f, cfg):
    """Apply the settings form to a copy of cfg. Returns (cfg, messages) or raises SyncError."""
    cfg = dict(cfg)
    old_calendar = cfg["target_calendar"]
    notes = []
    link = normalize_link(f.get("feed_url"))
    if f.get("feed_url", "").strip() and not link:
        raise engine.SyncError("That doesn't look like a calendar link. Copy the ICS link from Outlook.")
    if link and link != f.get("feed_url", "").strip():
        notes.append("That was the HTML link; switched to the ICS version of it.")
    cfg["feed_url"] = link or ""
    cfg["apple_id"] = f.get("apple_id", "").strip()
    cfg["target_calendar"] = f.get("target_calendar", "").strip()
    for key in ("include_titles", "include_location", "include_tentative", "include_free",
                "skip_multiday_allday"):
        cfg[key] = key in f
    # the template is the truth; the checkboxes on the page only edit it
    cfg["title_format"] = " ".join(f.get("title_format", "").split())
    cfg["include_titles"] = "{event}" in cfg["title_format"]
    cfg["alt_label_keywords"] = [k.strip() for k in f.get("alt_label_keywords", "").split(",") if k.strip()]
    cfg["alt_title_format"] = " ".join(f.get("alt_title_format", "").split())
    cfg["exclude_keywords"] = [k.strip() for k in f.get("exclude_keywords", "").split(",") if k.strip()]
    # Event IDs are made unique to the calendar so iCloud doesn't refuse them (412) when
    # another calendar on the account has the same meetings. A calendar keeps the IDs it
    # started with, so saving never re-creates its events.
    if cfg["target_calendar"] != old_calendar:
        cfg["uid_salt"] = cfg["target_calendar"]
    return cfg, notes


def go(path=""):
    """Redirect within the app. Home Assistant's ingress serves us under a prefix it
    names in X-Ingress-Path; elsewhere the app sits at the root."""
    return redirect(request.headers.get("X-Ingress-Path", "").rstrip("/") + "/" + path)


def create_app():
    app = Flask(__name__)
    app.secret_key = store.session_secret()
    app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Strict")
    auth = os.environ.get("APPLELOOK_AUTH", "password")
    login_password = os.environ.get("APPLELOOK_PASSWORD", "")

    @app.get("/health")
    def health():
        return "ok"

    @app.before_request
    def guard():
        if request.endpoint == "health":
            return None
        if auth == "ingress":
            if request.remote_addr != INGRESS_PROXY:
                abort(403)
        elif auth == "password":
            if request.endpoint not in ("login", "static") and not session.get("in"):
                return go("login")
        if request.method == "POST" and request.endpoint != "login":
            if not hmac.compare_digest(request.form.get("csrf", ""), session.get("csrf", "-")):
                abort(400)

    @app.context_processor
    def common():
        if "csrf" not in session:
            session["csrf"] = secrets.token_urlsafe(24)
        return {"csrf": session["csrf"], "version": __version__, "auth": auth}

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if auth != "password":
            return go()
        if not login_password:
            return render_template("login.html", missing=True)
        if request.method == "POST":
            if hmac.compare_digest(request.form.get("password", ""), login_password):
                session.clear()
                session["in"] = True
                return go()
            time.sleep(1)
            flash("That password isn't right.", "error")
        return render_template("login.html", missing=False)

    @app.post("/logout")
    def logout():
        session.clear()
        return go("login")

    @app.get("/")
    def index():
        cfg = store.load_settings()
        preview = _previews.pop(session.pop("preview", ""), None)
        saved_complete = store.is_complete(cfg)
        # show the settings that were previewed, not the saved ones, so Save and Sync
        # after a Preview saves exactly what was previewed
        form_cfg = preview["cfg"] if preview else cfg
        password = store.icloud_password()
        calendars, calendar_error = [], None
        if cfg["apple_id"] and password:
            key = (cfg["apple_id"], password)
            if _calendar_cache["key"] == key and time.time() - _calendar_cache["at"] < 300:
                calendars = _calendar_cache["names"]
            else:
                try:
                    calendars = engine.calendar_names(*key)
                    _calendar_cache.update(key=key, names=calendars, at=time.time())
                except engine.SyncError as exc:
                    calendar_error = str(exc)
                except Exception:
                    log.exception("listing calendars")
                    calendar_error = "Couldn't reach iCloud to list your calendars."
        for name in (cfg["target_calendar"], form_cfg["target_calendar"]):
            if name and name not in calendars:
                calendars = calendars + [name]
        return render_template(
            "index.html", cfg=form_cfg, has_password=bool(password), password_from_env=store.password_from_env(),
            calendars=calendars, calendar_error=calendar_error, complete=saved_complete,
            status=status, preview=preview, saved_calendar=cfg["target_calendar"],
            title_format=form_cfg["title_format"],
            example=engine.event_summary("Budget review", form_cfg),
            alt_example=(engine.event_summary(form_cfg["alt_label_keywords"][0] + " 120", form_cfg)
                         if form_cfg["alt_label_keywords"] else ""))

    @app.post("/save")
    def save():
        f = request.form
        old_calendar = store.load_settings()["target_calendar"]
        try:
            cfg, notes = settings_from_form(f, store.load_settings())
        except engine.SyncError as exc:
            flash(str(exc), "error")
            return go()
        for note in notes:
            flash(note, "info")
        if f.get("icloud_password", "").strip():
            store.save_icloud_password(f["icloud_password"])
            _calendar_cache["key"] = None
        store.save_settings(cfg)
        status.note("Settings saved")

        if old_calendar and old_calendar != cfg["target_calendar"] and store.is_complete(cfg):
            try:
                n = engine.purge({**cfg, "target_calendar": old_calendar}, store.icloud_password())
                status.note(f"Removed {n} events from {old_calendar!r}")
                flash(f"Moved to {cfg['target_calendar']!r}: removed {n} events from {old_calendar!r}.", "info")
            except engine.SyncError as exc:
                flash(f"Couldn't remove the events from {old_calendar!r}: {exc}", "error")
        if store.is_complete(cfg):
            try:
                r = run_sync(retry_wait=5)
                flash(f"Saved and synced {r['desired']} events: added {r['created']}, "
                      f"changed {r['updated']}, removed {r['deleted']}.", "ok")
            except engine.SyncError as exc:
                flash(str(exc), "error")
        else:
            flash("Saved. Fill in the rest to start syncing.", "info")
        return go()

    @app.post("/create-calendar")
    def create_calendar():
        cfg = store.load_settings()
        name = request.form.get("name", "").strip()
        try:
            engine.create_calendar(cfg["apple_id"], store.icloud_password(), name)
            _calendar_cache["key"] = None
            cfg["target_calendar"] = name
            cfg["uid_salt"] = name
            store.save_settings(cfg)
            flash(f"Created {name!r} in iCloud and chose it. Click Save and Sync to fill it.", "ok")
        except engine.SyncError as exc:
            flash(str(exc), "error")
        except Exception as exc:
            flash(f"Couldn't create the calendar: {exc}", "error")
        return go()

    @app.post("/preview")
    def preview():
        """Dry run of the settings as they are on the page, without saving them."""
        try:
            cfg, _ = settings_from_form(request.form, store.load_settings())
            password = request.form.get("icloud_password", "").strip() or store.icloud_password()
            if not (cfg["feed_url"] and cfg["apple_id"] and cfg["target_calendar"] and password):
                raise engine.SyncError("Fill in the link, Apple ID, password and calendar to preview.")
            with status.lock:
                r = engine.sync(cfg, password, dry_run=True)
            token = secrets.token_urlsafe(8)
            _previews.clear()
            _previews[token] = {"summary": f"{r['desired']} events from Outlook. A sync would add "
                                           f"{r['created']}, change {r['updated']} and remove {r['deleted']}.",
                                "changes": r["changes"],
                                "cfg": cfg}
            session["preview"] = token
        except engine.SyncError as exc:
            flash(str(exc), "error")
        except Exception as exc:
            log.exception("preview failed")
            flash(f"Couldn't preview: {exc}", "error")
        return go()

    @app.post("/sync")
    def sync_now():
        try:
            r = run_sync(retry_wait=5)
            flash(f"Synced {r['desired']} events: added {r['created']}, changed {r['updated']}, "
                  f"removed {r['deleted']}.", "ok")
        except engine.SyncError as exc:
            flash(str(exc), "error")
        return go()

    @app.post("/remove")
    def remove():
        cfg = store.load_settings()
        try:
            with status.lock:
                n = engine.purge(cfg, store.icloud_password())
            status.note(f"Removed {n} events")
            flash(f"Removed {n} events. The next sync adds them back unless you change the settings.", "ok")
        except engine.SyncError as exc:
            flash(str(exc), "error")
        return go()

    return app


def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(asctime)s %(levelname)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
    auth = os.environ.get("APPLELOOK_AUTH", "password")
    if auth == "password" and not os.environ.get("APPLELOOK_PASSWORD"):
        log.error("Set APPLELOOK_PASSWORD (the settings page's login password), "
                  "or APPLELOOK_AUTH=ingress when running as a Home Assistant add-on.")
        sys.exit(1)
    if auth not in ("password", "ingress", "none"):
        log.error("APPLELOOK_AUTH must be password, ingress or none")
        sys.exit(1)
    if auth == "none":
        log.warning("APPLELOOK_AUTH=none: the settings page has no login")

    from waitress import serve
    threading.Thread(target=scheduler, daemon=True, name="scheduler").start()
    port = int(os.environ.get("APPLELOOK_PORT", "8080"))
    log.info("AppleLook Server %s on port %d (auth: %s, data: %s)", __version__, port, auth, store.DATA)
    serve(create_app(), host=os.environ.get("APPLELOOK_HOST", "0.0.0.0"), port=port, threads=4)

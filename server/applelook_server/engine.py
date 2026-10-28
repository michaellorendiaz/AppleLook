"""
Outlook -> iCloud sync engine for AppleLook Server.

Ported from outlook-icloud-bridge's bridge.py, keeping its event IDs and its
CATEGORIES:OutlookBusySync tag, so it can take over the events that script (or
the older outlook-busy-bridge service) already wrote. Changes from bridge.py:
an include_free option, calendar listing and creation, results returned to the
caller instead of only logged, and no macOS Keychain.
"""

import datetime as dt
import hashlib
import logging
import re
import time

import caldav
import recurring_ical_events
import requests
from icalendar import Calendar, Event

ICLOUD_CALDAV = "https://caldav.icloud.com/"
MARKER = "OutlookBusySync"           # CATEGORIES tag identifying our events
BUSY_STATUSES = {"BUSY", "TENTATIVE", "OOF", "WORKINGELSEWHERE"}

DEFAULTS = {
    "label": "Work",
    "include_titles": False,
    "title_format": None,   # e.g. "{label} ({event})"; None = built from label/include_titles
    "alt_label_keywords": [],  # meetings whose title has one of these words...
    "alt_label": "",           # ...use this label instead (e.g. "ART" -> "Teaching")
    "alt_title_format": "",    # ...and this title template ("" = the usual one)
    "include_location": False,
    "online_as_remote": True,
    "include_tentative": True,
    "include_free": False,
    "skip_multiday_allday": False,
    "exclude_keywords": [],
    "window_back_days": 7,
    "window_fwd_days": 90,
    "uid_salt": "",
}

log = logging.getLogger("applelook")


class SyncError(Exception):
    """A problem worth showing to the user as-is."""


class AuthError(SyncError):
    """iCloud turned the sign-in away. Usually a bad password, but iCloud also
    rejects a good one now and then, so callers retry before blaming it."""


def to_utc(value):
    """Normalize a date/datetime to an aware UTC datetime (date -> midnight)."""
    if isinstance(value, dt.datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=dt.timezone.utc)
        return value.astimezone(dt.timezone.utc), False
    # all-day (date)
    return dt.datetime(value.year, value.month, value.day, tzinfo=dt.timezone.utc), True


def is_free(component):
    cdo = str(component.get("X-MICROSOFT-CDO-BUSYSTATUS", "")).upper()
    if cdo:
        return cdo == "FREE"
    return str(component.get("TRANSP", "OPAQUE")).upper() == "TRANSPARENT"


def should_copy(component, cfg):
    """Busy, out-of-office and (optionally) tentative events; Free ones only when asked."""
    status = str(component.get("STATUS", "")).upper()
    if status == "CANCELLED":
        return False
    cdo = str(component.get("X-MICROSOFT-CDO-BUSYSTATUS", "")).upper()
    if cdo:
        if cdo == "TENTATIVE" and not cfg["include_tentative"]:
            return False
        if cdo == "FREE":
            return cfg["include_free"]
        return cdo in BUSY_STATUSES
    if status == "TENTATIVE" and not cfg["include_tentative"]:
        return False
    return not is_free(component) or cfg["include_free"]


def clean_location(loc, cfg):
    """Keep human locations (room/building); optionally collapse meeting URLs to 'Remote'."""
    if not cfg["include_location"]:
        return ""
    loc = (loc or "").strip()
    if not loc:
        return ""
    low = loc.lower()
    if cfg["online_as_remote"] and ("http" in low or "teams.microsoft" in low or "zoom.us" in low):
        return "Remote"
    return loc


def stable_uid(source_uid, start_utc, salt=""):
    # iCloud rejects a UID that already exists in another calendar on the same
    # account, so installs salt it with their calendar name. No salt keeps the
    # original UIDs (and lets this take over outlook-busy-bridge's events).
    key = f"{source_uid}|{start_utc.isoformat()}"
    if salt:
        key = f"{salt}|{key}"
    h = hashlib.sha1(key.encode()).hexdigest()[:24]
    return f"obs-{h}@outlook-busy-bridge"


def fetch_feed(url, attempts=3, delay=20):
    """Download the ICS feed, retrying briefly."""
    for i in range(1, attempts + 1):
        try:
            r = requests.get(url, timeout=30, headers={"User-Agent": "AppleLook-Server"})
            if r.status_code in (403, 404):
                raise SyncError(f"Outlook says the calendar link no longer works (error {r.status_code}). "
                                "If you reset or unpublished it, paste the new ICS link.")
            r.raise_for_status()
            try:
                return Calendar.from_ical(r.content)
            except ValueError:
                raise SyncError("The link didn't return a calendar. Check that you copied the ICS link from Outlook.")
        except requests.RequestException:
            if i == attempts:
                raise SyncError("Couldn't download the Outlook calendar. Will try again later.")
            time.sleep(delay)


def title_format(cfg):
    """The title template. Settings saved before templates existed get the
    template that reproduces their old titles exactly."""
    if cfg.get("title_format") is not None:
        return cfg["title_format"]
    label = (cfg.get("label") or "").strip()
    if cfg.get("include_titles"):
        return "{label} ({event})" if label else "{event}"
    return "{label}" if label else ""


SEPARATORS = " \t:;,.|/\\-\u2013\u2014\u00b7"


def tidy_template(template):
    """Clean up a template after an empty variable was taken out of it: empty
    brackets, separators left at either end, or brackets around everything."""
    t = re.sub(r"\(\s*\)|\[\s*\]|\{\s*\}", "", template)
    t = re.sub(r"\s+", " ", t).strip(SEPARATORS)
    m = re.fullmatch(r"\((.*)\)|\[(.*)\]", t)
    if m and not re.search(r"[()\[\]]", m.group(1) or m.group(2)):
        t = (m.group(1) or m.group(2)).strip(SEPARATORS)
    return t


def render_title(template, label, event, altlabel=""):
    """Fill {label}, {altlabel} and {event}. An empty one is taken out of the
    template first, so "{label} ({event})" with no title gives "Work", not
    "Work ()". The meeting title itself is never trimmed or changed."""
    values = {"{label}": label.strip(), "{altlabel}": altlabel.strip(), "{event}": event}
    empty = [tok for tok, val in values.items() if tok in template and not val.strip()]
    if empty:
        for tok in empty:
            template = template.replace(tok, "")
        template = tidy_template(template)
    s = template
    for tok, val in values.items():
        s = s.replace(tok, val)
    return s if s.strip() else "Busy"


def alt_rule_applies(title, cfg):
    """Whether a word in the title starts with one of the alternative keywords,
    matching case ("ART 120", "ARTshow" yes; "Art show", "PARTY" no)."""
    return any(k and re.search(rf"(?<!\w){re.escape(k)}", title)
               for k in cfg.get("alt_label_keywords") or [])


def event_summary(title, cfg):
    """The event title others see: the title template, or for meetings matching an
    alternative keyword, its own template, where {altlabel} is the alternative
    label. With no template of its own, the alternative label takes the place
    of the label in the usual one."""
    label, altlabel = cfg.get("label") or "", cfg.get("alt_label") or ""
    template = title_format(cfg)
    if alt_rule_applies(title, cfg):
        if cfg.get("alt_title_format"):
            template = cfg["alt_title_format"]
        else:
            label = altlabel
    return render_title(template, label, title if "{event}" in template else "", altlabel)


def excluded(title, cfg):
    low = title.lower()
    return any(k.lower() in low for k in cfg["exclude_keywords"] if k)


def build_desired(cal, cfg, now=None):
    """Expand the feed into the rolling window ->
    {uid: (start_utc, end_utc, allday, loc, summary, free)}."""
    now = now or dt.datetime.now(dt.timezone.utc)
    win_start = now - dt.timedelta(days=cfg["window_back_days"])
    win_end = now + dt.timedelta(days=cfg["window_fwd_days"])
    desired = {}
    for occ in recurring_ical_events.of(cal).between(win_start, win_end):
        if occ.name != "VEVENT" or not should_copy(occ, cfg):
            continue
        s = occ.get("DTSTART")
        e = occ.get("DTEND")
        if not s:
            continue
        start_utc, allday = to_utc(s.dt)
        if e:
            end_utc, _ = to_utc(e.dt)
        else:
            end_utc = start_utc + dt.timedelta(minutes=30)
        if cfg["skip_multiday_allday"] and allday and (end_utc - start_utc) > dt.timedelta(days=1):
            continue
        title = str(occ.get("SUMMARY", "")).strip()
        if excluded(title, cfg):
            continue
        loc = clean_location(str(occ.get("LOCATION", "")), cfg)
        uid = stable_uid(str(occ.get("UID", "")), start_utc, cfg["uid_salt"])
        desired[uid] = (start_utc, end_utc, allday, loc, event_summary(title, cfg), is_free(occ))
    return desired


def make_ics(uid, start_utc, end_utc, allday, location, summary, free=False):
    cal = Calendar()
    cal.add("prodid", "-//AppleLook Server//EN")
    cal.add("version", "2.0")
    ev = Event()
    ev.add("uid", uid)
    ev.add("summary", summary)
    if location:
        ev.add("location", location)
    ev.add("categories", [MARKER])
    ev.add("transp", "TRANSPARENT" if free else "OPAQUE")
    ev.add("dtstamp", dt.datetime.now(dt.timezone.utc))
    if allday:
        ev.add("dtstart", start_utc.date())
        ev.add("dtend", (end_utc if end_utc > start_utc else start_utc + dt.timedelta(days=1)).date())
    else:
        ev.add("dtstart", start_utc)
        ev.add("dtend", end_utc)
    cal.add_component(ev)
    return cal.to_ical()


def load_existing(calendar, start, end):
    """Return {uid: caldav.Event} for events we manage (tagged MARKER) between start and end."""
    found = {}
    for ev in calendar.search(start=start, end=end, event=True, expand=False):
        comp = ev.icalendar_component
        cats = comp.get("CATEGORIES")
        names = []
        if cats is not None:
            try:
                names = [str(c) for c in cats.cats]
            except AttributeError:
                names = [str(cats)]
        if MARKER in names:
            found[str(comp.get("UID"))] = ev
    return found


def existing_props(ev):
    comp = ev.icalendar_component
    s, _ = to_utc(comp.get("DTSTART").dt)
    e = comp.get("DTEND")
    e = to_utc(e.dt)[0] if e else s
    loc = str(comp.get("LOCATION", "")).strip()
    summary = str(comp.get("SUMMARY", "")).strip()
    free = str(comp.get("TRANSP", "OPAQUE")).upper() == "TRANSPARENT"
    return s, e, loc, summary, free


def client(apple_id, password):
    if not apple_id or not password:
        raise SyncError("Enter your Apple ID and app-specific password first.")
    return caldav.DAVClient(url=ICLOUD_CALDAV, username=apple_id, password=password)


def calendar_names(apple_id, password):
    """Names of the account's calendars, for the settings picker."""
    try:
        names = []
        for c in client(apple_id, password).principal().calendars():
            try:
                names.append(c.get_display_name())
            except Exception:
                names.append(c.name)
        return sorted(n for n in names if n)
    except caldav.lib.error.AuthorizationError:
        raise AuthError("iCloud didn't accept the Apple ID and app-specific password.")


def create_calendar(apple_id, password, name):
    try:
        client(apple_id, password).principal().make_calendar(name=name)
    except caldav.lib.error.AuthorizationError:
        raise AuthError("iCloud didn't accept the Apple ID and app-specific password.")


def find_calendar(cfg, password):
    try:
        for c in client(cfg["apple_id"], password).principal().calendars():
            try:
                name = c.get_display_name()
            except Exception:
                name = c.name
            if name == cfg["target_calendar"]:
                return c
    except caldav.lib.error.AuthorizationError:
        raise AuthError("iCloud didn't accept the Apple ID and app-specific password.")
    raise SyncError(f"The iCloud calendar {cfg['target_calendar']!r} wasn't found. Pick one in Settings.")


def fmt(start, end, allday):
    if allday:
        return f"{start.date()} (all day)"
    s, e = start.astimezone(), end.astimezone()
    return f"{s:%a %b %d, %H:%M}-{e:%H:%M}"


def sync(cfg, password, dry_run=False):
    """Make the calendar match the feed. Returns a dict of counts (and, for a dry
    run, what would change)."""
    try:
        return _sync(cfg, password, dry_run)
    except caldav.lib.error.AuthorizationError:  # a 401 partway through
        raise AuthError("iCloud didn't accept the Apple ID and app-specific password.")


def _sync(cfg, password, dry_run):
    calendar = find_calendar(cfg, password)
    feed = fetch_feed(cfg["feed_url"])
    desired = build_desired(feed, cfg)
    now = dt.datetime.now(dt.timezone.utc)
    existing = load_existing(calendar,
                             now - dt.timedelta(days=cfg["window_back_days"] + 1),
                             now + dt.timedelta(days=cfg["window_fwd_days"] + 1))

    result = {"feed": len(feed.walk("VEVENT")), "desired": len(desired), "existing": len(existing),
              "created": 0, "updated": 0, "deleted": 0, "changes": []}

    for uid, (s, e, allday, loc, summary, free) in sorted(desired.items(), key=lambda kv: kv[1][0]):
        if uid not in existing:
            result["changes"].append(f"Add: {fmt(s, e, allday)} {summary}")
            if not dry_run:
                try:
                    calendar.save_event(make_ics(uid, s, e, allday, loc, summary, free).decode())
                except caldav.lib.error.PutError as exc:
                    if "412" not in str(exc):
                        raise
                    raise SyncError(
                        "iCloud refused to add an event because one with the same ID is already in "
                        "another calendar on this account. Delete AppleLook's old copies from that "
                        "calendar, then sync again.")
            result["created"] += 1
        elif existing_props(existing[uid]) != (s, e, loc, summary, free):
            result["changes"].append(f"Change: {fmt(s, e, allday)} {summary}")
            if not dry_run:
                existing[uid].delete()
                calendar.save_event(make_ics(uid, s, e, allday, loc, summary, free).decode())
            result["updated"] += 1

    for uid, ev in existing.items():
        if uid not in desired:
            props = existing_props(ev)
            result["changes"].append(f"Remove: {fmt(props[0], props[1], False)} {props[3]}")
            if not dry_run:
                ev.delete()
            result["deleted"] += 1

    log.info("%s: feed=%d desired=%d existing=%d  created=%d updated=%d deleted=%d",
             "dry run" if dry_run else "sync ok", result["feed"], result["desired"],
             result["existing"], result["created"], result["updated"], result["deleted"])
    return result


def purge(cfg, password):
    """Delete every event this tool (or outlook-busy-bridge) created in the calendar."""
    calendar = find_calendar(cfg, password)
    now = dt.datetime.now(dt.timezone.utc)
    existing = load_existing(calendar, now - dt.timedelta(days=730), now + dt.timedelta(days=730))
    for ev in existing.values():
        ev.delete()
    log.info("deleted %d synced event(s) from %r", len(existing), cfg["target_calendar"])
    return len(existing)

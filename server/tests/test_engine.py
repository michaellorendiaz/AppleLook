"""Engine tests: bridge.py's own cases plus AppleLook Server's additions. No network.

Run with:  python -m unittest discover tests   (from the server folder)
"""

import datetime as dt
import hashlib
import unittest

from icalendar import Calendar

from applelook_server import engine

NOW = dt.datetime(2026, 3, 2, 12, 0, tzinfo=dt.timezone.utc)

FEED = b"""BEGIN:VCALENDAR
VERSION:2.0
PRODID:test
BEGIN:VEVENT
UID:busy-1
SUMMARY:Budget review
LOCATION:Room 204
DTSTART:20260303T150000Z
DTEND:20260303T160000Z
X-MICROSOFT-CDO-BUSYSTATUS:BUSY
END:VEVENT
BEGIN:VEVENT
UID:free-1
SUMMARY:Lunch hold
DTSTART:20260303T170000Z
DTEND:20260303T180000Z
X-MICROSOFT-CDO-BUSYSTATUS:FREE
END:VEVENT
BEGIN:VEVENT
UID:cancel-1
SUMMARY:Cancelled sync
STATUS:CANCELLED
DTSTART:20260304T150000Z
DTEND:20260304T160000Z
X-MICROSOFT-CDO-BUSYSTATUS:BUSY
END:VEVENT
BEGIN:VEVENT
UID:tent-1
SUMMARY:Maybe meeting
LOCATION:https://teams.microsoft.com/l/meetup-join/abc
DTSTART:20260305T150000Z
DTEND:20260305T160000Z
X-MICROSOFT-CDO-BUSYSTATUS:TENTATIVE
END:VEVENT
BEGIN:VEVENT
UID:multi-1
SUMMARY:Room booking
DTSTART;VALUE=DATE:20260306
DTEND;VALUE=DATE:20260313
X-MICROSOFT-CDO-BUSYSTATUS:BUSY
END:VEVENT
BEGIN:VEVENT
UID:allday-1
SUMMARY:Offsite
DTSTART;VALUE=DATE:20260310
DTEND;VALUE=DATE:20260311
X-MICROSOFT-CDO-BUSYSTATUS:OOF
END:VEVENT
BEGIN:VEVENT
UID:weekly-1
SUMMARY:Team standup
DTSTART:20260302T140000Z
DTEND:20260302T143000Z
RRULE:FREQ=WEEKLY;COUNT=3
X-MICROSOFT-CDO-BUSYSTATUS:BUSY
END:VEVENT
BEGIN:VEVENT
UID:private-1
SUMMARY:Doctor appointment
DTSTART:20260311T150000Z
DTEND:20260311T160000Z
X-MICROSOFT-CDO-BUSYSTATUS:BUSY
END:VEVENT
END:VCALENDAR
"""


def desired(**overrides):
    cfg = dict(engine.DEFAULTS, label="Busy")  # bridge.py's default label
    cfg.update(overrides)
    return engine.build_desired(Calendar.from_ical(FEED), cfg, now=NOW)


def summaries(d):
    return sorted(v[4] for v in d.values())


class BridgeParityTests(unittest.TestCase):
    """The same expectations as outlook-icloud-bridge's tests/test_bridge.py."""

    def test_defaults_are_private_busy_blocks(self):
        d = desired()
        # busy-1, tent-1, multi-1, allday-1, 3x weekly, private-1
        self.assertEqual(len(d), 8)
        self.assertEqual(set(summaries(d)), {"Busy"})
        self.assertTrue(all(v[3] == "" for v in d.values()), "no locations by default")

    def test_free_and_cancelled_are_never_synced_by_default(self):
        d = desired(include_titles=True, label="")
        self.assertNotIn("Lunch hold", summaries(d))
        self.assertNotIn("Cancelled sync", summaries(d))

    def test_titles_and_label(self):
        self.assertIn("Work (Budget review)", summaries(desired(label="Work", include_titles=True)))
        self.assertIn("Budget review", summaries(desired(label="", include_titles=True)))

    def test_location_and_remote(self):
        locs = {v[3] for v in desired(include_location=True).values()}
        self.assertIn("Room 204", locs)
        self.assertIn("Remote", locs)
        d = desired(include_location=True, online_as_remote=False)
        self.assertTrue(any(v[3].startswith("https://") for v in d.values()))

    def test_tentative_toggle(self):
        self.assertNotIn("Maybe meeting",
                         summaries(desired(include_titles=True, label="", include_tentative=False)))

    def test_skip_multiday_allday_keeps_single_day(self):
        s = summaries(desired(include_titles=True, label="", skip_multiday_allday=True))
        self.assertNotIn("Room booking", s)
        self.assertIn("Offsite", s)

    def test_exclude_keywords(self):
        s = summaries(desired(include_titles=True, label="", exclude_keywords=["doctor"]))
        self.assertNotIn("Doctor appointment", s)

    def test_recurrence_expanded_with_stable_uids(self):
        s = summaries(desired(include_titles=True, label=""))
        self.assertEqual(s.count("Team standup"), 3)
        self.assertEqual(set(desired()), set(desired()), "UIDs must be deterministic")

    def test_uid_salt(self):
        plain, salted = set(desired()), set(desired(uid_salt="Bridge Test"))
        self.assertTrue(plain.isdisjoint(salted), "salt must change every UID")
        self.assertEqual(set(desired(uid_salt="")), plain, "no salt keeps original UIDs")

    def test_window_limits(self):
        self.assertEqual(len(desired(window_fwd_days=2)), 2)  # busy-1 + first standup


class TitleTemplateTests(unittest.TestCase):
    def test_old_settings_keep_their_titles(self):
        # settings saved before templates existed must produce exactly the same titles
        for label, titles in (("Work", True), ("", True), ("Work", False), ("", False)):
            cfg = dict(engine.DEFAULTS, label=label, include_titles=titles)
            old = f"{label} (Budget review)" if label and titles else (label or ("Budget review" if titles else "") or "Busy")
            self.assertEqual(engine.event_summary("Budget review", cfg), old)

    def test_custom_templates(self):
        cases = {
            "{label}: {event}": "Work: Budget review",
            "{event} ({label})": "Budget review (Work)",
            "[{label}] {event}": "[Work] Budget review",
            "{event}": "Budget review",
            "Out of office": "Out of office",
            "": "Busy",
        }
        for template, title in cases.items():
            cfg = dict(engine.DEFAULTS, label="Work", title_format=template)
            self.assertEqual(engine.event_summary("Budget review", cfg), title, template)

    def test_an_empty_variable_leaves_no_stray_punctuation(self):
        self.assertEqual(engine.render_title("{label} ({event})", "Work", ""), "Work")
        self.assertEqual(engine.render_title("{label}: {event}", "", "Budget review"), "Budget review")
        self.assertEqual(engine.render_title("{event} [{label}]", "", "Budget review"), "Budget review")
        self.assertEqual(engine.render_title("({label})", "", ""), "Busy")

    def test_the_meeting_title_is_never_trimmed(self):
        self.assertEqual(engine.render_title("{label}: {event}", "", "Sync w/ J.R."), "Sync w/ J.R.")

    def test_no_event_variable_means_no_titles(self):
        cfg = dict(engine.DEFAULTS, label="Work", title_format="{label}")
        self.assertEqual(set(summaries(engine.build_desired(Calendar.from_ical(FEED), cfg, now=NOW))), {"Work"})


class AltLabelTests(unittest.TestCase):
    cfg = dict(engine.DEFAULTS, label="Work", include_titles=True,
               alt_label_keywords=["ART"], alt_label="Teaching")

    def test_keyword_switches_the_label(self):
        self.assertEqual(engine.event_summary("ART 120 Drawing I", self.cfg), "Teaching (ART 120 Drawing I)")
        self.assertEqual(engine.event_summary("Studio: ART209", self.cfg), "Teaching (Studio: ART209)",
                         "a course number may follow")
        self.assertEqual(engine.event_summary("Budget review", self.cfg), "Work (Budget review)")

    def test_case_sensitive_whole_word(self):
        for title in ("Art show", "art 120", "PARTY planning", "DEPARTMENT meeting", "ARTS council", "ARTshow"):
            self.assertFalse(engine.alt_rule_applies(title, self.cfg), title)
        self.assertTrue(engine.alt_rule_applies("Critique (ART 209)", self.cfg))

    def test_several_keywords_and_no_titles(self):
        cfg = dict(self.cfg, alt_label_keywords=["ART", "DES"], title_format="{label}")
        self.assertEqual(engine.event_summary("DES 101", cfg), "Teaching")
        self.assertEqual(engine.event_summary("Faculty meeting", cfg), "Work")

    def test_its_own_event_title(self):
        cfg = dict(self.cfg, alt_title_format="{event} ({altlabel})")
        self.assertEqual(engine.event_summary("ART 120", cfg), "ART 120 (Teaching)")
        self.assertEqual(engine.event_summary("Budget review", cfg), "Work (Budget review)",
                         "other meetings keep the usual title")
        cfg = dict(self.cfg, title_format="{label}", alt_title_format="Class: {event}")
        self.assertEqual(engine.event_summary("ART 209", cfg), "Class: ART 209",
                         "the rule can show titles even when others don't")
        self.assertEqual(engine.event_summary("Budget review", cfg), "Work")

    def test_both_labels(self):
        cfg = dict(self.cfg, alt_title_format="{altlabel} · {label}")
        self.assertEqual(engine.event_summary("ART 120", cfg), "Teaching · Work",
                         "{label} stays the usual label in the rule's own title")
        cfg = dict(self.cfg, alt_label="", alt_title_format="{altlabel}: {event}")
        self.assertEqual(engine.event_summary("ART 120", cfg), "ART 120", "an empty one is taken out")

    def test_no_keywords_changes_nothing(self):
        cfg = dict(self.cfg, alt_label_keywords=[])
        self.assertEqual(engine.event_summary("ART 120", cfg), "Work (ART 120)")


class ServerAdditionsTests(unittest.TestCase):
    def test_free_toggle(self):
        d = desired(include_titles=True, label="", include_free=True)
        by_title = {v[4]: v for v in d.values()}
        self.assertTrue(by_title["Lunch hold"][5], "Free meetings are marked free")
        self.assertFalse(by_title["Budget review"][5])
        self.assertNotIn("Cancelled sync", by_title, "cancelled stays out even with Free on")

    def test_ids_match_outlook_busy_bridge_for_takeover(self):
        # Unsalted IDs must stay exactly what bridge.py (and the older service) wrote
        start = dt.datetime(2026, 3, 3, 15, 0, tzinfo=dt.timezone.utc)
        h = hashlib.sha1(b"busy-1|2026-03-03T15:00:00+00:00").hexdigest()[:24]
        self.assertEqual(engine.stable_uid("busy-1", start), f"obs-{h}@outlook-busy-bridge")
        self.assertIn(f"obs-{h}@outlook-busy-bridge", desired())

    def test_free_events_are_written_as_free_time(self):
        start = dt.datetime(2026, 3, 3, 17, 0, tzinfo=dt.timezone.utc)
        ics = engine.make_ics("u", start, start + dt.timedelta(hours=1), False, "", "Work", free=True)
        self.assertIn(b"TRANSP:TRANSPARENT", ics)
        self.assertIn(b"CATEGORIES:OutlookBusySync", ics)


if __name__ == "__main__":
    unittest.main()

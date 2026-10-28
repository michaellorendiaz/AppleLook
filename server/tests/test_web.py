"""Web page tests: login, CSRF, access rules and saving settings. No network: the
settings saved here are never complete, so nothing talks to Outlook or iCloud."""

import json
import os
import re
import tempfile
import unittest
from importlib import reload


def make_app(auth="password", password="hunter2"):
    os.environ["APPLELOOK_DATA"] = tempfile.mkdtemp()
    os.environ["APPLELOOK_AUTH"] = auth
    os.environ["APPLELOOK_PASSWORD"] = password
    os.environ.pop("ICLOUD_APP_PASSWORD", None)
    from applelook_server import store, web
    reload(store)
    reload(web)
    app = web.create_app()
    app.config["TESTING"] = True
    return app, store


def csrf_of(client):
    html = client.get("/").get_data(as_text=True)
    return re.search(r'name="csrf" value="([^"]+)"', html).group(1)


def csrf_of_ingress(client):
    html = client.get("/", environ_base={"REMOTE_ADDR": "172.30.32.2"}).get_data(as_text=True)
    return re.search(r'name="csrf" value="([^"]+)"', html).group(1)


class AuthTests(unittest.TestCase):
    def test_login_required(self):
        app, _ = make_app()
        c = app.test_client()
        r = c.get("/")
        self.assertEqual(r.status_code, 302)
        self.assertEqual(r.headers["Location"], "/login")

    def test_wrong_then_right_password(self):
        app, _ = make_app()
        c = app.test_client()
        self.assertIn("isn&#39;t right", c.post("/login", data={"password": "nope"}, follow_redirects=True).get_data(as_text=True))
        c.post("/login", data={"password": "hunter2"})
        self.assertEqual(c.get("/").status_code, 200)

    def test_ingress_only_from_home_assistant(self):
        app, _ = make_app(auth="ingress")
        c = app.test_client()
        self.assertEqual(c.get("/", environ_base={"REMOTE_ADDR": "192.168.1.50"}).status_code, 403)
        self.assertEqual(c.get("/", environ_base={"REMOTE_ADDR": "172.30.32.2"}).status_code, 200)

    def test_redirects_stay_under_the_ingress_prefix(self):
        app, _ = make_app(auth="ingress")
        c = app.test_client()
        r = c.post("/sync", data={"csrf": csrf_of_ingress(c)}, environ_base={"REMOTE_ADDR": "172.30.32.2"},
                   headers={"X-Ingress-Path": "/api/hassio_ingress/abc123"})
        self.assertEqual(r.headers["Location"], "/api/hassio_ingress/abc123/")

    def test_health_needs_no_login(self):
        for auth in ("password", "ingress"):
            app, _ = make_app(auth=auth)
            self.assertEqual(app.test_client().get("/health").get_data(as_text=True), "ok")

    def test_post_without_csrf_is_refused(self):
        app, _ = make_app(auth="none")
        c = app.test_client()
        c.get("/")
        self.assertEqual(c.post("/save", data={"label": "x"}).status_code, 400)


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.app, self.store = make_app(auth="none")
        self.c = self.app.test_client()

    def save(self, **form):
        form.setdefault("csrf", csrf_of(self.c))
        return self.c.post("/save", data=form, follow_redirects=True).get_data(as_text=True)

    def test_html_link_becomes_ics_and_options_save(self):
        page = self.save(feed_url="https://x.example/owa/calendar/a/b/calendar.html", apple_id="me@example.com",
                         label="Work", include_titles="on", include_free="on", exclude_keywords="Lunch, Focus time")
        self.assertIn("switched to the ICS version", page)
        cfg = json.loads((self.store.DATA / "settings.json").read_text())
        self.assertEqual(cfg["feed_url"], "https://x.example/owa/calendar/a/b/calendar.ics")
        self.assertTrue(cfg["include_titles"] and cfg["include_free"])
        self.assertFalse(cfg["include_tentative"], "an unticked box saves as off")
        self.assertEqual(cfg["exclude_keywords"], ["Lunch", "Focus time"])

    def test_bad_link_is_refused(self):
        self.assertIn("look like a calendar link", self.save(feed_url="not a link"))
        self.assertFalse((self.store.DATA / "settings.json").exists())

    def test_a_calendar_keeps_its_event_ids(self):
        settings = lambda: json.loads((self.store.DATA / "settings.json").read_text())
        self.save(target_calendar="Family")
        self.assertEqual(settings()["uid_salt"], "Family", "a new calendar gets IDs unique to it")
        # a calendar set up with the original (unsalted) IDs keeps them on every save
        self.store.save_settings({**settings(), "uid_salt": ""})
        self.save(target_calendar="Family")
        self.assertEqual(settings()["uid_salt"], "")
        self.save(target_calendar="Kids")
        self.assertEqual(settings()["uid_salt"], "Kids", "switching calendars makes new IDs")

    def test_preview_keeps_the_previewed_settings_on_the_page(self):
        # after Preview the form must show what was previewed, so Save and Sync saves that
        from unittest import mock
        from applelook_server import web
        result = {"desired": 1, "created": 0, "updated": 0, "deleted": 0, "changes": []}
        with mock.patch.object(web.engine, "sync", return_value=result):
            page = self.c.post("/preview", follow_redirects=True, data={
                "csrf": csrf_of(self.c), "feed_url": "https://x.example/calendar.ics",
                "apple_id": "me@example.com", "icloud_password": "abcd-efgh-ijkl-mnop",
                "target_calendar": "Family", "label": "Work", "include_titles": "on",
                "skip_multiday_allday": "on"}).get_data(as_text=True)
        self.assertIn("A sync would add 0", page)
        self.assertRegex(page, r'name="include_titles" data-for="title_format" data-token="\{event\}" checked')
        self.assertRegex(page, r'name="skip_multiday_allday" checked')
        self.assertNotIn('name="takeover"', page)
        self.assertRegex(page, r'value="Family" selected')
        self.assertFalse((self.store.DATA / "settings.json").exists(), "Preview saves nothing")

    def test_title_template_is_saved_and_drives_the_titles_checkbox(self):
        settings = lambda: json.loads((self.store.DATA / "settings.json").read_text())
        page = self.save(label="Work", title_format="{event}   ({label})")
        self.assertEqual(settings()["title_format"], "{event} ({label})")
        self.assertTrue(settings()["include_titles"], "{event} in the template means titles are on")
        self.assertRegex(page, r'name="include_titles" data-for="title_format" data-token="\{event\}" checked')
        self.assertIn("Budget review (Work)", page)
        self.save(label="Work", title_format="{label}", include_titles="on")
        self.assertFalse(settings()["include_titles"], "the template wins over the checkbox")

    def test_alternative_label_is_saved(self):
        page = self.save(label="Work", title_format="{label} ({event})",
                         alt_label_keywords="ART, DES", alt_label="Teaching")
        cfg = json.loads((self.store.DATA / "settings.json").read_text())
        self.assertEqual((cfg["alt_label_keywords"], cfg["alt_label"]), (["ART", "DES"], "Teaching"))
        self.assertIn('value="ART, DES"', page)
        self.assertIn("Teaching (ART 120)", page)
        self.assertIn("<details open>", page, "Advanced opens when a rule is set")
        self.save(label="Work", title_format="{label} ({event})", alt_label_keywords="ART",
                  alt_label="Teaching", alt_title_format="{event}  ({label})")
        cfg = json.loads((self.store.DATA / "settings.json").read_text())
        self.assertEqual(cfg["alt_title_format"], "{event} ({label})")

    def test_alternative_title_checkboxes(self):
        page = self.save(label="Work", title_format="{label}", alt_label_keywords="ART",
                         alt_label="Teaching", alt_title_format="{event}")
        self.assertRegex(page, r'data-for="alt_title_format" data-token="\{event\}" checked')
        self.assertNotRegex(page, r'data-for="alt_title_format" data-token="\{label\}" checked')
        self.assertIn('placeholder="Enter keyword(s)"', page)

    def test_old_settings_show_the_matching_template(self):
        self.store.save_settings({**self.store.load_settings(), "label": "Work", "include_titles": True})
        page = self.c.get("/").get_data(as_text=True)
        self.assertIn('value="{label} ({event})"', page)
        self.assertIn("Work (Budget review)", page)

    def test_password_saved_privately_and_never_shown(self):
        # no follow-up page load: with an Apple ID and password saved it would contact iCloud
        page = self.c.post("/save", data={"csrf": csrf_of(self.c), "apple_id": "me@example.com",
                                          "icloud_password": "abcd-efgh-ijkl-mnop"}).get_data(as_text=True)
        path = self.store.DATA / "icloud-password"
        self.assertEqual(path.read_text(), "abcd-efgh-ijkl-mnop")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("abcd-efgh-ijkl-mnop", page)


class RetryTests(unittest.TestCase):
    """iCloud sometimes turns a good password away; a sync retries once, and only
    several failures in a row blame the password."""

    def setUp(self):
        self.app, self.store = make_app(auth="none")
        from applelook_server import web
        self.web = web
        self.store.save_settings({**self.store.load_settings(), "feed_url": "https://x.example/c.ics",
                                  "apple_id": "me@example.com", "target_calendar": "Family"})
        self.store.save_icloud_password("abcd-efgh-ijkl-mnop")
        self.ok = {"desired": 1, "created": 0, "updated": 0, "deleted": 0, "changes": []}

    def sync_with(self, *outcomes):
        from unittest import mock
        with mock.patch.object(self.web.engine, "sync", side_effect=list(outcomes)) as m:
            try:
                return self.web.run_sync(retry_wait=0), m.call_count
            except self.web.engine.SyncError as exc:
                return str(exc), m.call_count

    def test_one_rejection_is_retried(self):
        result, calls = self.sync_with(self.web.engine.AuthError("no"), self.ok)
        self.assertEqual((result, calls), (self.ok, 2))
        self.assertIsNone(self.web.status.last_error)

    def test_only_repeated_rejections_blame_the_password(self):
        no = self.web.engine.AuthError("no")
        for _ in range(2):
            message, _ = self.sync_with(no, no)
            self.assertIn("try again at the next sync", message)
        message, _ = self.sync_with(no, no)
        self.assertIn("3 syncs in a row", message)
        self.assertIn("account.apple.com", message)
        self.sync_with(self.ok)
        self.assertEqual(self.web.status.auth_fails, 0, "a good sync resets the count")

    def test_failures_reach_the_container_log(self):
        with self.assertLogs("applelook", level="WARNING") as logs:
            self.sync_with(self.web.engine.SyncError("The iCloud calendar 'Family' wasn't found."))
        self.assertTrue(any("sync failed" in line for line in logs.output))


if __name__ == "__main__":
    unittest.main()

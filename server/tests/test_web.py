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
        self.assertRegex(page, r'name="include_titles" checked')
        self.assertRegex(page, r'name="skip_multiday_allday" checked')
        self.assertNotIn('name="takeover"', page)
        self.assertRegex(page, r'value="Family" selected')
        self.assertFalse((self.store.DATA / "settings.json").exists(), "Preview saves nothing")

    def test_password_saved_privately_and_never_shown(self):
        # no follow-up page load: with an Apple ID and password saved it would contact iCloud
        page = self.c.post("/save", data={"csrf": csrf_of(self.c), "apple_id": "me@example.com",
                                          "icloud_password": "abcd-efgh-ijkl-mnop"}).get_data(as_text=True)
        path = self.store.DATA / "icloud-password"
        self.assertEqual(path.read_text(), "abcd-efgh-ijkl-mnop")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("abcd-efgh-ijkl-mnop", page)


if __name__ == "__main__":
    unittest.main()

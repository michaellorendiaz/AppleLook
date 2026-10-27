"""Settings and secrets, kept in the data folder (/data in the container)."""

import json
import os
import secrets
from pathlib import Path

from . import engine

DATA = Path(os.environ.get("APPLELOOK_DATA", "/data"))


def _write_private(path, text):
    """Write a file readable only by this user, replacing it atomically."""
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def load_settings():
    """feed_url, apple_id, target_calendar plus every engine option (defaults filled in)."""
    cfg = {"feed_url": "", "apple_id": "", "target_calendar": "", **engine.DEFAULTS}
    path = DATA / "settings.json"
    if path.exists():
        cfg.update(json.loads(path.read_text()))
    return cfg


def save_settings(cfg):
    DATA.mkdir(parents=True, exist_ok=True)
    _write_private(DATA / "settings.json", json.dumps(cfg, indent=2))


def icloud_password():
    """The app-specific password: ICLOUD_APP_PASSWORD if set, else the saved one."""
    env = os.environ.get("ICLOUD_APP_PASSWORD")
    if env:
        return env
    path = DATA / "icloud-password"
    return path.read_text().strip() if path.exists() else ""


def password_from_env():
    return bool(os.environ.get("ICLOUD_APP_PASSWORD"))


def save_icloud_password(password):
    DATA.mkdir(parents=True, exist_ok=True)
    _write_private(DATA / "icloud-password", password.strip())


def session_secret():
    """Signing key for login cookies, made once and kept."""
    DATA.mkdir(parents=True, exist_ok=True)
    path = DATA / "session-key"
    if not path.exists():
        _write_private(path, secrets.token_hex(32))
    return path.read_text().strip()


def is_complete(cfg):
    return bool(cfg["feed_url"] and cfg["apple_id"] and cfg["target_calendar"] and icloud_password())

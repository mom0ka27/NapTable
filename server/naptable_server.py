#!/usr/bin/env python3
"""Small persistent NapTable sharing/configuration server.

FastAPI on uvicorn, in one process. Intended for a LAN or private deployment;
put it behind TLS/authentication at the edge for a public deployment.
"""
from __future__ import annotations
import argparse, functools, hashlib, html, json, os, secrets, sqlite3, threading, time, re
from contextlib import asynccontextmanager
from email.utils import formatdate
from datetime import datetime, timedelta, timezone
from http.cookies import CookieError, SimpleCookie
from http.server import DEFAULT_ERROR_CONTENT_TYPE, DEFAULT_ERROR_MESSAGE, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse
from pathlib import Path

import anyio, uvicorn
from fastapi import Depends, FastAPI, Request, Response
from starlette.convertors import Convertor, register_url_convertor

try:  # `python3 server/naptable_server.py` and `import server.naptable_server`
    from . import app_attest, entitlements, holidays, live_activity, school_times
    from .live_activity_timeline import ProtocolError, identifier
except ImportError:  # pragma: no cover - depends on how the server was started
    import app_attest, entitlements, holidays, live_activity, school_times
    from live_activity_timeline import ProtocolError, identifier

STATIC_ROOT = Path(__file__).resolve().parent / "static"
SITE_ROOT = STATIC_ROOT / "site"
# The public website: a fixed list, so no request path ever reaches the filesystem.
SITE_ASSETS = {"site.css": "text/css; charset=utf-8", "site.js": "application/javascript; charset=utf-8", "theme.js": "application/javascript; charset=utf-8"}
for _name in ("week-view", "week-view-dark", "day-view", "month-view", "onboarding-import", "month-preview-light", "month-preview-dark"):
    SITE_ASSETS[f"img/{_name}.jpg"] = "image/jpeg"
for _name in ("icon", "favicon", "live-lock-screen", "live-island-expanded", "live-island-compact", "upcoming-widget", "two-day-widget"):
    SITE_ASSETS[f"img/{_name}.png"] = "image/png"
for _name in ("widget-small", "widget-small-two", "widget-medium", "widget-today-list", "widget-today-timeline", "widget-twoday-list", "widget-twoday-timeline", "widget-inline", "widget-circular", "widget-rectangular", "holiday-national", "holiday-midautumn"):
    for _scheme in ("light", "dark"):
        SITE_ASSETS[f"img/{_name}-{_scheme}.png"] = "image/png"
# Usage days follow the school clock, not UTC: "today" starts at 00:00 UTC+8.
USAGE_ZONE = timezone(timedelta(hours=8))

SCHEMA = """
CREATE TABLE IF NOT EXISTS usage_devices (
 installation_id TEXT PRIMARY KEY, secret_hash TEXT NOT NULL,
 school_id TEXT NOT NULL DEFAULT '', system_name TEXT NOT NULL,
 system_version TEXT NOT NULL, device_model TEXT NOT NULL, app_version TEXT NOT NULL,
 consent_version INTEGER NOT NULL, first_seen TEXT NOT NULL, last_seen TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS usage_devices_last_seen ON usage_devices(last_seen);
CREATE TABLE IF NOT EXISTS usage_daily (
 day TEXT PRIMARY KEY, active INTEGER NOT NULL DEFAULT 0, new INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS configuration_migrations (name TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS apns_config (
 id INTEGER PRIMARY KEY CHECK(id=1), key_path TEXT NOT NULL DEFAULT '',
 key_id TEXT NOT NULL DEFAULT '', team_id TEXT NOT NULL DEFAULT '',
 bundle_id TEXT NOT NULL DEFAULT '', tick_seconds REAL NOT NULL DEFAULT 5,
 channels_json TEXT NOT NULL DEFAULT '{}', updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS school_configs (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, semester_start TEXT NOT NULL,
 periods_json TEXT NOT NULL, note TEXT NOT NULL, updated_at TEXT NOT NULL,
 unified_holidays_enabled INTEGER NOT NULL DEFAULT 1,
 unified_makeup_enabled INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS school_terms (
 school_id TEXT NOT NULL, term_id TEXT NOT NULL, version INTEGER NOT NULL,
 semester_start_monday TEXT NOT NULL, week_count INTEGER NOT NULL,
 periods_json TEXT NOT NULL, timezone TEXT NOT NULL, note TEXT NOT NULL,
 updated_at TEXT NOT NULL, adjustments_json TEXT NOT NULL DEFAULT '[]',
 is_current INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY (school_id, term_id)
);
CREATE TABLE IF NOT EXISTS school_seasonal_periods (
 school_id TEXT PRIMARY KEY, periods_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS global_calendar (
 id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL DEFAULT 1,
 adjustments_json TEXT NOT NULL DEFAULT '[]', updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS admin_sessions (
 token_hash TEXT PRIMARY KEY, secret_hash TEXT NOT NULL,
 created_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS admin_audit (
 id INTEGER PRIMARY KEY, at TEXT NOT NULL, admin TEXT NOT NULL,
 action TEXT NOT NULL, target TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS admin_audit_at ON admin_audit(at);
CREATE TABLE IF NOT EXISTS shares (
 code TEXT PRIMARY KEY, write_token_hash TEXT NOT NULL, owner TEXT NOT NULL,
 school_id TEXT NOT NULL, school_name TEXT NOT NULL, payload_json TEXT NOT NULL,
 semester_start_monday TEXT NOT NULL DEFAULT '', class_time_list_json TEXT NOT NULL DEFAULT '[]',
 term_id TEXT NOT NULL DEFAULT '', term_version INTEGER NOT NULL DEFAULT 0, term_snapshot_json TEXT NOT NULL DEFAULT '{}',
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0
);
"""

def now(): return datetime.now(timezone.utc).isoformat()
def _usage_day(stamp): return stamp.astimezone(USAGE_ZONE).date().isoformat()

# The console keeps its session in a cookie so a page reload does not ask for
# the token again. It is bound to the admin token in force when it was issued,
# so rotating an admin's token signs that admin's consoles out.
ADMIN_COOKIE = "naptable_admin"
ADMIN_SESSION_TTL = timedelta(hours=12)
ADMIN_NAME = re.compile(r"[A-Za-z0-9._-]{1,40}")
# Wrong tokens, from the login form or the X-Admin-Token header, per client.
LOGIN_FAILURES = 10
LOGIN_WINDOW = timedelta(minutes=15)
# The audit log keeps this long; nothing in it is needed to run the service.
AUDIT_RETENTION = timedelta(days=365)

def admin_tokens():
    """Admin name -> token. NAPTABLE_ADMIN_TOKEN is the admin named "admin";
    NAPTABLE_ADMIN_TOKENS adds named ones, "alice=token1,bob=token2", so the
    audit log can say who did what and one person's token can be rotated alone."""
    return dict(_parse_admin_tokens(os.environ.get("NAPTABLE_ADMIN_TOKEN", "").strip(),
                                    os.environ.get("NAPTABLE_ADMIN_TOKENS", "")))

@functools.lru_cache(maxsize=8)
def _parse_admin_tokens(single, named):
    """Read once per value, so a bad entry is reported once, not per request."""
    tokens = {"admin": single} if single else {}
    for entry in named.split(","):
        name, separator, token = entry.strip().partition("=")
        name, token = name.strip(), token.strip()
        if not separator or not token or not ADMIN_NAME.fullmatch(name):
            if entry.strip(): print("NAPTABLE_ADMIN_TOKENS: ignoring an entry that is not name=token")
            continue
        tokens[name] = token
    return tuple(tokens.items())

def token_owner(supplied, tokens):
    """The name whose token `supplied` is, or None. Every token is compared,
    so the time taken does not say which name came closest."""
    found = None
    for name, token in tokens.items():
        if _same_secret(supplied, token) and found is None: found = name
    return found

class LoginThrottle:
    """Refuses a client after LOGIN_FAILURES wrong tokens within LOGIN_WINDOW.
    In memory: a restart forgets it, and nginx limits the rate in front."""
    def __init__(self, now=lambda: datetime.now(timezone.utc)):
        self.now, self.lock, self.failures = now, threading.Lock(), {}
    def _recent(self, client):
        cutoff = self.now() - LOGIN_WINDOW
        kept = [stamp for stamp in self.failures.get(client, ()) if stamp > cutoff]
        if kept: self.failures[client] = kept
        else: self.failures.pop(client, None)
        return kept
    def retry_after(self, client):
        """Seconds until `client` may try again; 0 when it may now."""
        with self.lock:
            recent = self._recent(client)
            if len(recent) < LOGIN_FAILURES: return 0
            # Open again once the oldest of the last LOGIN_FAILURES leaves the window.
            return max(1, int((recent[-LOGIN_FAILURES] + LOGIN_WINDOW - self.now()).total_seconds()) + 1)
    def fail(self, client):
        with self.lock:
            self.failures.setdefault(client, []).append(self.now())
            if len(self.failures) > 10000:  # a flood of addresses cannot grow this without bound
                for key in list(self.failures)[:5000]: self.failures.pop(key, None)

class PublishLimiter:
    """At most `limit(key)` publishes per key in the last hour. In memory, like
    LoginThrottle: a restart forgets it."""
    def __init__(self, now=time.time):
        self.now, self.lock, self.stamps = now, threading.Lock(), {}
    def retry_after(self, key, limit):
        """Seconds until `key` may publish again, counting this one when it may now."""
        with self.lock:
            cutoff = self.now() - 3600
            recent = [stamp for stamp in self.stamps.get(key, ()) if stamp > cutoff]
            if len(recent) >= limit:
                self.stamps[key] = recent
                return max(1, int(recent[-limit] + 3600 - self.now()) + 1)
            self.stamps[key] = recent + [self.now()]
            if len(self.stamps) > 20000:  # a flood of keys cannot grow this without bound
                for stale in list(self.stamps)[:10000]: self.stamps.pop(stale, None)
            return 0

def publisher_label(publisher):
    """A share's publisher as the admin sees it: the kind and the first
    characters of the hashed device id or address."""
    kind, _, digest = (publisher or "").partition(":")
    return {"kind": kind, "id": digest[:8]} if digest else None

class ShareQuotaError(ValueError):
    """A publish refused for a quota: answered 429, not 400."""

# A share is handed back in one response and installed as one table, so the
# payload is bounded here rather than left to whatever a client uploads.
MAX_COURSES = 600
MAX_COURSE_BYTES = 256 * 1024
MAX_OWNER_LENGTH = 40
MAX_REQUEST_BYTES = 1024 * 1024
# Anti-abuse. A publisher known by its App Attest key holds at most this
# many shares; anyone publishes at most PUBLISH_PER_HOUR new or replaced shares
# an hour (a bare address, often a whole campus behind one NAT, gets more); a
# share nobody reads or updates for SHARE_IDLE_DAYS is deleted.
MAX_ACTIVE_SHARES = 10
PUBLISH_PER_HOUR = 20
PUBLISH_PER_HOUR_BY_ADDRESS = 120
# New shares a day from publishers known only by address, across everyone:
# past it only attested devices may publish.
UNIDENTIFIED_SHARES_PER_DAY = 3000
SHARE_IDLE_DAYS = 180
# Writes an hour from one address without App Attest (simulators, older apps,
# scripts), per endpoint. Publishing has its own, stricter quotas below.
UNATTESTED_PER_HOUR = {"share.update": 600, "liveActivity.register": 300, "liveActivity.timetable": 600, "usage.report": 600}
SHARE_CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ"

MAX_ADJUSTMENTS = 200
ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")

def normalize_adjustments(value):
    """Validate the global 调休 table.

    The client covers the timetable by date: `off` removes a day's classes and
    `swap` makes a day run another day's. A `swap` without a usable source
    would silently delete a day of classes on the client, so it is rejected
    here instead of being stored.
    """
    if value is None: return []
    if not isinstance(value, list): raise ValueError("adjustments must be a list")
    if len(value) > MAX_ADJUSTMENTS: raise ValueError(f"最多配置 {MAX_ADJUSTMENTS} 条调休")
    rows = []
    seen_dates = set()
    seen_sources = set()
    for item in value:
        if not isinstance(item, dict): raise ValueError("each adjustment must be an object")
        date = str(item.get("date", "")).strip()
        kind = str(item.get("kind", "")).strip()
        if not ISO_DATE.fullmatch(date) or not _is_date(date): raise ValueError(f"调休日期无效：{date or '(空)'}")
        if date in seen_dates: raise ValueError(f"{date} 只能配置一次调休")
        seen_dates.add(date)
        if kind not in ("off", "swap"): raise ValueError("调休类型只能是 off 或 swap")
        source = str(item.get("source") or "").strip()
        if kind == "swap":
            if not ISO_DATE.fullmatch(source) or not _is_date(source): raise ValueError(f"{date} 是调课，必须写明上哪一天的课")
            if source == date: raise ValueError(f"{date} 不能调到自己当天")
            if source in seen_sources: raise ValueError(f"{source} 只能被调到一个日期")
            seen_sources.add(source)
        else:
            source = ""
        row = {"date": date, "kind": kind, "note": str(item.get("note") or "")[:80]}
        if source: row["source"] = source
        rows.append(row)
    return rows

def _is_date(value):
    from datetime import date as _date
    try:
        _date.fromisoformat(value); return True
    except ValueError:
        return False

MAX_WEEK = 40
# (field names, lowest, highest) as `ImportedSchedule.makeCourse` reads them.
# 0 is legal where it means "no fixed slot" (free-time rows) or, for
# time_count (periods *after* the first), "one period"; a free-time row may
# carry a negative count, which the client clamps.
COURSE_BOUNDS = ((("week_time", "weekTime"), 0, 7), (("start_time", "startTime"), 0, 64),
                 (("time_count", "timeCount"), -64, 31))

def _bounded(value, low, high, name):
    """An integer in [low, high]. Numeric strings pass, since the client's codec
    accepts them; floats, booleans and anything larger are refused."""
    if isinstance(value, str) and re.fullmatch(r"\s*-?\d{1,12}\s*", value): value = int(value)
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{name} 必须是 {low}-{high} 的整数")
    return value

def _text(value, name, limit=200):
    """An optional string field of an admin form; None means empty."""
    if value is None: return ""
    if not isinstance(value, str): raise ValueError(f"{name} must be a string")
    if len(value) > limit: raise ValueError(f"{name} 最多 {limit} 个字符")
    return value

def normalize_courses(value):
    """Validate uploaded rows and return them with their encoded form.

    `CoursePayloadCodec` on the client is deliberately tolerant about field
    shapes, so the server only enforces what makes a share storable and
    readable: a list of objects, each carrying a name, small enough to return
    whole.
    """
    if value is None: value = []
    if not isinstance(value, list): raise ValueError("courses must be a list")
    if len(value) > MAX_COURSES: raise ValueError(f"一张课表最多 {MAX_COURSES} 门课程")
    for course in value:
        if not isinstance(course, dict): raise ValueError("each course must be an object")
        name = course.get("name")
        if not isinstance(name, str) or not name.strip(): raise ValueError("每门课程都需要名称")
        # Readers decode these into fixed-width integers: an unbounded value
        # crashes the app that installs the share.
        for keys, low, high in COURSE_BOUNDS:
            for key in keys:
                if course.get(key) is not None: _bounded(course[key], low, high, key)
        weeks = course.get("weeks")
        if isinstance(weeks, str):
            # The Flutter-era `"[1,2,3]"` string: every number in it is a week,
            # as `ImportedSchedule.normalizeWeeks` reads it.
            if len(weeks) > 400: raise ValueError("weeks 过长")
            weeks = re.findall(r"\d+", weeks)
        if isinstance(weeks, list):
            if len(weeks) > 400: raise ValueError("weeks 过长")
            for week in weeks: _bounded(week, 1, MAX_WEEK, "weeks")
        elif weeks is not None: raise ValueError("weeks must be a list")
    encoded = json.dumps(value, ensure_ascii=False)
    if len(encoded.encode()) > MAX_COURSE_BYTES: raise ValueError("课表内容过大，无法分享")
    return value, encoded

def normalize_periods(value):
    if not isinstance(value, list) or not value:
        raise ValueError("学校至少需要一个节次")
    rows = []
    previous = ""
    for index, period in enumerate(value, 1):
        if not isinstance(period, dict): raise ValueError("each period must be an object")
        start, end = str(period.get("start", "")), str(period.get("end", ""))
        if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", start) or not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", end):
            raise ValueError("invalid period time")
        if start >= end or (previous and start < previous):
            raise ValueError("periods must be ordered and non-overlapping")
        rows.append({"id": index, "name": f"第{index}节", "start": start, "end": end})
        previous = end
    return rows

class SchoolExists(ValueError):
    """`save_school(create=True)` for an id already in the catalogue."""

class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.lock:
            self.db.executescript(SCHEMA)
            terms = {row[1] for row in self.db.execute("PRAGMA table_info(school_terms)")}
            school_columns = {row[1] for row in self.db.execute("PRAGMA table_info(school_configs)")}
            if "unified_holidays_enabled" not in school_columns:
                self.db.execute("ALTER TABLE school_configs ADD COLUMN unified_holidays_enabled INTEGER NOT NULL DEFAULT 1")
            if "unified_makeup_enabled" not in school_columns:
                self.db.execute("ALTER TABLE school_configs ADD COLUMN unified_makeup_enabled INTEGER NOT NULL DEFAULT 1")
            if "adjustments_json" not in terms: self.db.execute("ALTER TABLE school_terms ADD COLUMN adjustments_json TEXT NOT NULL DEFAULT '[]'")
            if "is_current" not in terms: self.db.execute("ALTER TABLE school_terms ADD COLUMN is_current INTEGER NOT NULL DEFAULT 0")
            shares = {row[1] for row in self.db.execute("PRAGMA table_info(shares)")}
            if "adjustments_json" not in shares: self.db.execute("ALTER TABLE shares ADD COLUMN adjustments_json TEXT NOT NULL DEFAULT '[]'")
            columns = {row[1] for row in self.db.execute("PRAGMA table_info(shares)")}
            if "semester_start_monday" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN semester_start_monday TEXT NOT NULL DEFAULT ''")
            if "class_time_list_json" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN class_time_list_json TEXT NOT NULL DEFAULT '[]'")
            if "schedule_scope" not in columns:
                self.db.execute("ALTER TABLE shares ADD COLUMN schedule_scope TEXT NOT NULL DEFAULT ''")
            for row in self.db.execute("SELECT code FROM shares WHERE schedule_scope='' ").fetchall():
                self.db.execute("UPDATE shares SET schedule_scope=? WHERE code=?", (secrets.token_hex(16), row[0]))
            if "term_id" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN term_id TEXT NOT NULL DEFAULT ''")
            if "term_version" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN term_version INTEGER NOT NULL DEFAULT 0")
            if "term_snapshot_json" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN term_snapshot_json TEXT NOT NULL DEFAULT '{}'")
            # The Sign in with Apple account that published it, from before accounts were removed.
            if "account" in columns: self.db.execute("ALTER TABLE shares DROP COLUMN account")
            # Who publishes it, for quotas and the admin: a hash of its App Attest key, else of its address.
            if "publisher" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN publisher TEXT NOT NULL DEFAULT ''")
            # When someone last downloaded it (at most daily): a share nobody reads or updates expires.
            if "last_read_at" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN last_read_at TEXT NOT NULL DEFAULT ''")
            self.db.execute("CREATE INDEX IF NOT EXISTS shares_publisher ON shares(publisher)")
            # Revoking or replacing a share used to only flag the row.
            self.db.execute("DELETE FROM shares WHERE revoked!=0")
            self.db.commit(); self.seed(); self._migrate_configuration_model()
        self.expired_at = 0.0
        self.expire_shares()
    def close(self):
        with self.lock: self.db.close()
    @staticmethod
    def _digest(value): return hashlib.sha256(value.encode()).hexdigest()
    def create_admin_session(self, secret, ttl=ADMIN_SESSION_TTL):
        raw = secrets.token_urlsafe(32)
        stamp = datetime.now(timezone.utc)
        with self.lock, self.db:
            self.db.execute("DELETE FROM admin_sessions WHERE expires_at<=?", (stamp.isoformat(),))
            self.db.execute("INSERT INTO admin_sessions (token_hash,secret_hash,created_at,expires_at) VALUES (?,?,?,?)",
                            (self._digest(raw), self._digest(secret), stamp.isoformat(), (stamp + ttl).isoformat()))
        return raw
    def admin_session_valid(self, raw, tokens, ttl=ADMIN_SESSION_TTL):
        """The admin a console session cookie belongs to, or None. Its expiry
        slides, so an admin who keeps working is not signed out mid-edit."""
        if not raw or not tokens: return None
        digest = self._digest(raw)
        stamp = datetime.now(timezone.utc)
        with self.lock, self.db:
            row = self.db.execute("SELECT secret_hash,expires_at FROM admin_sessions WHERE token_hash=?", (digest,)).fetchone()
            if not row: return None
            name = next((name for name, token in tokens.items()
                         if secrets.compare_digest(row["secret_hash"], self._digest(token))), None)
            if row["expires_at"] <= stamp.isoformat() or name is None:
                self.db.execute("DELETE FROM admin_sessions WHERE token_hash=?", (digest,))
                return None
            self.db.execute("UPDATE admin_sessions SET expires_at=? WHERE token_hash=?", ((stamp + ttl).isoformat(), digest))
        return name
    def audit(self, admin, action, target="", detail=None):
        stamp = datetime.now(timezone.utc)
        with self.lock, self.db:
            self.db.execute("DELETE FROM admin_audit WHERE at<?", ((stamp - AUDIT_RETENTION).isoformat(),))
            self.db.execute("INSERT INTO admin_audit (at,admin,action,target,detail) VALUES (?,?,?,?,?)",
                            (stamp.isoformat(), admin or "", action, str(target or ""),
                             json.dumps(detail or {}, ensure_ascii=False)))
    def audit_log(self, action="", limit=200):
        """The newest entries, optionally of one action or one action family
        ("school" matches school.save, school.delete…)."""
        where, params = "", ()
        if action:
            where, params = "WHERE action=? OR action LIKE ?", (action, action.replace("%", "").replace("_", "") + ".%")
        with self.lock:
            rows = self.db.execute(f"SELECT * FROM admin_audit {where} ORDER BY id DESC LIMIT ?", (*params, limit)).fetchall()
        return {"entries": [{"at": r["at"], "admin": r["admin"], "action": r["action"], "target": r["target"],
                             "detail": json.loads(r["detail"] or "{}")} for r in rows]}
    def delete_admin_session(self, raw):
        if not raw: return
        with self.lock, self.db:
            self.db.execute("DELETE FROM admin_sessions WHERE token_hash=?", (self._digest(raw),))
    def apns_config(self):
        """Return the WebUI-managed APNs settings, or None before first save."""
        with self.lock:
            row = self.db.execute("SELECT * FROM apns_config WHERE id=1").fetchone()
        if not row:
            return None
        try:
            channels = json.loads(row["channels_json"] or "{}")
        except (TypeError, ValueError, json.JSONDecodeError):
            channels = {}
        return {
            "keyPath": row["key_path"], "keyID": row["key_id"],
            "teamID": row["team_id"], "bundleID": row["bundle_id"],
            "tickSeconds": row["tick_seconds"], "channels": channels,
            "updatedAt": row["updated_at"],
        }
    def save_apns_config(self, value):
        """Validate and persist settings supplied by the administrator."""
        if not isinstance(value, dict): raise ValueError("APNs config must be an object")
        fields = {key: str(value.get(key) or "").strip() for key in ("keyPath", "keyID", "teamID", "bundleID")}
        if any(fields.values()) and not all(fields.values()):
            raise ValueError("keyPath、keyID、teamID 和 bundleID 必须同时填写")
        try:
            tick = float(value.get("tickSeconds", 5))
        except (TypeError, ValueError):
            raise ValueError("推送调度间隔必须是数字")
        if not 0.5 <= tick <= 3600:
            raise ValueError("推送调度间隔必须在 0.5-3600 秒之间")
        existing = self.apns_config()
        # Broadcast channels belong to one APNs app. Reusing them after a
        # Bundle ID change would make every broadcast fail against the new app.
        same_app = existing and existing.get("bundleID") == fields["bundleID"]
        clean_channels = dict(existing.get("channels", {})) if same_app else {}
        # Preserve legacy manually configured channels on the first migration.
        if not clean_channels:
            for key, channel in (value.get("channels") or {}).items():
                if isinstance(channel, dict): channel = channel.get("channelID") or channel.get("channelId")
                environment, separator, school_id = str(key).strip().partition(":")
                channel = str(channel or "").strip()
                if separator and environment in ("production", "sandbox") and school_id and channel:
                    clean_channels[f"{environment}:{school_id}"] = channel
        stamp = now()
        with self.lock, self.db:
            self.db.execute(
                "INSERT INTO apns_config (id,key_path,key_id,team_id,bundle_id,tick_seconds,channels_json,updated_at) VALUES (1,?,?,?,?,?,?,?) "
                "ON CONFLICT(id) DO UPDATE SET key_path=excluded.key_path,key_id=excluded.key_id,team_id=excluded.team_id,bundle_id=excluded.bundle_id,tick_seconds=excluded.tick_seconds,channels_json=excluded.channels_json,updated_at=excluded.updated_at",
                (fields["keyPath"], fields["keyID"], fields["teamID"], fields["bundleID"], tick,
                 json.dumps(clean_channels, ensure_ascii=False), stamp))
        return self.apns_config()
    def seed(self):
        if self.db.execute("SELECT 1 FROM configuration_migrations WHERE name='editable-school-catalog'").fetchone():
            return
        # Remove only the former built-in CPU entry; preserve administrator entries.
        legacy = self.db.execute("SELECT 1 FROM school_configs WHERE id='cpu' AND note=?",
                                 ("CPU 客户端共享服务配置；校历以 CPU 教务数据为准",)).fetchone()
        if legacy:
            self.db.execute("DELETE FROM school_terms WHERE school_id='cpu'")
            self.db.execute("DELETE FROM school_configs WHERE id='cpu'")
        periods = [{"id": i, "name": f"第{i}节", "start": s, "end": e} for i,(s,e) in enumerate([
            ("08:00","08:50"),("09:00","09:50"),("10:10","11:00"),("11:10","12:00"),
            ("14:00","14:50"),("15:00","15:50"),("16:10","17:00"),("17:10","18:00"),
            ("18:30","19:20"),("19:30","20:20"),("20:30","21:20"),("21:30","22:20"),("22:30","23:59")], 1)]
        row = self.db.execute("SELECT 1 FROM school_configs WHERE id='nju'").fetchone()
        if not row:
            self.db.execute("INSERT INTO school_configs (id,name,semester_start,periods_json,note,updated_at) VALUES (?,?,?,?,?,?)", ("nju","南京大学","",json.dumps(periods,ensure_ascii=False),"模板时间，需按校历校准",now()))
            self.db.commit()
        term = self.db.execute("SELECT 1 FROM school_terms WHERE school_id='nju' AND term_id='2026-fall-template'").fetchone()
        if not term:
            row = self.db.execute("SELECT periods_json FROM school_configs WHERE id='nju'").fetchone()
            self.db.execute("INSERT INTO school_terms (school_id,term_id,version,semester_start_monday,week_count,periods_json,timezone,note,updated_at,adjustments_json) VALUES (?,?,?,?,?,?,?,?,?,'[]')", ("nju", "2026-fall-template", 1, "2026-09-14", 18, row[0], "Asia/Shanghai", "模板，未按官方校历校准", now()))
            self.db.commit()
        self.db.execute("INSERT INTO configuration_migrations (name) VALUES ('editable-school-catalog')")
        self.db.commit()
    def _migrate_configuration_model(self):
        """Promote school periods, one current term and one global calendar.

        Legacy columns remain so existing databases and frozen shares stay
        readable; all new reads are composed from the normalized owners.
        """
        from datetime import date, timedelta
        today = date.today()
        schools = self.db.execute("SELECT id,periods_json FROM school_configs").fetchall()
        for school in schools:
            try: periods = json.loads(school["periods_json"] or "[]")
            except json.JSONDecodeError: periods = []
            if not periods:
                legacy = self.db.execute(
                    "SELECT periods_json FROM school_terms WHERE school_id=? ORDER BY updated_at DESC LIMIT 1",
                    (school["id"],)).fetchone()
                if legacy:
                    self.db.execute("UPDATE school_configs SET periods_json=? WHERE id=?", (legacy[0], school["id"]))
            current = self.db.execute(
                "SELECT 1 FROM school_terms WHERE school_id=? AND is_current=1", (school["id"],)).fetchone()
            if current: continue
            terms = self.db.execute(
                "SELECT term_id,semester_start_monday,week_count FROM school_terms WHERE school_id=?",
                (school["id"],)).fetchall()
            candidates = []
            for term in terms:
                try:
                    start = date.fromisoformat(term["semester_start_monday"])
                    active = start <= today < start + timedelta(days=max(1, int(term["week_count"])) * 7)
                    candidates.append((active, start, term["term_id"]))
                except (TypeError, ValueError): pass
            if candidates:
                chosen = max(candidates, key=lambda item: (item[0], item[1]))[2]
                self.db.execute("UPDATE school_terms SET is_current=1 WHERE school_id=? AND term_id=?",
                                (school["id"], chosen))
        if not self.db.execute("SELECT 1 FROM global_calendar WHERE id=1").fetchone():
            merged = {}
            for row in self.db.execute("SELECT adjustments_json FROM school_terms ORDER BY updated_at"):
                try:
                    for item in json.loads(row[0] or "[]"): merged[item.get("date")] = item
                except (TypeError, json.JSONDecodeError): pass
            rows = [item for key, item in sorted(merged.items()) if key]
            self.db.execute("INSERT INTO global_calendar VALUES (1,1,?,?)",
                            (json.dumps(rows, ensure_ascii=False), now()))
        self.db.commit()
    def global_calendar(self):
        with self.lock:
            row = self.db.execute("SELECT * FROM global_calendar WHERE id=1").fetchone()
        return {"version": row["version"], "adjustments": json.loads(row["adjustments_json"] or "[]"),
                "updatedAt": row["updated_at"]}
    def save_global_calendar(self, value):
        adjustments = normalize_adjustments(value.get("adjustments") if isinstance(value, dict) else None)
        stamp = now()
        with self.lock, self.db:
            self.db.execute("UPDATE global_calendar SET version=version+1,adjustments_json=?,updated_at=? WHERE id=1",
                            (json.dumps(adjustments, ensure_ascii=False), stamp))
            self.db.execute("UPDATE school_terms SET version=version+1,updated_at=?", (stamp,))
        return self.global_calendar()
    def import_calendar(self, value):
        """Preview the published arrangement against what is already stored.

        Nothing is written: the admin reviews the rows, fills in which day's
        classes each worked weekend runs, and saves through the normal path.
        """
        raw_years = value.get("years") if isinstance(value, dict) else None
        academic_year = value.get("academicYear") if isinstance(value, dict) else None
        start_date = end_date = None
        if academic_year is not None:
            if type(academic_year) is not int or not 2000 <= academic_year <= 2100 or raw_years is not None:
                raise ValueError("academicYear 必须是 2000-2100 的整数，且不能与 years 同时指定")
            years = [academic_year, academic_year + 1]
            start_date, end_date = f"{academic_year}-09-01", f"{academic_year + 1}-07-31"
        elif raw_years:
            try:
                years = sorted({int(year) for year in raw_years})
            except (TypeError, ValueError):
                raise ValueError("years 必须是年份列表")
            if len(years) > 5 or any(year < 2000 or year > 2100 for year in years):
                raise ValueError("years 超出范围")
        else:
            years = holidays.years_to_fetch(datetime.now(timezone(timedelta(hours=8))).date())
        existing = self.global_calendar()["adjustments"]
        results, errors = [], []
        for year in years:
            try:
                arrangement = holidays.fetch_year(year)
            except holidays.HolidayError as error:
                errors.append(str(error))
                continue
            days = arrangement["days"]
            if start_date:
                days = [row for row in days if start_date <= row["date"] <= end_date]
            plan = holidays.plan(days, existing)
            results.append({"year": year, "source": arrangement["source"],
                            "papers": arrangement["papers"], **plan})
        if not results and errors:
            raise ValueError("；".join(errors))
        return {"years": results, "errors": errors, "startDate": start_date, "endDate": end_date,
                "proposed": [row for item in results for row in item["proposed"]]}
    def schools(self):
        with self.lock:
            rows=self.db.execute("SELECT * FROM school_configs ORDER BY id").fetchall()
            return [self.school(r) for r in rows]
    def school(self, r):
        terms = self.db.execute("SELECT * FROM school_terms WHERE school_id=? ORDER BY semester_start_monday DESC,term_id", (r["id"],)).fetchall()
        current = next((term["term_id"] for term in terms if term["is_current"]), None)
        periods = json.loads(r["periods_json"] or "[]")
        seasons = school_times.stored_seasons(self.db, r["id"])
        if seasons and len(periods) != len(seasons[0]["periods"]):
            periods = normalize_periods(seasons[-1]["periods"])
        return {"id":r["id"],"name":r["name"],"timezone":"Asia/Shanghai","periods":periods,
                "unifiedHolidaysEnabled": bool(r["unified_holidays_enabled"]),
                "unifiedMakeupEnabled": bool(r["unified_makeup_enabled"]),
                "seasonalPeriods":seasons,
                "currentTermID":current,"terms":[self.term(t, periods) for t in terms],
                "note":r["note"],"updatedAt":r["updated_at"]}
    def term(self, r, periods=None):
        if periods is None:
            school = self.db.execute("SELECT periods_json FROM school_configs WHERE id=?", (r["school_id"],)).fetchone()
            periods = json.loads(school[0] or "[]") if school else []
        seasons = school_times.stored_seasons(self.db, r["school_id"])
        if seasons and len(periods) != len(seasons[0]["periods"]):
            periods = normalize_periods(seasons[-1]["periods"])
        school_config = self.db.execute("SELECT unified_holidays_enabled,unified_makeup_enabled FROM school_configs WHERE id=?", (r["school_id"],)).fetchone()
        adjustments = self.global_calendar()["adjustments"]
        if school_config and not school_config["unified_holidays_enabled"]:
            adjustments = [item for item in adjustments if item.get("kind") != "off"]
        if school_config and not school_config["unified_makeup_enabled"]:
            adjustments = [item for item in adjustments if item.get("kind") != "swap"]
        return {"id":r["term_id"],"version":r["version"],"semesterStartMonday":r["semester_start_monday"],
                "seasonalPeriods":seasons,
                "weekCount":r["week_count"],"periods":periods,"adjustments":adjustments,
                "timezone":r["timezone"],"note":r["note"],"current":bool(r["is_current"]),"updatedAt":r["updated_at"]}
    def find_term(self, school_id, term_id):
        with self.lock:
            r=self.db.execute("SELECT * FROM school_terms WHERE school_id=? AND term_id=?",(school_id,term_id)).fetchone()
        return self.term(r) if r else None
    def delete_school(self, school_id):
        # Shares carry frozen snapshots and remain readable after removal.
        with self.lock, self.db:
            deleted = self.db.execute("DELETE FROM school_configs WHERE id=?", (school_id,)).rowcount
            if deleted:
                self.db.execute("DELETE FROM school_terms WHERE school_id=?", (school_id,))
                self.db.execute("DELETE FROM school_seasonal_periods WHERE school_id=?", (school_id,))
            return bool(deleted)
    def rename_school(self, old_id, new_id):
        if not isinstance(new_id, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{1,79}", new_id):
            raise ValueError("invalid school id")
        with self.lock, self.db:
            row = self.db.execute("SELECT 1 FROM school_configs WHERE id=?", (old_id,)).fetchone()
            if not row:
                return None
            if old_id != new_id:
                if self.db.execute("SELECT 1 FROM school_configs WHERE id=?", (new_id,)).fetchone():
                    raise ValueError("school id already exists")
                self.db.execute("UPDATE school_configs SET id=?,updated_at=? WHERE id=?", (new_id, now(), old_id))
                self.db.execute("UPDATE school_terms SET school_id=? WHERE school_id=?", (new_id, old_id))
                seasons = school_times.stored_seasons(self.db, old_id)
                self.db.execute("DELETE FROM school_seasonal_periods WHERE school_id=?", (old_id,))
                self.db.execute("INSERT OR REPLACE INTO school_seasonal_periods VALUES (?,?)", (new_id, json.dumps(seasons)))
                self.db.execute("UPDATE usage_devices SET school_id=? WHERE school_id=?", (new_id, old_id))
                # Shares retain their frozen timetable, name and scope; only the
                # reference used by resync and clients changes.
                self.db.execute("UPDATE shares SET school_id=? WHERE school_id=?", (new_id, old_id))
                tables = {row[0] for row in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                for table in ("la_devices", "la_day_channels"):
                    if table in tables:
                        self.db.execute(f"UPDATE {table} SET school_id=? WHERE school_id=?", (new_id, old_id))
                if {"la_timetables", "la_channels", "la_schedule_versions", "la_v2_broadcasts"} <= tables:
                    # Leftovers of a deleted school with the new id would collide
                    # with the moved rows; they go once their channels retire.
                    if any(self.db.execute(f"SELECT 1 FROM {table} WHERE school=? LIMIT 1", (new_id,)).fetchone()
                           for table in ("la_channels", "la_schedule_versions")):
                        raise ValueError("该学校 ID 的旧实时活动频道仍在回收，请稍后再试")
                    self.db.execute("UPDATE la_timetables SET school=? WHERE school=?", (new_id, old_id))
                    self.db.execute("UPDATE la_schedule_versions SET school=? WHERE school=?", (new_id, old_id))
                    # The channel's logical key names the school: broadcasts follow it.
                    key = "bundle||':'||environment||':'||?||':'||schedule||':'||version||':end-period-'||final_period"
                    self.db.execute(f"UPDATE la_v2_broadcasts SET channel_key=(SELECT {key} FROM la_channels c WHERE c.logical_key=la_v2_broadcasts.channel_key) "
                                    "WHERE channel_key IN (SELECT logical_key FROM la_channels WHERE school=?)", (new_id, old_id))
                    self.db.execute(f"UPDATE la_channels SET school=?,logical_key={key} WHERE school=?", (new_id, new_id, old_id))
                config = self.db.execute("SELECT channels_json FROM apns_config WHERE id=1").fetchone()
                if config:
                    channels = json.loads(config[0] or "{}")
                    for environment in ("production", "sandbox"):
                        previous = f"{environment}:{old_id}"
                        if previous in channels:
                            channels[f"{environment}:{new_id}"] = channels.pop(previous)
                    self.db.execute("UPDATE apns_config SET channels_json=? WHERE id=1",
                                    (json.dumps(channels, ensure_ascii=False),))
            return self.school(self.db.execute("SELECT * FROM school_configs WHERE id=?", (new_id,)).fetchone())
    def save_school(self, value, create=False):
        """Insert or update a school. With `create`, an existing id is left
        alone and reported, so a console adding a school cannot overwrite one."""
        name = _text(value.get("name"), "name", 80).strip()
        if not value.get("id") or not name: raise ValueError("id/name/periods are required")
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{1,79}", str(value["id"])):
            raise ValueError("invalid school id")
        semester_start = _text(value.get("semesterStart"), "semesterStart", 40)
        note = _text(value.get("note"), "note", 400)
        holidays_enabled = value.get("unifiedHolidaysEnabled", True)
        makeup_enabled = value.get("unifiedMakeupEnabled", True)
        if type(holidays_enabled) is not bool or type(makeup_enabled) is not bool:
            raise ValueError("统一放假和调休开关必须是布尔值")
        periods = normalize_periods(value.get("periods"))
        stamp=now()
        with self.lock, self.db:
            existing = self.db.execute("SELECT periods_json,unified_holidays_enabled,unified_makeup_enabled FROM school_configs WHERE id=?", (value["id"],)).fetchone()
            if create and existing is not None: raise SchoolExists(value["id"])
            previous_seasons = school_times.stored_seasons(self.db, value["id"])
            seasons = school_times.normalize_seasons(value.get("seasonalPeriods", previous_seasons))
            if "seasonalPeriods" not in value and seasons and len(periods) != len(seasons[0]["periods"]):
                periods = normalize_periods(seasons[-1]["periods"])
            seasons = school_times.normalize_seasons(seasons, len(periods))
            encoded_periods = json.dumps(periods, ensure_ascii=False)
            policy_changed = existing is None or bool(existing["unified_holidays_enabled"]) != holidays_enabled or bool(existing["unified_makeup_enabled"]) != makeup_enabled
            periods_changed = existing is None or json.loads(existing["periods_json"] or "[]") != periods or previous_seasons != seasons or policy_changed
            self.db.execute("INSERT INTO school_configs (id,name,semester_start,periods_json,note,updated_at,unified_holidays_enabled,unified_makeup_enabled) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,semester_start=excluded.semester_start,periods_json=excluded.periods_json,note=excluded.note,updated_at=excluded.updated_at,unified_holidays_enabled=excluded.unified_holidays_enabled,unified_makeup_enabled=excluded.unified_makeup_enabled", (value["id"],name,semester_start,encoded_periods,note,stamp,int(holidays_enabled),int(makeup_enabled)))
            self.db.execute("INSERT OR REPLACE INTO school_seasonal_periods VALUES (?,?)", (value["id"], json.dumps(seasons)))
            if periods_changed:
                self.db.execute("UPDATE school_terms SET version=version+1,updated_at=? WHERE school_id=?", (stamp, value["id"]))
            return self.school(self.db.execute("SELECT * FROM school_configs WHERE id=?", (value["id"],)).fetchone())
    def save_term(self, school_id, value):
        """Insert or update one term of a school; the version and the current
        flag are decided inside the write, so concurrent saves cannot race."""
        required=[value.get("id"),value.get("semesterStartMonday"),value.get("weekCount"),value.get("timezone")]
        if not all(required): raise ValueError("term id, semesterStartMonday, weekCount and timezone are required")
        if not isinstance(value["id"], str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{1,79}", value["id"]):
            raise ValueError("invalid term id")
        if type(value["weekCount"]) is not int or not 1 <= value["weekCount"] <= 40:
            raise ValueError("weekCount must be an integer between 1 and 40")
        if value["timezone"] != "Asia/Shanghai" or not isinstance(value["semesterStartMonday"], str) or not ISO_DATE.fullmatch(value["semesterStartMonday"]):
            raise ValueError("only Asia/Shanghai and ISO date are supported")
        from datetime import date
        try: parsed=date.fromisoformat(value["semesterStartMonday"])
        except ValueError: raise ValueError("invalid semesterStartMonday")
        if parsed.isoweekday() != 1: raise ValueError("semesterStartMonday must be Monday")
        note = _text(value.get("note"), "note", 400)
        requested = value.get("current")
        if requested is not None and not isinstance(requested, bool): raise ValueError("current must be a boolean")
        stamp=now()
        with self.lock, self.db:
            if not self.db.execute("SELECT 1 FROM school_configs WHERE id=?", (school_id,)).fetchone():
                raise ValueError("unknown schoolID")
            last=self.db.execute("SELECT is_current FROM school_terms WHERE school_id=? AND term_id=?",(school_id,value["id"])).fetchone()
            other_current = self.db.execute(
                "SELECT 1 FROM school_terms WHERE school_id=? AND term_id!=? AND is_current=1",
                (school_id, value["id"])).fetchone()
            # A school must always retain one current term. Switch by marking
            # another term current, not by clearing the only one.
            make_current = requested is True or not other_current
            if make_current: self.db.execute("UPDATE school_terms SET is_current=0 WHERE school_id=?", (school_id,))
            self.db.execute("INSERT INTO school_terms (school_id,term_id,version,semester_start_monday,week_count,periods_json,timezone,note,updated_at,adjustments_json,is_current) VALUES (?,?,1,?,?,'[]',?,?,?,'[]',?) ON CONFLICT(school_id,term_id) DO UPDATE SET version=version+1,semester_start_monday=excluded.semester_start_monday,week_count=excluded.week_count,timezone=excluded.timezone,note=excluded.note,updated_at=excluded.updated_at,is_current=excluded.is_current",(school_id,value["id"],value["semesterStartMonday"],value["weekCount"],value["timezone"],note,stamp,int(make_current)))
            return self.term(self.db.execute("SELECT * FROM school_terms WHERE school_id=? AND term_id=?",(school_id,value["id"])).fetchone())
    def delete_term(self, school_id, term_id):
        """Remove a term that is not the school's current one: clients only
        follow the current term, and shares keep their frozen copy."""
        with self.lock, self.db:
            row = self.db.execute("SELECT is_current FROM school_terms WHERE school_id=? AND term_id=?",
                                  (school_id, term_id)).fetchone()
            if row is None: return False
            if row["is_current"]: raise ValueError("不能删除当前学期，请先把另一个学期设为当前")
            self.db.execute("DELETE FROM school_terms WHERE school_id=? AND term_id=?", (school_id, term_id))
        return True
    def report_usage(self, installation_id, secret, value):
        if not re.fullmatch(r"[a-fA-F0-9-]{36}", installation_id):
            raise ValueError("invalid installation ID")
        if not re.fullmatch(r"[a-zA-Z0-9_-]{32,128}", secret):
            raise ValueError("invalid device secret")
        if not isinstance(value, dict) or type(value.get("consentVersion")) is not int or value["consentVersion"] != 1:
            raise ValueError("basic privacy consent version 1 required")
        allowed = {"consentVersion", "schoolID", "systemName", "systemVersion", "deviceModel", "appVersion"}
        if set(value) - allowed: raise ValueError("unexpected usage fields")
        fields = []
        for key in ("systemName", "systemVersion", "deviceModel", "appVersion"):
            field = value.get(key)
            if not isinstance(field, str) or not field.strip() or len(field) > 80 or any(ord(c) < 32 for c in field):
                raise ValueError("invalid " + key)
            fields.append(field.strip())
        school = value.get("schoolID") or ""
        if not isinstance(school, str) or len(school) > 80: raise ValueError("invalid schoolID")
        stamp = datetime.now(timezone.utc)
        with self.lock, self.db:
            existing = self.db.execute("SELECT secret_hash,last_seen FROM usage_devices WHERE installation_id=?", (installation_id,)).fetchone()
            if existing and not secrets.compare_digest(existing[0], self._digest(secret)):
                return False
            if school and not self.db.execute("SELECT 1 FROM school_configs WHERE id=?", (school,)).fetchone():
                raise ValueError("unknown schoolID")
            cutoff = (stamp - timedelta(days=90)).isoformat()
            self.db.execute("DELETE FROM usage_devices WHERE last_seen<?", (cutoff,))
            self.db.execute("DELETE FROM usage_daily WHERE day<?", (_usage_day(stamp - timedelta(days=90)),))
            # Only counts leave this block: the daily table never names a device.
            fresh = existing is None or existing["last_seen"] < cutoff
            today = _usage_day(stamp)
            if fresh or _usage_day(datetime.fromisoformat(existing["last_seen"])) < today:
                self.db.execute("INSERT INTO usage_daily VALUES (?,1,?) ON CONFLICT(day) DO UPDATE SET "
                                "active=active+1,new=new+excluded.new", (today, int(fresh)))
            self.db.execute(
                "INSERT INTO usage_devices VALUES (?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(installation_id) DO UPDATE SET school_id=excluded.school_id,system_name=excluded.system_name,"
                "system_version=excluded.system_version,device_model=excluded.device_model,app_version=excluded.app_version,"
                "consent_version=excluded.consent_version,last_seen=excluded.last_seen",
                (installation_id, self._digest(secret), school, *fields, 1, stamp.isoformat(), stamp.isoformat()))
        return True

    def usage_stats(self):
        stamp = datetime.now(timezone.utc)
        today = stamp.astimezone(USAGE_ZONE).replace(hour=0, minute=0, second=0, microsecond=0)
        with self.lock, self.db:
            self.db.execute("DELETE FROM usage_devices WHERE last_seen<?", ((stamp - timedelta(days=90)).isoformat(),))
            devices = self.db.execute("SELECT school_id,system_name,system_version,device_model,app_version,first_seen,last_seen "
                                      "FROM usage_devices WHERE last_seen>=?", ((stamp - timedelta(days=30)).isoformat(),)).fetchall()
            history = {row["day"]: row for row in self.db.execute("SELECT * FROM usage_daily WHERE day>=?",
                                                                    (_usage_day(today - timedelta(days=29)),))}
            rows = self.db.execute("SELECT id,name FROM school_configs ORDER BY name").fetchall()
        labels = {"systemVersions": lambda item: item["system_name"] + " " + item["system_version"],
                  "deviceModels": lambda item: item["device_model"], "appVersions": lambda item: item["app_version"]}
        def distribution(items, key):
            counts = {}
            for item in items:
                label = labels[key](item)
                counts[label] = counts.get(label, 0) + 1
            return [{"name": name, "users": count} for name, count in sorted(counts.items(), key=lambda entry: (-entry[1], entry[0]))]
        def seen_since(items, start, column="last_seen"):
            # Stored stamps are UTC ISO strings, so the bound must be too.
            bound = start.astimezone(timezone.utc).isoformat()
            return sum(item[column] >= bound for item in items)
        schools = []
        for row in rows:
            matching = [device for device in devices if device["school_id"] == row["id"]]
            schools.append({"id": row["id"], "name": row["name"], "users": len(matching),
                            "todayUsers": seen_since(matching, today),
                            "systemVersions": distribution(matching, "systemVersions"),
                            "deviceModels": distribution(matching, "deviceModels"),
                            "appVersions": distribution(matching, "appVersions")})
        # Today comes from the live rows so it is right even before the daily
        # table has seen a report; earlier days only survive as counts.
        daily = []
        for offset in range(29, -1, -1):
            day = _usage_day(today - timedelta(days=offset))
            saved = history.get(day)
            daily.append({"date": day, "users": saved["active"] if saved else 0, "newUsers": saved["new"] if saved else 0})
        daily[-1] = {"date": _usage_day(today), "users": seen_since(devices, today),
                     "newUsers": seen_since(devices, today, "first_seen")}
        known = {row["id"] for row in rows}
        return {"totalUsers": len(devices), "unassignedUsers": sum(device["school_id"] not in known for device in devices),
                "todayUsers": daily[-1]["users"], "newUsersToday": daily[-1]["newUsers"],
                "yesterdayUsers": daily[-2]["users"], "weeklyUsers": seen_since(devices, today - timedelta(days=6)),
                "daily": daily, "windowDays": 30, "timeZone": "UTC+8", "schools": schools,
                "systemVersions": distribution(devices, "systemVersions"),
                "deviceModels": distribution(devices, "deviceModels"),
                "appVersions": distribution(devices, "appVersions"), "updatedAt": stamp.isoformat()}
    def school_name(self, school_id):
        """The catalogue name, never the client's copy of it: a reader should
        see 南京大学 even when the sharer's app had not loaded the catalogue."""
        with self.lock:
            r=self.db.execute("SELECT name FROM school_configs WHERE id=?",(school_id,)).fetchone()
        return r["name"] if r else school_id
    def create(self, value, previous_code=None, write_token=None, publisher=""):
        """`publisher` is who asks, as `publisher_key` made it: one that is not
        a bare address may hold at most MAX_ACTIVE_SHARES shares at a time."""
        term = self.find_term(value.get("schoolID", ""), value.get("termID", ""))
        if not term: raise ValueError("unknown schoolID/termID")
        _, payload = normalize_courses(value.get("courses"))
        owner = str(value.get("owner") or "匿名").strip()[:MAX_OWNER_LENGTH] or "匿名"
        token=secrets.token_urlsafe(24); stamp=now()
        if time.time() - self.expired_at > 3600: self.expire_shares()
        with self.lock, self.db:
            code = self._new_share_code()
            if previous_code is None and publisher and not publisher.startswith("ip:"):
                held = self.db.execute("SELECT COUNT(*) FROM shares WHERE publisher=? AND revoked=0", (publisher,)).fetchone()[0]
                if held >= MAX_ACTIVE_SHARES: raise ShareQuotaError(f"最多同时保留 {MAX_ACTIVE_SHARES} 个分享码，请先撤销不用的分享")
            obsolete_codes = []
            if previous_code is not None:
                previous = self.authorize(previous_code, write_token)
                if previous is None: return None
                obsolete_codes.append(previous_code.upper())
                legacy = value.get("previousShares", [])
                if not isinstance(legacy, list) or len(legacy) > 100:
                    raise ValueError("invalid previous shares")
                for item in legacy:
                    if not isinstance(item, dict): raise ValueError("invalid previous share")
                    old_code, old_token = item.get("code"), item.get("token")
                    if not isinstance(old_code, str) or not isinstance(old_token, str):
                        raise ValueError("invalid previous share")
                    if self.authorize(old_code, old_token) is None: return None
                    obsolete_codes.append(old_code.upper())
                def content(rows):
                    # Database identities and ordering are not timetable changes.
                    ignored = {"id", "tableId", "courseKey"}
                    cleaned = []
                    for row in rows:
                        row = {k: v for k, v in row.items() if k not in ignored}
                        if isinstance(row.get("weeks"), list): row["weeks"] = sorted(set(row["weeks"]))
                        cleaned.append(json.dumps(row, ensure_ascii=False, sort_keys=True))
                    return sorted(cleaned)
                unchanged = (previous["school_id"] == value["schoolID"]
                             and previous["term_id"] == term["id"]
                             and content(json.loads(previous["payload_json"])) == content(json.loads(payload))
                             and previous["semester_start_monday"] == term["semesterStartMonday"]
                             and json.loads(previous["class_time_list_json"]) == term["periods"]
                             and json.loads(previous["adjustments_json"] or "[]") == term.get("adjustments", [])
                             and json.loads(previous["term_snapshot_json"] or "{}").get("weekCount") == term["weekCount"]
                             and json.loads(previous["term_snapshot_json"] or "{}").get("timezone") == term["timezone"])
                unchanged = unchanged and json.loads(previous["term_snapshot_json"] or "{}").get("seasonalPeriods", school_times.default_seasons(value["schoolID"])) == term.get("seasonalPeriods", [])
                if unchanged: raise ValueError("课表没有变更，请继续使用现有分享码")
            self.db.execute("INSERT INTO shares (code,write_token_hash,owner,school_id,school_name,payload_json,semester_start_monday,class_time_list_json,adjustments_json,term_id,term_version,term_snapshot_json,created_at,updated_at,revoked) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)", (code,hashlib.sha256(token.encode()).hexdigest(),owner,value["schoolID"],self.school_name(value["schoolID"]),payload,term["semesterStartMonday"],json.dumps(term["periods"],ensure_ascii=False),json.dumps(term.get("adjustments",[]),ensure_ascii=False),term["id"],term["version"],json.dumps(term,ensure_ascii=False),stamp,stamp))
            scope = previous["schedule_scope"] if previous_code is not None else secrets.token_hex(16)
            publisher = publisher or (previous["publisher"] if previous_code is not None else "")
            self.db.execute("UPDATE shares SET schedule_scope=?,publisher=?,last_read_at=? WHERE code=?", (scope, publisher, stamp, code))
            for obsolete_code in obsolete_codes:
                self.db.execute("DELETE FROM shares WHERE code=?", (obsolete_code,))
        return self.get(code, include_token=True, token=token)
    def _new_share_code(self):
        while True:
            code = "".join(secrets.choice(SHARE_CODE_ALPHABET) for _ in range(8))
            if not self.db.execute("SELECT 1 FROM shares WHERE code=?", (code,)).fetchone(): return code
    def _read(self, code):
        """The live share row, marking it read (once a day at most)."""
        with self.lock:
            r=self.db.execute("SELECT * FROM shares WHERE code=? AND revoked=0",(code.upper(),)).fetchone()
            stamp = datetime.now(timezone.utc)
            if r is not None and r["last_read_at"] < (stamp - timedelta(days=1)).isoformat():
                self.db.execute("UPDATE shares SET last_read_at=? WHERE code=?", (stamp.isoformat(), r["code"]))
                self.db.commit()
        return r
    def expire_shares(self):
        """Delete shares nobody downloaded or updated for SHARE_IDLE_DAYS, unless a
        device still follows them for Live Activity reminders. Their readers see
        them as revoked."""
        cutoff = (datetime.now(timezone.utc) - timedelta(days=SHARE_IDLE_DAYS)).isoformat()
        with self.lock, self.db:
            followed = self.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='la_timetables'").fetchone()
            keep = " AND schedule_scope NOT IN (SELECT follow_scope FROM la_timetables WHERE follow_scope!='')" if followed else ""
            gone = self.db.execute(f"DELETE FROM shares WHERE MAX(updated_at,last_read_at)<?{keep}", (cutoff,)).rowcount
        self.expired_at = time.time()
        if gone: print(f"expired {gone} idle shares")
        return gone
    def share_stats(self):
        """For the admin: how many shares exist and were made today (UTC+8)."""
        start = datetime.now(USAGE_ZONE).replace(hour=0, minute=0, second=0, microsecond=0).astimezone(timezone.utc).isoformat()
        with self.lock:
            row = self.db.execute("SELECT COUNT(*), COALESCE(SUM(LENGTH(payload_json)),0), SUM(created_at>=?), SUM(created_at>=? AND publisher LIKE 'ip:%') FROM shares",
                                  (start, start)).fetchone()
        return {"total": row[0], "payloadBytes": row[1], "createdToday": row[2] or 0, "unidentifiedToday": row[3] or 0,
                "maxActivePerPublisher": MAX_ACTIVE_SHARES, "idleDays": SHARE_IDLE_DAYS}
    def unidentified_today(self):
        return self.share_stats()["unidentifiedToday"]
    def get(self, code, include_token=False, token=None):
        if include_token:
            with self.lock: r=self.db.execute("SELECT * FROM shares WHERE code=? AND revoked=0",(code.upper(),)).fetchone()
        else: r=self._read(code)
        if not r: return None
        snapshot=json.loads(r["term_snapshot_json"] or "{}")
        courses=json.loads(r["payload_json"])
        # `name` becomes the reader's table name, so it says whose timetable
        # this is rather than repeating the school for every share.
        out={"id":r["code"],"scheduleScope":r["schedule_scope"],"timeZone":snapshot.get("timezone"),"owner":r["owner"],"schoolID":r["school_id"],"schoolName":r["school_name"],"name":f"{r['owner']} · {r['school_name']}","termID":r["term_id"],"termVersion":r["term_version"],"term_version":r["term_version"],"term_week_count":snapshot.get("weekCount",0),"term_timezone":snapshot.get("timezone","Asia/Shanghai"),"configurationFrozen":True,"courses":courses,"courseCount":len(courses),"semester_start_monday":r["semester_start_monday"],"class_time_list":json.loads(r["class_time_list_json"]),"calendar_adjustments":json.loads(r["adjustments_json"] or "[]"),"createdAt":r["created_at"],"updatedAt":r["updated_at"]}
        if include_token: out["writeToken"]=token
        out["seasonalPeriods"] = snapshot.get("seasonalPeriods", school_times.default_seasons(r["school_id"]))
        return out
    def meta(self, code):
        """Everything a follower needs to decide whether to download again."""
        r=self._read(code)
        if not r: return None
        snapshot=json.loads(r["term_snapshot_json"] or "{}")
        return {"id":r["code"],"scheduleScope":r["schedule_scope"],"timeZone":snapshot.get("timezone"),"owner":r["owner"],"schoolID":r["school_id"],"schoolName":r["school_name"],"name":f"{r['owner']} · {r['school_name']}","termID":r["term_id"],"termVersion":r["term_version"],"courseCount":len(json.loads(r["payload_json"])),"semester_start_monday":r["semester_start_monday"],"term_week_count":snapshot.get("weekCount",0),"adjustmentCount":len(json.loads(r["adjustments_json"] or "[]")),"updatedAt":r["updated_at"]}
    def authorize(self, code, token):
        """The share row when `token` is its write token, otherwise None.

        Kept apart from the callers so a bad request body can no longer be
        reported as a bad token.
        """
        with self.lock: r=self.db.execute("SELECT * FROM shares WHERE code=? AND revoked=0",(code.upper(),)).fetchone()
        if not r or not token: return None
        return r if secrets.compare_digest(r["write_token_hash"], hashlib.sha256(token.encode()).hexdigest()) else None
    def _freeze(self, code, term, payload=None):
        """Point a share at one term's configuration and copy that term's
        periods into the share. A reader installs those times as-is, which is
        what lets a timetable from another school keep its own bell schedule."""
        stamp=now()
        fields=[term["semesterStartMonday"],json.dumps(term["periods"],ensure_ascii=False),json.dumps(term.get("adjustments",[]),ensure_ascii=False),term["id"],term["version"],json.dumps(term,ensure_ascii=False),stamp]
        with self.lock, self.db:
            if payload is None:
                self.db.execute("UPDATE shares SET semester_start_monday=?,class_time_list_json=?,adjustments_json=?,term_id=?,term_version=?,term_snapshot_json=?,updated_at=? WHERE code=?",(*fields,code.upper()))
            else:
                self.db.execute("UPDATE shares SET payload_json=?,school_id=?,school_name=?,semester_start_monday=?,class_time_list_json=?,adjustments_json=?,term_id=?,term_version=?,term_snapshot_json=?,updated_at=? WHERE code=?",(payload["courses"],payload["schoolID"],self.school_name(payload["schoolID"]),*fields,code.upper()))
        return self.get(code)
    def update(self, code, token, value):
        row = self.authorize(code, token)
        if not row: return None
        # Omitting the school or the term means "keep this share where it is",
        # so a plain course edit does not have to restate them.
        school_id = str(value.get("schoolID") or row["school_id"])
        term_id = str(value.get("termID") or row["term_id"])
        term = self.find_term(school_id, term_id)
        if not term: raise ValueError("unknown schoolID/termID")
        _, payload = normalize_courses(value.get("courses"))
        return self._freeze(code, term, {"courses": payload, "schoolID": school_id})
    def resync(self, code, token):
        """Re-freeze the share against its school's current term configuration.

        A share keeps the times it was published with, so an admin correcting
        a bell schedule cannot silently move everybody's classes. This is the
        owner's way to opt into the correction.
        """
        row = self.authorize(code, token)
        if not row: return None
        term = self.find_term(row["school_id"], row["term_id"])
        if not term: raise ValueError("该分享的学校或学期已不在服务端配置中")
        return self._freeze(code, term)
    def revoke(self, code, token):
        """Delete the share. None when it no longer exists, so an owner whose
        share is already gone can drop the stale credential."""
        with self.lock, self.db:
            if self.db.execute("SELECT 1 FROM shares WHERE code=?",(code.upper(),)).fetchone() is None: return None
            if not self.authorize(code, token): return False
            self.db.execute("DELETE FROM shares WHERE code=?",(code.upper(),))
        return True
    def admin_shares(self, query=""):
        """The newest 200 shares matching `query`: a code prefix, part of the
        owner's name, or the start of the publisher's device id."""
        query = str(query or "").strip()[:MAX_OWNER_LENGTH]
        with self.lock:
            where, params = "", ()
            if query:
                pattern = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                where = "WHERE s.code LIKE ? ESCAPE '\\' OR s.owner LIKE ? ESCAPE '\\' OR s.publisher LIKE ? ESCAPE '\\'"
                params = (pattern.upper() + "%", f"%{pattern}%", f"%:{pattern.lower()}%")
            total = self.db.execute(f"SELECT COUNT(*) FROM shares s {where}", params).fetchone()[0]
            rows = self.db.execute(
                f"SELECT s.code,s.owner,s.school_id,s.school_name,s.term_id,s.payload_json,s.created_at,s.updated_at,s.publisher "
                f"FROM shares s {where} ORDER BY s.updated_at DESC LIMIT 200", params).fetchall()
        return {"total": total, "shares": [{
            "code": r["code"], "owner": r["owner"], "schoolID": r["school_id"], "schoolName": r["school_name"],
            "termID": r["term_id"], "courseCount": len(json.loads(r["payload_json"])),
            "publisher": publisher_label(r["publisher"]), "createdAt": r["created_at"], "updatedAt": r["updated_at"]} for r in rows]}
    def admin_delete_share(self, code):
        """Delete a share without its write token. Followers see it as revoked
        by its owner: they keep their copy and stop receiving updates."""
        with self.lock, self.db:
            return bool(self.db.execute("DELETE FROM shares WHERE code=?", (code.upper(),)).rowcount)

def _same_secret(supplied, secret):
    """`compare_digest` refuses non-ASCII str; bytes compare whatever was sent."""
    return secrets.compare_digest(str(supplied).encode(), str(secret).encode())


# -- HTTP ----------------------------------------------------------------------
# FastAPI picks the route; the route bodies are the chains the stdlib handler
# ran, in the same order, so every status, header and error text stays what
# the released apps and the console expect.

HTTP_METHODS = ("GET", "HEAD", "POST", "PUT", "DELETE")
# A client that stops sending mid-request must not hold its request forever.
BODY_TIMEOUT = 15
SCHOOL_ID = r"[a-zA-Z0-9][a-zA-Z0-9._-]{1,79}"

class SchoolIDConvertor(Convertor):
    regex = SCHOOL_ID
    def convert(self, value): return value
    def to_string(self, value): return value

register_url_convertor("school", SchoolIDConvertor())

class Exchange:
    """One request as the routes and `live_activity.handle` see it: headers,
    a JSON body parsed on first use, and the one response they send."""
    def __init__(self, request):
        self.store = request.app.state.store
        self.live_activity = request.app.state.live_activity
        self.entitlements = request.app.state.entitlements
        self.throttle = request.app.state.throttle
        self.attest = request.app.state.attest
        self.publishes = request.app.state.publishes
        self.peer = request.client.host if request.client else ""
        self.admin = None  # the signed-in admin's name, once `require_admin` passed
        self.headers = request.headers
        self.command = request.method
        self.target = request.scope["naptable.target"]
        self.path = urlparse(self.target).path
        self.response = None
        self._raw, self._error = b"", None
        self.extra_headers = []  # added to whatever response goes out
    async def receive(self, request):
        """Read the body before the route runs, so no worker thread waits on a
        slow client. A problem with it is raised by `body()`, where the route
        asks for it: a request refused before its body is read still is."""
        try: n = int(self.headers.get("Content-Length", 0))
        except ValueError: self._error = ValueError("invalid Content-Length"); return
        if n < 0 or n > MAX_REQUEST_BYTES:
            self._error = ValueError(f"request body exceeds {MAX_REQUEST_BYTES} bytes"); return
        if not n: return  # without a length there is no body, chunked or not
        chunks = []
        stream = request.stream()
        try:
            while True:
                with anyio.fail_after(BODY_TIMEOUT): chunk = await anext(stream, None)
                if chunk is None: break
                chunks.append(chunk)
        except Exception as error: self._error = error; return
        self._raw = b"".join(chunks)
    def body(self):
        """The request body, which every route expects to be a JSON object."""
        if self._error is not None: raise self._error
        try: value = json.loads(self._raw or b"{}")
        except UnicodeDecodeError: raise ValueError("request body must be UTF-8 JSON")
        if not isinstance(value, dict): raise ValueError("request body must be a JSON object")
        return value
    def send(self, status, data, content_type, headers=()):
        if self.response is not None: return  # the first answer is the one the client got
        self.response = _response(status, data, [("Content-Type", content_type), ("Content-Length", str(len(data))), *headers, *self.extra_headers])
    def send_json(self, status, value, headers=()):
        self.send(status, json.dumps(value,ensure_ascii=False).encode(), "application/json; charset=utf-8", headers)
    def client_address(self):
        """Who is asking, for the sign-in throttle: nginx on this host appends
        the real address to X-Forwarded-For; anyone else is taken as seen."""
        forwarded = self.headers.get("X-Forwarded-For", "")
        if forwarded and self.peer in ("127.0.0.1", "::1"):
            return forwarded.rsplit(",", 1)[-1].strip() or self.peer
        return self.peer
    def refuse_throttled(self):
        """Answer 429 when this client has used up its wrong tokens."""
        wait = self.throttle.retry_after(self.client_address())
        if wait: self.send_json(429, {"error": "too many failed sign-ins, try again later"}, [("Retry-After", str(wait))])
        return bool(wait)
    def audit(self, action, target="", detail=None):
        self.store.audit(self.admin, action, target, detail)
    def attested(self, endpoint):
        """Check this write's App Attest assertion. Returns (key id or None,
        answered): answered means a refusal went out, for a forged assertion
        (401) or an unattested writer over its address's hourly limit (429).
        Unattested writes are otherwise let through: a simulator cannot sign."""
        if self.attest is None: return None, False
        key, refuse, outcome = self.attest.check(self.headers, self.command, self.path, self._raw, endpoint)
        # A key we lost (the database was reset): the app attests a new one.
        if outcome == "unknownKey": self.extra_headers.append(("X-App-Attest-Status", "unknownKey"))
        if refuse:
            self.send_json(401, {"error": "invalid app attest assertion"}, [("X-App-Attest-Status", "invalid")])
            return None, True
        limit = UNATTESTED_PER_HOUR.get(endpoint)
        if key is None and limit:
            wait = self.publishes.retry_after(f"unattested:{endpoint}:{self.client_address()}", limit)
            if wait:
                self.send_json(429, {"error": "请求太频繁，请稍后再试"}, [("Retry-After", str(wait))])
                return None, True
        return key, False
    def cookie(self, name):
        jar = SimpleCookie()
        try: jar.load(self.headers.get("Cookie", ""))
        except CookieError: return ""
        found = jar.get(name)
        return found.value if found else ""
    def same_origin(self):
        """The session cookie is only honoured on same-origin requests, so a
        third-party page cannot ride a signed-in admin's session."""
        site = self.headers.get("Sec-Fetch-Site")
        if site: return site in ("same-origin", "none")
        origin = self.headers.get("Origin")
        if not origin: return True  # not a browser request
        return urlparse(origin).netloc == self.headers.get("Host", "")
    def require_admin(self):
        tokens = admin_tokens()
        if not tokens: return False
        supplied = self.headers.get("X-Admin-Token")
        if supplied is not None:
            # A header is a sign-in on every request: it shares the form's throttle.
            client = self.client_address()
            if self.refuse_throttled(): return False
            self.admin = token_owner(supplied, tokens)
            if self.admin is None: self.throttle.fail(client)
        elif self.same_origin():
            self.admin = self.store.admin_session_valid(self.cookie(ADMIN_COOKIE), tokens)
        return self.admin is not None
    def session_cookie(self, value, max_age):
        parts = [f"{ADMIN_COOKIE}={value}", "Path=/", "HttpOnly", "SameSite=Strict", f"Max-Age={max_age}"]
        if self.headers.get("X-Forwarded-Proto", "").lower() == "https": parts.append("Secure")
        return "; ".join(parts)
    def send_file(self, path, content_type, cache="no-store"):
        try: data = path.read_bytes()
        except OSError: return self.send_json(404, {"error": "not found"})
        self.send(200, data, content_type, [("Cache-Control", cache)])
    def versioned(self):
        """Console assets are cached only when admin.html asks for them by
        version (`?v=`), so a deploy is picked up on the next page load."""
        return "public, max-age=86400" if "v" in parse_qs(urlparse(self.target).query) else "no-store"
    def apns_status(self):
        value = self.store.apns_config() or {"keyPath": "", "keyID": "", "teamID": "", "bundleID": "", "tickSeconds": 5, "channels": {}}
        if self.live_activity is not None and hasattr(self.live_activity, "v2"):
            value["liveActivityHealth"] = self.live_activity.v2.health()
        return value
    def fail(self, status, message):
        # A store write that failed half way must not leave its transaction open.
        store = self.store
        if store is not None:
            with store.lock:
                try:
                    if store.db.in_transaction: store.db.rollback()
                except sqlite3.Error: pass
        self.send_json(status, {"error": message})

def _dispatch(x, route):
    """Every route's outermost frame: a request never goes without an answer,
    whatever the route raised."""
    try: route(x)
    except (ValueError, KeyError, TypeError, live_activity.apns.APNsError) as error:
        x.fail(400, str(error))
    except Exception as error:
        print(f"request failed: {x.command} {x.target}: {type(error).__name__}: {error}")
        x.fail(500, "internal error")

ROUTES = []
def route(methods, *paths):
    """Register a route body for `create_app`. Order is precedence: the first
    route whose path and method match answers."""
    def register(body):
        for path in paths: ROUTES.append((methods.split(), path, body))
        return body
    return register

def admin_only(x):
    if x.require_admin(): return False
    # A throttled header already has its 429; `send_json` keeps the first answer.
    x.send_json(403, {"error": "admin token required"}); return True

# Live Activity answers first, as `live_activity.handle` always did; with no
# service, or a path it does not own, the request is simply not found.
@route("GET HEAD POST PUT DELETE", "/v1/live-activity{rest:path}", "/v2/live-activity{rest:path}")
def live_activity_route(x):
    # HEAD is GET without the body.
    method = "GET" if x.command == "HEAD" else x.command
    # The writes that add a device or a timetable to plan for.
    if method == "POST" and x.path == "/v2/live-activity/devices":
        if x.attested("liveActivity.register")[1]: return
    elif method == "PUT" and x.path.startswith("/v2/live-activity/devices/") and x.path.endswith("/timetable"):
        if x.attested("liveActivity.timetable")[1]: return
    if not live_activity.handle(x, x.live_activity, method, x.path): x.send_json(404, {"error": "not found"})

@route("GET HEAD", "/")
def site_index(x): x.send_file(SITE_ROOT / "index.html", "text/html; charset=utf-8")

@route("GET HEAD", "/privacy", "/privacy/")
def site_privacy(x): x.send_file(SITE_ROOT / "privacy.html", "text/html; charset=utf-8")

@route("GET HEAD", "/site/{name:path}")
def site_asset(x):
    name = x.path[len("/site/"):]
    if name not in SITE_ASSETS: return x.send_json(404, {"error": "not found"})
    x.send_file(SITE_ROOT / name, SITE_ASSETS[name], "public, max-age=86400")

@route("GET HEAD", "/admin", "/admin/")
def admin_page(x):
    try:
        page = (STATIC_ROOT / "admin.html").read_text(encoding="utf-8")
        css_hash = hashlib.sha256((STATIC_ROOT / "admin.css").read_bytes()).hexdigest()[:16]
        js_hash = hashlib.sha256((STATIC_ROOT / "admin.js").read_bytes()).hexdigest()[:16]
    except OSError:
        return x.send_json(404, {"error": "not found"})
    page = page.replace("__ADMIN_CSS_HASH__", css_hash).replace("__ADMIN_JS_HASH__", js_hash)
    x.send(200, page.encode("utf-8"), "text/html; charset=utf-8", [("Cache-Control", "no-store")])

@route("GET HEAD", "/static/admin.css")
def admin_css(x): x.send_file(STATIC_ROOT / "admin.css", "text/css; charset=utf-8", x.versioned())

@route("GET HEAD", "/static/admin.js")
def admin_js(x): x.send_file(STATIC_ROOT / "admin.js", "application/javascript; charset=utf-8", x.versioned())

@route("GET HEAD", "/health")
def health(x): x.send_json(200,{"ok":True})

@route("GET HEAD", "/v1/admin/session")
def admin_session(x):
    if admin_only(x): return
    x.send_json(200, {"authenticated": True, "admin": x.admin})

@route("GET HEAD", "/v1/admin/apns")
def admin_apns(x):
    if admin_only(x): return
    x.send_json(200, x.apns_status())

@route("GET HEAD", "/v1/admin/calendar")
def admin_calendar(x):
    if admin_only(x): return
    x.send_json(200, x.store.global_calendar())

@route("GET HEAD", "/v1/admin/stats")
def admin_stats(x):
    if admin_only(x): return
    x.send_json(200, x.store.usage_stats())

@route("GET HEAD", "/v1/admin/audit")
def admin_audit(x):
    if admin_only(x): return
    x.send_json(200, x.store.audit_log(parse_qs(urlparse(x.target).query).get("action", [""])[0][:40]))

@route("GET HEAD", "/v1/admin/shares")
def admin_shares(x):
    if admin_only(x): return
    x.send_json(200, x.store.admin_shares(parse_qs(urlparse(x.target).query).get("q", [""])[0]))

@route("GET HEAD", "/v1/schools")
def schools(x): x.send_json(200,{"schools":x.store.schools()})

# The unified holiday arrangement on its own, for tables not bound to a
# school term. Kept out of /v1/schools: released clients decode that
# body as a plain {"schools": [...]} map and would reject a new key.
@route("GET HEAD", "/v1/calendar")
def calendar(x): x.send_json(200, x.store.global_calendar())

@route("GET HEAD", "/v1/shares/{rest:path}")
def share(x):
    parts=[p for p in x.path[len("/v1/shares/"):].split("/") if p]
    if len(parts)==1: value=x.store.get(parts[0])
    elif parts[1:]==["meta"]: value=x.store.meta(parts[0])
    else: return x.send_json(404,{"error":"not found"})
    if not value: return x.send_json(404,{"error":"share not found"})
    x.send_json(200,value)

@route("POST", "/v1/usage/devices/{installation:path}")
def report_usage(x):
    if x.attested("usage.report")[1]: return
    accepted = x.store.report_usage(x.path.removeprefix("/v1/usage/devices/"),
                                    x.headers.get("X-Device-Secret", ""), x.body())
    x.send_json(200, {"accepted": True}) if accepted else x.send_json(403, {"error": "invalid device secret"})

@route("POST", "/v1/admin/session")
def sign_in(x):
    if x.refuse_throttled(): return
    tokens = admin_tokens()
    supplied = str(x.body().get("token", ""))
    x.admin = token_owner(supplied, tokens)
    if x.admin is None:
        client = x.client_address()
        x.throttle.fail(client)
        if tokens: x.audit("session.failed", client)
        return x.send_json(403, {"error": "admin token required"})
    cookie = x.session_cookie(x.store.create_admin_session(tokens[x.admin]), int(ADMIN_SESSION_TTL.total_seconds()))
    x.audit("session.signIn", x.client_address())
    x.send_json(200, {"authenticated": True, "admin": x.admin}, [("Set-Cookie", cookie)])

@route("POST", "/v1/admin/apns")
def save_apns(x):
    if admin_only(x): return
    candidate = x.body()
    # Moving to another app gives up the devices of the old one: only on
    # the admin's explicit confirmation, after a 409 listing what is dropped.
    retire = candidate.pop("retireOtherBundles", False) is True
    # Parse the key before writing, so a typo cannot replace a
    # working configuration with one that the dispatcher cannot use.
    # The client checked here is the one the dispatcher then uses.
    client = live_activity._client_from_config(candidate)
    v2 = getattr(x.live_activity, "v2", None) if x.live_activity is not None else None
    retiring = False
    try:
        if v2 is not None:
            try: v2.validate_client(client)
            except ProtocolError as error:
                if error.status != 409: raise
                if not retire:
                    client.close()
                    return x.send_json(409, {"error": str(error), "retire": v2.retired_impact(client.bundle_id)})
                retiring = True
        value = x.store.save_apns_config(candidate)
        if retiring: v2.retire_bundles(client)
        x.audit("apns.save", value["bundleID"], {"keyID": value["keyID"], "teamID": value["teamID"],
                                                  "tickSeconds": value["tickSeconds"], "retiredOtherBundles": retiring})
    except BaseException:
        if client is not None: client.close()
        raise
    if x.live_activity is not None:
        live_activity.apply_config(x.live_activity, value, client=client)
    elif client is not None: client.close()
    x.send_json(200, x.apns_status())

@route("POST", "/v1/admin/calendar")
def save_calendar(x):
    if admin_only(x): return
    saved = x.store.save_global_calendar(x.body())
    x.audit("calendar.save", f"v{saved['version']}", {"adjustments": len(saved["adjustments"])})
    x.send_json(200, saved)

@route("POST", "/v1/admin/calendar/import")
def import_calendar(x):
    if admin_only(x): return
    x.send_json(200, x.store.import_calendar(x.body()))

@route("POST", "/v1/admin/schools/{school_id:school}/rename")
def rename_school(x):
    if admin_only(x): return
    new_id = x.body().get("id")
    old_id = x.path.split("/")[4]
    saved = x.store.rename_school(old_id, new_id)
    if not saved: return x.send_json(404, {"error": "school not found"})
    if saved["id"] != old_id: x.audit("school.rename", saved["id"], {"from": old_id})
    if x.live_activity is not None:
        config = x.store.apns_config()
        x.live_activity.channels = live_activity._channels_from_value(config.get("channels", {}) if config else {})
    x.send_json(200, saved)


def publisher_key(x, key):
    """Who publishes, for quotas and the admin: the device's App Attest key,
    else its address (a simulator, an old app); hashed, so the table keeps
    neither."""
    kind, value = ("device", key) if key else ("ip", x.client_address())
    return f"{kind}:{hashlib.sha256(value.encode()).hexdigest()[:32]}"

def publish(x, previous_code=None):
    """Create or replace a share within the quotas."""
    key, refused = x.attested("share.publish")
    if refused: return
    who = publisher_key(x, key)
    anonymous = who.startswith("ip:")
    wait = x.publishes.retry_after(who, PUBLISH_PER_HOUR_BY_ADDRESS if anonymous else PUBLISH_PER_HOUR)
    if wait: return x.send_json(429, {"error": "发布太频繁，请稍后再试"}, [("Retry-After", str(wait))])
    if anonymous and previous_code is None and x.store.unidentified_today() >= UNIDENTIFIED_SHARES_PER_DAY:
        return x.send_json(429, {"error": "今天的分享已达上限，请更新到最新版 App 或明天再试"})
    try:
        value = x.store.create(x.body(), previous_code=previous_code, write_token=x.headers.get("X-Write-Token", ""), publisher=who)
    except ShareQuotaError as error: return x.send_json(429, {"error": str(error)})
    x.send_json(201, value) if value else x.send_json(403, {"error": "invalid write token"})

@route("POST", "/v1/shares")
def create_share(x): publish(x)

@route("POST", "/v1/shares/{rest:path}")
def share_action(x):
    path = x.path
    if path.endswith("/replace"):
        return publish(x, previous_code=path[len("/v1/shares/"):-len("/replace")])
    if path.endswith("/resync"):
        code=path[len("/v1/shares/"):-len("/resync")]
        value=x.store.resync(code,x.headers.get("X-Write-Token",""))
        return x.send_json(200,value) if value else x.send_json(403,{"error":"invalid write token"})
    x.send_json(404,{"error":"not found"})

# Every write to the catalogue lives under /v1/admin, so the edge can guard
# that one prefix; /v1/schools itself is only read.
@route("POST", "/v1/admin/schools/{school_id:school}")
def save_school(x):
    if admin_only(x): return
    value=x.body(); value["id"]=x.path.rsplit("/",1)[-1]
    # A contract with admin.js: `"create": true` adds a school and
    # never overwrites one that already has this id.
    create = value.pop("create", False) is True
    try: saved = x.store.save_school(value, create=create)
    except SchoolExists: return x.send_json(409, {"error": "school exists"})
    x.audit("school.create" if create else "school.save", saved["id"], {"name": saved["name"], "periods": len(saved["periods"])})
    x.send_json(200, saved)

@route("POST", "/v1/admin/schools/{school_id:school}/terms")
def save_term(x):
    if admin_only(x): return
    school_id = x.path.split("/")[4]
    saved = x.store.save_term(school_id, x.body())
    x.audit("term.save", f"{school_id}/{saved['id']}", {"version": saved["version"], "current": saved["current"],
                                                        "semesterStartMonday": saved["semesterStartMonday"], "weekCount": saved["weekCount"]})
    x.send_json(200, saved)

@route("PUT", "/v1/shares/{rest:path}")
def update_share(x):
    if x.attested("share.update")[1]: return
    value=x.store.update(x.path.rsplit("/",1)[-1],x.headers.get("X-Write-Token",""),x.body())
    x.send_json(200,value) if value else x.send_json(403,{"error":"invalid write token"})

@route("DELETE", "/v1/admin/session")
def sign_out(x):
    if x.require_admin(): x.audit("session.signOut")
    x.store.delete_admin_session(x.cookie(ADMIN_COOKIE))
    x.send_json(200, {"authenticated": False}, [("Set-Cookie", x.session_cookie("", 0))])

@route("DELETE", "/v1/admin/schools/{school_id:school}")
def delete_school(x):
    if admin_only(x): return
    school_id = x.path.rsplit("/", 1)[-1]
    if not x.store.delete_school(school_id):
        return x.send_json(404, {"error": "school not found"})
    x.audit("school.delete", school_id)
    x.send_json(200, {"deleted": True})

@route("DELETE", "/v1/admin/schools/{school_id:school}/terms/{term_id:school}")
def delete_term(x):
    if admin_only(x): return
    parts = x.path.split("/")
    if not x.store.delete_term(parts[4], parts[6]):
        return x.send_json(404, {"error": "term not found"})
    x.audit("term.delete", f"{parts[4]}/{parts[6]}")
    x.send_json(200, {"deleted": True})

@route("DELETE", "/v1/admin/shares/{code}")
def admin_delete_share(x):
    if admin_only(x): return
    code = x.path.rsplit("/", 1)[-1].upper()
    share = x.store.meta(code)
    if not x.store.admin_delete_share(code):
        return x.send_json(404, {"error": "share not found"})
    x.audit("share.delete", code, {"owner": share["owner"], "schoolID": share["schoolID"]} if share else {})
    x.send_json(200, {"deleted": True})

@route("DELETE", "/v1/shares/{rest:path}")
def revoke_share(x):
    revoked=x.store.revoke(x.path.rsplit("/",1)[-1],x.headers.get("X-Write-Token",""))
    if revoked is None: return x.send_json(404,{"error":"share not found"})
    x.send_json(200,{"revoked":True}) if revoked else x.send_json(403,{"error":"invalid write token"})

# MARK: Live Activity entitlements
#
# Entitlements are per device after a verified StoreKit transaction; the admin
# controls whether reminders require a trial or lifetime purchase.

@route("GET HEAD", "/v1/entitlements/settings")
def public_entitlement_settings(x):
    # Available before optional notification consent or device registration.
    settings = x.entitlements.settings() if x.entitlements is not None else entitlements.SETTINGS
    x.send_json(200, settings, [("Cache-Control", "no-store")])

@route("GET HEAD", "/v1/admin/entitlements")
def admin_entitlements(x):
    if admin_only(x): return
    if x.entitlements is None: return x.send_json(404, {"error": "not found"})
    x.send_json(200, x.entitlements.admin_summary())

@route("POST", "/v1/admin/entitlements/settings")
def admin_entitlement_settings(x):
    if admin_only(x): return
    if x.entitlements is None: return x.send_json(404, {"error": "not found"})
    value = x.body()
    try: saved = x.entitlements.save_settings(value)
    except entitlements.EntitlementError as error: return x.send_json(400, {"error": str(error)})
    x.audit("entitlement.settings", "", value)
    x.send_json(200, saved)

@route("POST", "/v1/app-attest/challenge")
def attest_challenge(x):
    if x.attest is None: return x.send_json(404, {"error": "not found"})
    x.send_json(200, x.attest.challenge())

@route("POST", "/v1/app-attest/keys")
def attest_key(x):
    if x.attest is None: return x.send_json(404, {"error": "not found"})
    try: x.send_json(200, x.attest.register(x.body()))
    except app_attest.AttestError as error: x.send_json(400, {"error": str(error)})

@route("GET HEAD", "/v1/admin/abuse")
def admin_abuse(x):
    if admin_only(x): return
    x.send_json(200, {"shares": x.store.share_stats(), "appAttest": x.attest.summary() if x.attest is not None else None})

@route("GET HEAD POST PUT DELETE", "/{rest:path}")
def not_found(x): x.send_json(404,{"error":"not found"})

async def _exchange(request: Request):
    x = Exchange(request)
    await x.receive(request)
    return x

def _endpoint(body):
    # Plain `def`: FastAPI runs it on its thread pool, so the store's lock
    # and SQLite never block the event loop.
    def endpoint(x: Exchange = Depends(_exchange)):
        _dispatch(x, body)
        return x.response
    endpoint.__name__ = body.__name__
    return endpoint

class RequestTarget:
    """Route on the request target as it was sent, as `BaseHTTPRequestHandler`
    did: undecoded, so `%2F` inside a code is no separator, and with a leading
    `//` collapsed. A method it had no `do_*` for keeps its 501 page."""
    def __init__(self, app): self.app = app
    async def __call__(self, scope, receive, send):
        if scope["type"] != "http": return await self.app(scope, receive, send)
        raw = scope.get("raw_path") or scope["path"].encode()
        query = scope.get("query_string") or b""
        target = (raw + b"?" + query if query else raw).decode("latin-1")
        if target.startswith("//"): target = "/" + target.lstrip("/")
        if scope["method"] not in HTTP_METHODS: return await _unsupported(scope["method"])(scope, receive, send)
        path = urlparse(target).path
        if not path.startswith("/"):  # `*`, or an absolute URI without a path
            data = b'{"error": "not found"}'
            return await _response(404, data, [("Content-Type", "application/json; charset=utf-8"), ("Content-Length", str(len(data)))])(scope, receive, send)
        await self.app(dict(scope, path=path, root_path="", **{"naptable.target": target}), receive, send)

def _unsupported(method):
    message = "Unsupported method (%r)" % method
    page = DEFAULT_ERROR_MESSAGE % {"code": 501, "message": html.escape(message, quote=False),
                                    "explain": html.escape(BaseHTTPRequestHandler.responses[501][1], quote=False)}
    data = page.encode("UTF-8", "replace")
    return _response(501, data, [("Connection", "close"), ("Content-Type", DEFAULT_ERROR_CONTENT_TYPE), ("Content-Length", str(len(data)))])

def _response(status, data, headers):
    """A response with exactly these headers, in this order and casing, after
    the Date line, as the stdlib server wrote them."""
    response = Response(data, status)
    response.raw_headers = [(b"Date", formatdate(usegmt=True).encode())] + [
        (name.encode("latin-1"), value.encode("latin-1")) for name, value in headers]
    return response

def wire_entitlements(store, service=None):
    """Entitlements over `store`, gating the Live Activity `service`: a device
    that becomes entitled (or the switch turning off) queues its pending
    reminders again."""
    v2 = getattr(service, "v2", None)
    if store is None: return None
    bundle_id = getattr(getattr(service, "v2", None), "client", None)
    bundle_id = getattr(bundle_id, "bundle_id", None)
    found = entitlements.Entitlements(store.db, store.lock, bundle_id=bundle_id)
    if v2 is not None:
        found.now = v2.now
        v2.entitlement, found.on_change = found, v2.requeue
    return found

def wire_attest(store):
    """App Attest over `store`, for the App ID the APNs settings name."""
    if store is None: return None
    def app_id():
        settings = store.apns_config() or {}
        team, bundle = settings.get("teamID", ""), settings.get("bundleID", "")
        return f"{team}.{bundle}" if team and bundle else ""
    return app_attest.AppAttest(store.db, store.lock, app_id=app_id)

def create_app(store, service=None, workers=True, entitlement_store=None, attest_store=None):
    """The HTTP app over `store` and the Live Activity `service`. With
    `workers`, the service's dispatch threads run for the app's lifetime."""
    @asynccontextmanager
    async def lifespan(app):
        if workers and service is not None: service.start()
        try: yield
        finally:
            if workers and service is not None: await anyio.to_thread.run_sync(service.stop)
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, redirect_slashes=False, lifespan=lifespan)
    app.state.store, app.state.live_activity = store, service
    app.state.throttle = LoginThrottle()
    app.state.entitlements = entitlement_store if entitlement_store is not None else wire_entitlements(store, service)
    app.state.attest = attest_store if attest_store is not None else wire_attest(store)
    app.state.publishes = PublishLimiter()
    for methods, path, body in ROUTES:
        app.add_api_route(path, _endpoint(body), methods=methods, include_in_schema=False)
    app.add_middleware(RequestTarget)
    return app

def server_config(app, **options):
    """uvicorn as `main` runs it; the tests serve through the same settings.
    nginx in front sets X-Forwarded-Proto, which the cookie code reads itself,
    so uvicorn leaves the proxy headers alone."""
    return uvicorn.Config(app, http="h11", ws="none", lifespan="on", access_log=False, server_header=False,
                          proxy_headers=False, date_header=False, log_level="warning", timeout_graceful_shutdown=10, **options)

def main():
    p=argparse.ArgumentParser(); p.add_argument("--host",default="127.0.0.1"); p.add_argument("--port",type=int,default=8787); p.add_argument("--db",default="naptable.sqlite3"); a=p.parse_args()
    store=Store(a.db)
    service=live_activity.build_service(store.db, store.lock, config=store.apns_config())
    configured = "已配置" if service.client else "未配置（只接受注册与计划，不发推送）"
    print(f"NapTable server listening on http://{a.host}:{a.port}")
    print(f"实况通知推送：APNs {configured}")
    # Exactly one process: the Live Activity schedule lives in this process's
    # memory, and a lock on the database refuses a second scheduler.
    uvicorn.Server(server_config(create_app(store, service), host=a.host, port=a.port)).run()
if __name__ == "__main__": main()

#!/usr/bin/env python3
"""Small persistent NapTable sharing/configuration server.

FastAPI on uvicorn, in one process. Intended for a LAN or private deployment;
put it behind TLS/authentication at the edge for a public deployment.
"""
from __future__ import annotations
import argparse, hashlib, html, json, os, secrets, sqlite3, threading, re
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
    from . import holidays, live_activity
except ImportError:  # pragma: no cover - depends on how the server was started
    import holidays, live_activity

STATIC_ROOT = Path(__file__).resolve().parent / "static"
SITE_ROOT = STATIC_ROOT / "site"
# The public website: a fixed list, so no request path ever reaches the filesystem.
SITE_ASSETS = {"site.css": "text/css; charset=utf-8", "img/icon.png": "image/png", "img/favicon.png": "image/png",
               **{f"img/{name}.jpg": "image/jpeg" for name in ("week-view", "month-view", "onboarding-import",
                                                                 "device-settings", "today-widget", "two-day-widget")}}
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
 periods_json TEXT NOT NULL, note TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS school_terms (
 school_id TEXT NOT NULL, term_id TEXT NOT NULL, version INTEGER NOT NULL,
 semester_start_monday TEXT NOT NULL, week_count INTEGER NOT NULL,
 periods_json TEXT NOT NULL, timezone TEXT NOT NULL, note TEXT NOT NULL,
 updated_at TEXT NOT NULL, adjustments_json TEXT NOT NULL DEFAULT '[]',
 is_current INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY (school_id, term_id)
);
CREATE TABLE IF NOT EXISTS global_calendar (
 id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL DEFAULT 1,
 adjustments_json TEXT NOT NULL DEFAULT '[]', updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS admin_sessions (
 token_hash TEXT PRIMARY KEY, secret_hash TEXT NOT NULL,
 created_at TEXT NOT NULL, expires_at TEXT NOT NULL
);
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
# so rotating NAPTABLE_ADMIN_TOKEN signs every console out.
ADMIN_COOKIE = "naptable_admin"
ADMIN_SESSION_TTL = timedelta(hours=12)

# A share is handed back in one response and installed as one table, so the
# payload is bounded here rather than left to whatever a client uploads.
MAX_COURSES = 600
MAX_COURSE_BYTES = 256 * 1024
MAX_OWNER_LENGTH = 40
MAX_REQUEST_BYTES = 1024 * 1024

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
            # Revoking or replacing a share used to only flag the row.
            self.db.execute("DELETE FROM shares WHERE revoked!=0")
            self.db.commit(); self.seed(); self._migrate_configuration_model()
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
    def admin_session_valid(self, raw, secret, ttl=ADMIN_SESSION_TTL):
        """Accept a console session cookie, sliding its expiry so an admin who
        keeps working is not signed out mid-edit."""
        if not raw or not secret: return False
        digest = self._digest(raw)
        stamp = datetime.now(timezone.utc)
        with self.lock, self.db:
            row = self.db.execute("SELECT secret_hash,expires_at FROM admin_sessions WHERE token_hash=?", (digest,)).fetchone()
            if not row: return False
            if row["expires_at"] <= stamp.isoformat() or not secrets.compare_digest(row["secret_hash"], self._digest(secret)):
                self.db.execute("DELETE FROM admin_sessions WHERE token_hash=?", (digest,))
                return False
            self.db.execute("UPDATE admin_sessions SET expires_at=? WHERE token_hash=?", ((stamp + ttl).isoformat(), digest))
        return True
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
    def save_apns_channels(self, channels):
        config = self.apns_config()
        if not config: return None
        with self.lock, self.db:
            self.db.execute("UPDATE apns_config SET channels_json=?,updated_at=? WHERE id=1",
                            (json.dumps(channels, ensure_ascii=False), now()))
        return self.apns_config()
    def reconcile_apns_channels(self, client):
        config = self.apns_config()
        if not config or client is None: return {"created": [], "errors": [], "config": config}
        channels = dict(config.get("channels", {}))
        created, errors = [], []
        school_ids = [row[0] for row in self.db.execute("SELECT id FROM school_configs ORDER BY id")]
        for environment in ("production", "sandbox"):
            try:
                remote_channels = set(client.list_channels(environment=environment))
            except Exception as error:
                errors.append({"key": f"{environment}:*", "error": str(error)})
                continue
            for school_id in school_ids:
                key = f"{environment}:{school_id}"
                if channels.get(key) in remote_channels: continue
                try:
                    channel_id = client.create_channel(environment=environment)
                    channels[key] = channel_id
                    remote_channels.add(channel_id)
                    self.save_apns_channels(channels)
                    created.append(key)
                except Exception as error:
                    errors.append({"key": key, "error": str(error)})
        return {"created": created, "errors": errors, "config": self.apns_config()}
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
            self.db.execute("INSERT INTO school_configs VALUES (?,?,?,?,?,?)", ("nju","南京大学","",json.dumps(periods,ensure_ascii=False),"模板时间，需按校历校准",now()))
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
        return {"id":r["id"],"name":r["name"],"timezone":"Asia/Shanghai","periods":periods,
                "currentTermID":current,"terms":[self.term(t, periods) for t in terms],
                "note":r["note"],"updatedAt":r["updated_at"]}
    def term(self, r, periods=None):
        if periods is None:
            school = self.db.execute("SELECT periods_json FROM school_configs WHERE id=?", (r["school_id"],)).fetchone()
            periods = json.loads(school[0] or "[]") if school else []
        return {"id":r["term_id"],"version":r["version"],"semesterStartMonday":r["semester_start_monday"],
                "weekCount":r["week_count"],"periods":periods,"adjustments":self.global_calendar()["adjustments"],
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
        periods = normalize_periods(value.get("periods"))
        stamp=now()
        with self.lock, self.db:
            existing = self.db.execute("SELECT periods_json FROM school_configs WHERE id=?", (value["id"],)).fetchone()
            if create and existing is not None: raise SchoolExists(value["id"])
            encoded_periods = json.dumps(periods, ensure_ascii=False)
            periods_changed = existing is None or json.loads(existing["periods_json"] or "[]") != periods
            self.db.execute("INSERT INTO school_configs VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,semester_start=excluded.semester_start,periods_json=excluded.periods_json,note=excluded.note,updated_at=excluded.updated_at", (value["id"],name,semester_start,encoded_periods,note,stamp))
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
    def create(self, value, previous_code=None, write_token=None):
        term = self.find_term(value.get("schoolID", ""), value.get("termID", ""))
        if not term: raise ValueError("unknown schoolID/termID")
        _, payload = normalize_courses(value.get("courses"))
        owner = str(value.get("owner") or "匿名").strip()[:MAX_OWNER_LENGTH] or "匿名"
        code=secrets.token_urlsafe(6).replace("-", "").replace("_", "").upper()[:8]
        token=secrets.token_urlsafe(24); stamp=now()
        with self.lock, self.db:
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
                if unchanged: raise ValueError("课表没有变更，请继续使用现有分享码")
            self.db.execute("INSERT INTO shares (code,write_token_hash,owner,school_id,school_name,payload_json,semester_start_monday,class_time_list_json,adjustments_json,term_id,term_version,term_snapshot_json,created_at,updated_at,revoked) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)", (code,hashlib.sha256(token.encode()).hexdigest(),owner,value["schoolID"],self.school_name(value["schoolID"]),payload,term["semesterStartMonday"],json.dumps(term["periods"],ensure_ascii=False),json.dumps(term.get("adjustments",[]),ensure_ascii=False),term["id"],term["version"],json.dumps(term,ensure_ascii=False),stamp,stamp))
            scope = previous["schedule_scope"] if previous_code is not None else secrets.token_hex(16)
            self.db.execute("UPDATE shares SET schedule_scope=? WHERE code=?", (scope, code))
            for obsolete_code in obsolete_codes:
                self.db.execute("DELETE FROM shares WHERE code=?", (obsolete_code,))
        return self.get(code, include_token=True, token=token)
    def get(self, code, include_token=False, token=None):
        with self.lock: r=self.db.execute("SELECT * FROM shares WHERE code=? AND revoked=0",(code.upper(),)).fetchone()
        if not r: return None
        snapshot=json.loads(r["term_snapshot_json"] or "{}")
        courses=json.loads(r["payload_json"])
        # `name` becomes the reader's table name, so it says whose timetable
        # this is rather than repeating the school for every share.
        out={"id":r["code"],"scheduleScope":r["schedule_scope"],"timeZone":snapshot.get("timezone"),"owner":r["owner"],"schoolID":r["school_id"],"schoolName":r["school_name"],"name":f"{r['owner']} · {r['school_name']}","termID":r["term_id"],"termVersion":r["term_version"],"term_version":r["term_version"],"term_week_count":snapshot.get("weekCount",0),"term_timezone":snapshot.get("timezone","Asia/Shanghai"),"configurationFrozen":True,"courses":courses,"courseCount":len(courses),"semester_start_monday":r["semester_start_monday"],"class_time_list":json.loads(r["class_time_list_json"]),"calendar_adjustments":json.loads(r["adjustments_json"] or "[]"),"createdAt":r["created_at"],"updatedAt":r["updated_at"]}
        if include_token: out["writeToken"]=token
        return out
    def meta(self, code):
        """Everything a follower needs to decide whether to download again."""
        with self.lock: r=self.db.execute("SELECT * FROM shares WHERE code=? AND revoked=0",(code.upper(),)).fetchone()
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
        self.headers = request.headers
        self.command = request.method
        self.target = request.scope["naptable.target"]
        self.path = urlparse(self.target).path
        self.response = None
        self._raw, self._error = b"", None
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
        self.response = _response(status, data, [("Content-Type", content_type), ("Content-Length", str(len(data))), *headers])
    def send_json(self, status, value, headers=()):
        self.send(status, json.dumps(value,ensure_ascii=False).encode(), "application/json; charset=utf-8", headers)
    def admin_secret(self): return os.environ.get("NAPTABLE_ADMIN_TOKEN", "").strip()
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
        secret = self.admin_secret()
        if not secret: return False
        if _same_secret(self.headers.get("X-Admin-Token", ""), secret): return True
        return self.same_origin() and self.store.admin_session_valid(self.cookie(ADMIN_COOKIE), secret)
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
    x.send_json(403, {"error": "admin token required"}); return True

# Live Activity answers first, as `live_activity.handle` always did; with no
# service, or a path it does not own, the request is simply not found.
@route("GET HEAD POST PUT DELETE", "/v1/live-activity{rest:path}", "/v2/live-activity{rest:path}")
def live_activity_route(x):
    # HEAD is GET without the body.
    method = "GET" if x.command == "HEAD" else x.command
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
def admin_page(x): x.send_file(STATIC_ROOT / "admin.html", "text/html; charset=utf-8")

@route("GET HEAD", "/static/admin.css")
def admin_css(x): x.send_file(STATIC_ROOT / "admin.css", "text/css; charset=utf-8", x.versioned())

@route("GET HEAD", "/static/admin.js")
def admin_js(x): x.send_file(STATIC_ROOT / "admin.js", "application/javascript; charset=utf-8", x.versioned())

@route("GET HEAD", "/health")
def health(x): x.send_json(200,{"ok":True})

@route("GET HEAD", "/v1/admin/session")
def admin_session(x):
    if admin_only(x): return
    x.send_json(200, {"authenticated": True})

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
    x.send_json(200,value) if value else x.send_json(404,{"error":"share not found"})

@route("POST", "/v1/usage/devices/{installation:path}")
def report_usage(x):
    accepted = x.store.report_usage(x.path.removeprefix("/v1/usage/devices/"),
                                    x.headers.get("X-Device-Secret", ""), x.body())
    x.send_json(200, {"accepted": True}) if accepted else x.send_json(403, {"error": "invalid device secret"})

@route("POST", "/v1/admin/session")
def sign_in(x):
    secret = x.admin_secret()
    supplied = str(x.body().get("token", ""))
    if not secret or not _same_secret(supplied, secret):
        return x.send_json(403, {"error": "admin token required"})
    cookie = x.session_cookie(x.store.create_admin_session(secret), int(ADMIN_SESSION_TTL.total_seconds()))
    x.send_json(200, {"authenticated": True}, [("Set-Cookie", cookie)])

@route("POST", "/v1/admin/apns")
def save_apns(x):
    if admin_only(x): return
    candidate = x.body()
    # Parse the key before writing, so a typo cannot replace a
    # working configuration with one that the dispatcher cannot use.
    # The client checked here is the one the dispatcher then uses.
    client = live_activity._client_from_config(candidate)
    try:
        if x.live_activity is not None and hasattr(x.live_activity, "v2"):
            x.live_activity.v2.validate_client(client)
        value = x.store.save_apns_config(candidate)
    except BaseException:
        if client is not None: client.close()
        raise
    if x.live_activity is not None:
        live_activity.apply_config(x.live_activity, value, client=client)
    elif client is not None: client.close()
    x.send_json(200, x.apns_status())

@route("POST", "/v1/admin/apns/reconcile")
def reconcile_apns(x):
    if admin_only(x): return
    x.send_json(200, {"config": x.apns_status(), "created": [], "errors": []})

@route("POST", "/v1/admin/calendar")
def save_calendar(x):
    if admin_only(x): return
    x.send_json(200, x.store.save_global_calendar(x.body()))

@route("POST", "/v1/admin/calendar/import")
def import_calendar(x):
    if admin_only(x): return
    x.send_json(200, x.store.import_calendar(x.body()))

@route("POST", "/v1/admin/schools/{school_id:school}/rename")
def rename_school(x):
    if admin_only(x): return
    new_id = x.body().get("id")
    saved = x.store.rename_school(x.path.split("/")[4], new_id)
    if not saved: return x.send_json(404, {"error": "school not found"})
    if x.live_activity is not None:
        config = x.store.apns_config()
        x.live_activity.channels = live_activity._channels_from_value(config.get("channels", {}) if config else {})
    x.send_json(200, saved)

@route("POST", "/v1/shares")
def create_share(x): x.send_json(201,x.store.create(x.body()))

@route("POST", "/v1/shares/{rest:path}")
def share_action(x):
    path = x.path
    if path.endswith("/replace"):
        code = path[len("/v1/shares/"):-len("/replace")]
        value = x.store.create(x.body(), previous_code=code, write_token=x.headers.get("X-Write-Token", ""))
        return x.send_json(201, value) if value else x.send_json(403, {"error": "invalid write token"})
    if path.endswith("/resync"):
        code=path[len("/v1/shares/"):-len("/resync")]
        value=x.store.resync(code,x.headers.get("X-Write-Token",""))
        return x.send_json(200,value) if value else x.send_json(403,{"error":"invalid write token"})
    x.send_json(404,{"error":"not found"})

@route("POST", "/v1/schools/{rest:path}")
def save_school(x):
    if not x.require_admin():
        return x.send_json(403,{"error":"school template is read-only without admin token"})
    value=x.body(); value["id"]=x.path.rsplit("/",1)[-1]
    # A contract with admin.js: `"create": true` adds a school and
    # never overwrites one that already has this id.
    try: saved = x.store.save_school(value, create=value.pop("create", False) is True)
    except SchoolExists: return x.send_json(409, {"error": "school exists"})
    x.send_json(200, saved)

@route("POST", "/v1/admin/schools/{rest:path}")
def save_term(x):
    if not x.path.endswith("/terms"): return x.send_json(404,{"error":"not found"})
    if admin_only(x): return
    x.send_json(200, x.store.save_term(x.path.split("/")[4], x.body()))

@route("PUT", "/v1/shares/{rest:path}")
def update_share(x):
    value=x.store.update(x.path.rsplit("/",1)[-1],x.headers.get("X-Write-Token",""),x.body())
    x.send_json(200,value) if value else x.send_json(403,{"error":"invalid write token"})

@route("DELETE", "/v1/admin/session")
def sign_out(x):
    x.store.delete_admin_session(x.cookie(ADMIN_COOKIE))
    x.send_json(200, {"authenticated": False}, [("Set-Cookie", x.session_cookie("", 0))])

@route("DELETE", "/v1/schools/{school_id:school}")
def delete_school(x):
    if admin_only(x): return
    if not x.store.delete_school(x.path.rsplit("/", 1)[-1]):
        return x.send_json(404, {"error": "school not found"})
    x.send_json(200, {"deleted": True})

@route("DELETE", "/v1/shares/{rest:path}")
def revoke_share(x):
    revoked=x.store.revoke(x.path.rsplit("/",1)[-1],x.headers.get("X-Write-Token",""))
    if revoked is None: return x.send_json(404,{"error":"share not found"})
    x.send_json(200,{"revoked":True}) if revoked else x.send_json(403,{"error":"invalid write token"})

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

def create_app(store, service=None, workers=True):
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

#!/usr/bin/env python3
"""Server side scheduling for iOS Live Activities.

iOS only lets an app start a Live Activity from the foreground, so a class that
begins while NapTable is suspended cannot put anything on the Lock Screen. The
way around that is the iOS 17.2 push-to-start token: the app hands its token to
this server, the server pushes `start` at the right moment, and the system
starts the activity without the app being opened.

The division of labour is deliberate. The app already knows how to turn a
timetable into what the island should show -- lead time, the persistent mode,
the labels -- so it uploads a *plan*: fully rendered content states each with
the instant it should be pushed. This server stores the plan, waits, and relays
it to APNs. It never parses a timetable, so the two sides cannot drift apart,
and `content-state` is encoded once, by the same Swift types that decode it.
"""
from __future__ import annotations

import hashlib
import json
import os
import secrets
import threading
import time
from datetime import datetime, timedelta, timezone
try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python versions without zoneinfo
    ZoneInfo = None

try:  # `python3 server/naptable_server.py` and `import server.live_activity`
    from . import apns
except ImportError:  # pragma: no cover - depends on how the server was started
    import apns

SCHEMA = """
CREATE TABLE IF NOT EXISTS la_day_channels (
 school_id TEXT NOT NULL, date_key TEXT NOT NULL, environment TEXT NOT NULL,
 bundle_id TEXT NOT NULL, channel_id TEXT NOT NULL,
 PRIMARY KEY (school_id,date_key,environment,bundle_id)
);
CREATE TABLE IF NOT EXISTS la_devices (
 device_id TEXT PRIMARY KEY, secret_hash TEXT NOT NULL, start_token TEXT NOT NULL DEFAULT '',
 environment TEXT NOT NULL DEFAULT 'production', bundle_id TEXT NOT NULL DEFAULT '',
 time_zone TEXT NOT NULL DEFAULT 'Asia/Shanghai', school_id TEXT NOT NULL DEFAULT '',
 term_id TEXT NOT NULL DEFAULT '', channel_id TEXT NOT NULL DEFAULT '',
 supports_broadcast INTEGER NOT NULL DEFAULT 0, broadcast_enabled INTEGER NOT NULL DEFAULT 0,
 enabled INTEGER NOT NULL DEFAULT 1,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS la_plan (
 device_id TEXT NOT NULL, item_id TEXT NOT NULL, fire_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL, event TEXT NOT NULL, payload_json TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending', detail TEXT NOT NULL DEFAULT '',
 sent_at TEXT NOT NULL DEFAULT '', revision INTEGER NOT NULL DEFAULT 0,
 attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NOT NULL DEFAULT 0,
 claimed_until INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (device_id, item_id)
);
CREATE INDEX IF NOT EXISTS la_plan_due ON la_plan (state, fire_at);
CREATE TABLE IF NOT EXISTS la_activities (
 device_id TEXT NOT NULL, activity_id TEXT NOT NULL, update_token TEXT NOT NULL,
 expires_at INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL,
 PRIMARY KEY (device_id, activity_id)
);
CREATE TABLE IF NOT EXISTS la_broadcast_plan (
 channel_id TEXT NOT NULL, environment TEXT NOT NULL, bundle_id TEXT NOT NULL,
 event_id TEXT NOT NULL, fire_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
 event TEXT NOT NULL, payload_json TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending', detail TEXT NOT NULL DEFAULT '',
 sent_at TEXT NOT NULL DEFAULT '', attempts INTEGER NOT NULL DEFAULT 0,
 next_attempt_at INTEGER NOT NULL DEFAULT 0, claimed_until INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY (channel_id, event_id)
);
CREATE INDEX IF NOT EXISTS la_broadcast_due ON la_broadcast_plan (state, fire_at);
"""

EVENTS = ("start", "update", "end")
MAX_PLAN_ITEMS = 240
# One APNs payload is capped at 4 KB; leave room for the `aps` keys this server
# adds around the uploaded content state.
MAX_ITEM_BYTES = 3200
MAX_HORIZON = 45 * 24 * 3600
ATTRIBUTES_TYPE = "ScheduleLiveActivityAttributes"
CLAIM_SECONDS = 30
RETRY_BASE_SECONDS = 5
RETRY_MAX_SECONDS = 300
BROADCAST_LATE_WINDOW = 60


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _hash(value):
    return hashlib.sha256(value.encode()).hexdigest()


def _token_is_hex(value):
    return bool(value) and len(value) <= 200 and all(c in "0123456789abcdefABCDEF" for c in value)


class PlanError(ValueError):
    """A plan the server refuses to store, reported back to the client."""


def normalize_item(raw, now):
    """Validate one uploaded plan entry and return its storable form."""
    if not isinstance(raw, dict):
        raise PlanError("plan items must be objects")
    item_id = str(raw.get("id", "")).strip()
    if not item_id or len(item_id) > 120:
        raise PlanError("each plan item needs an id of at most 120 characters")
    event = str(raw.get("event", "")).strip()
    if event not in EVENTS:
        raise PlanError(f"event must be one of {', '.join(EVENTS)}")
    try:
        fire_at = int(raw["fireAt"])
    except (KeyError, TypeError, ValueError):
        raise PlanError("fireAt must be a Unix timestamp in seconds")
    if not now - 3600 <= fire_at <= now + MAX_HORIZON:
        raise PlanError("fireAt is outside the accepted window")
    expires_at = raw.get("expiresAt")
    expires_at = int(expires_at) if isinstance(expires_at, (int, float)) else fire_at + 3600
    if expires_at <= fire_at:
        expires_at = fire_at + 60
    content_state = raw.get("contentState")
    if not isinstance(content_state, dict):
        raise PlanError("contentState must be an object")
    payload = {"contentState": content_state, "attributesType": str(raw.get("attributesType") or ATTRIBUTES_TYPE)}
    if event == "start":
        if not isinstance(raw.get("attributes"), dict):
            raise PlanError("a start item must carry the activity attributes")
        payload["attributes"] = raw["attributes"]
    for key in ("staleDate", "dismissalDate"):
        if isinstance(raw.get(key), (int, float)):
            payload[key] = int(raw[key])
    if isinstance(raw.get("relevanceScore"), (int, float)):
        payload["relevanceScore"] = float(raw["relevanceScore"])
    if isinstance(raw.get("alert"), dict):
        alert = {k: str(v)[:200] for k, v in raw["alert"].items() if k in ("title", "body", "sound")}
        if alert:
            payload["alert"] = alert
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    if len(encoded.encode()) > MAX_ITEM_BYTES:
        raise PlanError(f"plan item {item_id} is larger than {MAX_ITEM_BYTES} bytes")
    return {"id": item_id, "fire_at": fire_at, "expires_at": expires_at, "event": event, "payload": encoded}


def aps_payload(event, payload, timestamp):
    """Turn a stored plan item into the `aps` dictionary APNs expects."""
    aps = {"timestamp": int(timestamp), "event": event, "content-state": payload["contentState"]}
    if event == "start":
        aps["attributes-type"] = payload.get("attributesType", ATTRIBUTES_TYPE)
        aps["attributes"] = payload.get("attributes", {})
    if "staleDate" in payload:
        aps["stale-date"] = payload["staleDate"]
    if "dismissalDate" in payload and event == "end":
        aps["dismissal-date"] = payload["dismissalDate"]
    if "relevanceScore" in payload:
        aps["relevance-score"] = payload["relevanceScore"]
    if "alert" in payload:
        aps["alert"] = payload["alert"]
    return {"aps": aps}


class LiveActivityService:
    """Device registry, plan storage and the dispatcher that sends the pushes."""

    def __init__(self, db, lock, client=None, now=time.time, tick=5.0, channels=None):
        self.db = db
        self.lock = lock
        self.client = client
        self.now = now
        self.tick = tick
        self.channels = channels or {}
        self._stop = threading.Event()
        self._thread = None
        self._day_channels_lock = threading.Lock()
        self._day_channels_checked = 0
        with self.lock:
            self.db.executescript(SCHEMA)
            columns = {row[1] for row in self.db.execute("PRAGMA table_info(la_devices)")}
            migrations = {
                "school_id": "TEXT NOT NULL DEFAULT ''",
                "term_id": "TEXT NOT NULL DEFAULT ''",
                "channel_id": "TEXT NOT NULL DEFAULT ''",
                "supports_broadcast": "INTEGER NOT NULL DEFAULT 0",
                "broadcast_enabled": "INTEGER NOT NULL DEFAULT 0",
            }
            for name, definition in migrations.items():
                if name not in columns:
                    self.db.execute(f"ALTER TABLE la_devices ADD COLUMN {name} {definition}")
            plan_columns = {row[1] for row in self.db.execute("PRAGMA table_info(la_plan)")}
            for name, definition in {
                "revision": "INTEGER NOT NULL DEFAULT 0",
                "attempts": "INTEGER NOT NULL DEFAULT 0",
                "next_attempt_at": "INTEGER NOT NULL DEFAULT 0",
                "claimed_until": "INTEGER NOT NULL DEFAULT 0",
            }.items():
                if name not in plan_columns:
                    self.db.execute(f"ALTER TABLE la_plan ADD COLUMN {name} {definition}")
            broadcast_columns = {row[1] for row in self.db.execute("PRAGMA table_info(la_broadcast_plan)")}
            for name, definition in {
                "attempts": "INTEGER NOT NULL DEFAULT 0",
                "next_attempt_at": "INTEGER NOT NULL DEFAULT 0",
                "claimed_until": "INTEGER NOT NULL DEFAULT 0",
            }.items():
                if name not in broadcast_columns:
                    self.db.execute(f"ALTER TABLE la_broadcast_plan ADD COLUMN {name} {definition}")
            self.db.commit()

    # -- lifecycle ---------------------------------------------------------

    def start(self):
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="live-activity-dispatch", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None

    def reconfigure(self, client=None, tick=5.0, channels=None):
        """Apply WebUI settings without restarting the HTTP server."""
        old = self.client
        self.client = client
        self.tick = max(0.5, float(tick))
        self.channels = channels or {}
        with self.lock:
            devices = self.db.execute(
                "SELECT device_id,environment,school_id,supports_broadcast FROM la_devices").fetchall()
            for row in devices:
                channel_id = self.channel_id(row["school_id"], row["environment"]) if row["supports_broadcast"] else ""
                self.db.execute("UPDATE la_devices SET channel_id=?,broadcast_enabled=? WHERE device_id=?",
                                (channel_id, int(bool(channel_id)), row["device_id"]))
            self.db.commit()
        if old is not None and old is not client:
            close = getattr(old, "close", None)
            if close:
                close()

    def _run(self):
        while not self._stop.wait(self.tick):
            try:
                self.dispatch_due()
            except Exception as error:  # a bad row must not kill the loop
                print(f"live activity dispatch failed: {error}")

    # -- devices -----------------------------------------------------------

    def ensure_day_channels(self):
        """Provision two school dates, retaining yesterday for late delivery.

        Only server-owned IDs are deleted. APNs allows 10,000 channels per
        app/environment; failures leave rows intact so cleanup can retry.
        """
        if self.client is None or not hasattr(self.client, "create_channel"):
            return
        with self._day_channels_lock:
            now = self.now()
            if now - self._day_channels_checked < 60:
                return
            self._day_channels_checked = now
            zone = timezone(timedelta(hours=8))
            today = datetime.fromtimestamp(now, zone).date()
            with self.lock:
                if not self.db.execute("SELECT 1 FROM sqlite_master WHERE name='school_configs'").fetchone():
                    return
                schools = [r[0] for r in self.db.execute("SELECT id FROM school_configs")]
                rows = self.db.execute("SELECT * FROM la_day_channels").fetchall()
            bundle = self.client.bundle_id
            for row in rows:
                if row["bundle_id"] != bundle:
                    continue
                if row["date_key"] < (today - timedelta(days=1)).isoformat():
                    try:
                        self.client.delete_channel(row["channel_id"], environment=row["environment"])
                        with self.lock:
                            self.db.execute("DELETE FROM la_day_channels WHERE channel_id=?", (row["channel_id"],))
                            self.db.execute("DELETE FROM la_broadcast_plan WHERE channel_id=?", (row["channel_id"],))
                            self.db.commit()
                    except Exception as error:
                        print(f"day channel cleanup failed: {error}")
            for school in schools:
                for offset in range(2):
                    date = (today + timedelta(days=offset)).isoformat()
                    for environment in ("production", "sandbox"):
                        with self.lock:
                            exists = self.db.execute("SELECT 1 FROM la_day_channels WHERE school_id=? AND date_key=? AND environment=? AND bundle_id=?", (school, date, environment, bundle)).fetchone()
                            count = self.db.execute("SELECT COUNT(*) FROM la_day_channels WHERE environment=? AND bundle_id=?", (environment, bundle)).fetchone()[0]
                        if exists:
                            continue
                        if count + len(self.channels) >= 9000:
                            continue
                        try:
                            channel = self.client.create_channel(environment=environment)
                            with self.lock:
                                self.db.execute("INSERT INTO la_day_channels VALUES (?,?,?,?,?)", (school, date, environment, bundle, channel))
                                self.db.commit()
                        except Exception as error:
                            print(f"day channel provisioning failed: {error}")

    def day_config(self, value):
        environment = value.get("environment", "production")
        school = value.get("schoolID", "")
        if environment not in ("production", "sandbox"):
            raise PlanError("invalid environment")
        bundle = getattr(self.client, "bundle_id", "")
        if bundle and value.get("bundleID") != bundle:
            raise PlanError("Bundle ID mismatch")
        # Read only: polling clients never trigger APNs management requests.
        today = datetime.fromtimestamp(self.now(), timezone(timedelta(hours=8))).date()
        with self.lock:
            rows = self.db.execute("SELECT date_key,channel_id FROM la_day_channels WHERE school_id=? AND environment=? AND bundle_id=? AND date_key>=? AND date_key<=?", (school, environment, bundle, today.isoformat(), (today + timedelta(days=1)).isoformat())).fetchall()
        return {"channels": {r[0]: r[1] for r in rows}, "pushConfigured": self.client is not None}

    def register(self, value):
        """Create a device row, or refresh the one identified by its secret."""
        start_token = str(value.get("startToken", "")).strip()
        if start_token and not _token_is_hex(start_token):
            raise PlanError("startToken must be hexadecimal")
        environment = value.get("environment", "production")
        if environment not in ("production", "sandbox"):
            raise PlanError("environment must be production or sandbox")
        bundle_id = str(value.get("bundleID") or getattr(self.client, "bundle_id", "naptable")).strip()[:120]
        if not bundle_id or any(char.isspace() for char in bundle_id):
            raise PlanError("bundleID must be a valid App Bundle ID")
        time_zone = str(value.get("timeZone", "Asia/Shanghai"))[:64]
        school_id = str(value.get("schoolID", "")).strip()[:120]
        term_id = str(value.get("termID", "")).strip()[:120]
        broadcast_enabled = bool(value.get("supportsBroadcast", False))
        channel_id = self.channel_id(school_id, environment) if broadcast_enabled else ""
        device_id = str(value.get("deviceID", "")).strip()
        stamp = _now_iso()
        if device_id:
            row = self._device(device_id)
            if row is None:
                raise PlanError("unknown deviceID")
            with self.lock:
                self.db.execute(
                    "UPDATE la_devices SET start_token=?,environment=?,bundle_id=?,time_zone=?,school_id=?,term_id=?,channel_id=?,supports_broadcast=?,broadcast_enabled=?,enabled=1,updated_at=? WHERE device_id=?",
                    (start_token or row["start_token"], environment, bundle_id, time_zone, school_id,
                     term_id, channel_id, int(broadcast_enabled), int(bool(channel_id)), stamp, device_id))
                self.db.commit()
            return self.registration_status(device_id)
        device_id = secrets.token_hex(16)
        secret = secrets.token_urlsafe(32)
        with self.lock:
            self.db.execute(
                "INSERT INTO la_devices (device_id,secret_hash,start_token,environment,bundle_id,time_zone,school_id,term_id,channel_id,supports_broadcast,broadcast_enabled,enabled,created_at,updated_at)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (device_id, _hash(secret), start_token, environment, bundle_id, time_zone, school_id,
                 term_id, channel_id, int(broadcast_enabled), int(bool(channel_id)), 1, stamp, stamp))
            self.db.commit()
        result = self.registration_status(device_id)
        result["secret"] = secret
        return result

    def channel_id(self, school_id, environment):
        """Return the APNs channel configured for one school/environment."""
        return str(self.channels.get((environment, school_id), "")).strip()

    def registration_status(self, device_id):
        row = self._device(device_id)
        channel_id = row["channel_id"] if row else ""
        return {
            "deviceID": device_id,
            "pushConfigured": self.client is not None,
            "broadcastConfigured": bool(channel_id),
            "channelID": channel_id or None,
        }

    def _device(self, device_id):
        with self.lock:
            return self.db.execute("SELECT * FROM la_devices WHERE device_id=?", (device_id,)).fetchone()

    def authenticate(self, device_id, secret):
        row = self._device(device_id)
        if row is None or not secret:
            return None
        return row if secrets.compare_digest(row["secret_hash"], _hash(secret)) else None

    def forget(self, device_id):
        with self.lock:
            self.db.execute("DELETE FROM la_plan WHERE device_id=?", (device_id,))
            self.db.execute("DELETE FROM la_activities WHERE device_id=?", (device_id,))
            self.db.execute("DELETE FROM la_devices WHERE device_id=?", (device_id,))
            self.db.commit()

    # -- plan --------------------------------------------------------------

    def replace_plan(self, device_id, items):
        """Swap in a new plan. Everything still pending is dropped first, so a
        timetable edit cannot leave a push for a class that no longer exists."""
        if not isinstance(items, list):
            raise PlanError("items must be a list")
        if len(items) > MAX_PLAN_ITEMS:
            raise PlanError(f"a plan holds at most {MAX_PLAN_ITEMS} items")
        now = int(self.now())
        normalized = [normalize_item(item, now) for item in items]
        seen = set()
        for item in normalized:
            if item["id"] in seen:
                raise PlanError(f"duplicate plan item id {item['id']}")
            seen.add(item["id"])
        with self.lock:
            revision_row = self.db.execute(
                "SELECT COALESCE(MAX(revision), 0) FROM la_plan WHERE device_id=?", (device_id,)
            ).fetchone()
            revision = int(revision_row[0]) + 1
            self.db.execute("DELETE FROM la_plan WHERE device_id=? AND state='pending'", (device_id,))
            self.db.executemany(
                "INSERT INTO la_plan (device_id,item_id,fire_at,expires_at,event,payload_json,revision,next_attempt_at) VALUES (?,?,?,?,?,?,?,?)"
                " ON CONFLICT(device_id,item_id) DO UPDATE SET fire_at=excluded.fire_at,expires_at=excluded.expires_at,"
                "event=excluded.event,payload_json=excluded.payload_json,state='pending',detail='',sent_at='',"
                "revision=excluded.revision,attempts=0,next_attempt_at=excluded.next_attempt_at,claimed_until=0",
                [(device_id, i["id"], i["fire_at"], i["expires_at"], i["event"], i["payload"], revision, now)
                 for i in normalized])
            # History is only useful while it is recent.
            self.db.execute("DELETE FROM la_plan WHERE device_id=? AND state!='pending' AND fire_at < ?",
                            (device_id, now - 3 * 24 * 3600))
            self.db.commit()
        return self.status(device_id)

    def status(self, device_id):
        with self.lock:
            row = self.db.execute("SELECT * FROM la_devices WHERE device_id=?", (device_id,)).fetchone()
            pending = self.db.execute(
                "SELECT COUNT(*) , MIN(fire_at) FROM la_plan WHERE device_id=? AND state='pending'", (device_id,)).fetchone()
            recent = self.db.execute(
                "SELECT item_id,event,fire_at,state,detail,sent_at FROM la_plan WHERE device_id=? AND state!='pending'"
                " ORDER BY fire_at DESC LIMIT 10", (device_id,)).fetchall()
            activities = self.db.execute("SELECT COUNT(*) FROM la_activities WHERE device_id=?", (device_id,)).fetchone()
        if row is None:
            return None
        return {
            "deviceID": device_id,
            "environment": row["environment"],
            "schoolID": row["school_id"],
            "termID": row["term_id"],
            "channelID": row["channel_id"] or None,
            "broadcastEnabled": bool(row["broadcast_enabled"]),
            "broadcastConfigured": bool(row["channel_id"]),
            "hasStartToken": bool(row["start_token"]),
            "enabled": bool(row["enabled"]),
            "pushConfigured": self.client is not None,
            "pendingCount": pending[0],
            "nextFireAt": pending[1],
            "activityCount": activities[0],
            "updatedAt": row["updated_at"],
            "recent": [dict(item) for item in recent],
        }

    # -- started activities ------------------------------------------------

    def remember_activity(self, device_id, value):
        activity_id = str(value.get("activityID", "")).strip()[:120]
        update_token = str(value.get("updateToken", "")).strip()
        if not activity_id or not _token_is_hex(update_token):
            raise PlanError("activityID and a hexadecimal updateToken are required")
        expires = value.get("expiresAt")
        expires = int(expires) if isinstance(expires, (int, float)) else int(self.now()) + 24 * 3600
        with self.lock:
            self.db.execute(
                "INSERT INTO la_activities VALUES (?,?,?,?,?) ON CONFLICT(device_id,activity_id) DO UPDATE SET"
                " update_token=excluded.update_token,expires_at=excluded.expires_at,updated_at=excluded.updated_at",
                (device_id, activity_id, update_token, expires, _now_iso()))
            self.db.execute("DELETE FROM la_activities WHERE device_id=? AND expires_at < ?",
                            (device_id, int(self.now()) - 3600))
            self.db.commit()
        return {"activityID": activity_id}

    def forget_activity(self, device_id, activity_id):
        with self.lock:
            self.db.execute("DELETE FROM la_activities WHERE device_id=? AND activity_id=?", (device_id, activity_id))
            self.db.commit()

    def _update_token(self, device_id):
        with self.lock:
            row = self.db.execute(
                "SELECT activity_id,update_token FROM la_activities WHERE device_id=? AND expires_at > ?"
                " ORDER BY updated_at DESC LIMIT 1", (device_id, int(self.now()))).fetchone()
        return (row["activity_id"], row["update_token"]) if row else (None, None)

    # -- dispatch ----------------------------------------------------------

    def _broadcast_payload(self, date_key, period, phase, timestamp):
        state = {
            "phase": "inProgress" if phase == "started" else "upcoming",
            "courseName": "",
            "startDate": int(timestamp),
            "endDate": int(timestamp),
            "updatedAt": int(timestamp),
            "broadcastDateKey": date_key,
            "broadcastPeriod": period,
            "broadcastPhase": phase,
            "broadcastTimestamp": int(timestamp),
        }
        return {"aps": {"timestamp": int(timestamp), "event": "update", "content-state": state}}

    def _ensure_broadcast_plan(self, now):
        """Materialize a short rolling window of school boundary events.

        A channel is shared by every user of a school. The server therefore
        only needs the school's bell schedule, not any student's courses.
        Devices decide locally whether the boundary maps to a course.
        """
        if self.client is None:
            return
        with self.lock:
            devices = self.db.execute(
                "SELECT DISTINCT channel_id,environment,bundle_id,school_id,time_zone "
                "FROM la_devices WHERE enabled=1 AND broadcast_enabled=1 AND channel_id != ''"
            ).fetchall()
            devices = list(devices) + [dict(r, time_zone="Asia/Shanghai") for r in self.db.execute(
                "SELECT * FROM la_day_channels WHERE bundle_id=?", (getattr(self.client, "bundle_id", ""),)).fetchall()]
        horizon = 8
        for row in devices:
            with self.lock:
                term = self.db.execute(
                    "SELECT t.*,s.periods_json AS school_periods_json FROM school_terms t "
                    "JOIN school_configs s ON s.id=t.school_id "
                    "WHERE t.school_id=? AND t.is_current=1 LIMIT 1",
                    (row["school_id"],)).fetchone()
                calendar = self.db.execute("SELECT adjustments_json FROM global_calendar WHERE id=1").fetchone()
            if term is None:
                continue
            try:
                zone = ZoneInfo(row["time_zone"] or term["timezone"] or "Asia/Shanghai") if ZoneInfo else timezone.utc
                start = datetime.fromtimestamp(now, timezone.utc).astimezone(zone).date() - timedelta(days=1)
                term_start = datetime.fromisoformat(term["semester_start_monday"]).date()
                term_end = term_start + timedelta(days=max(1, int(term["week_count"])) * 7)
                periods = json.loads(term["school_periods_json"] or "[]")
                adjustments = {x.get("date"): x for x in json.loads(calendar[0] or "[]")}
            except (ValueError, TypeError, json.JSONDecodeError):
                continue
            rows = []
            for offset in range(horizon):
                date = start + timedelta(days=offset)
                if isinstance(row, dict) and row.get("date_key") != date.isoformat():
                    continue
                if date < term_start or date >= term_end:
                    continue
                adjustment = adjustments.get(date.isoformat())
                if adjustment and adjustment.get("kind") == "off":
                    continue
                last_end = max((str(p.get("end", "")) for p in periods), default="")
                for index, period in enumerate(periods, 1):
                    for phase, clock in (("started", period.get("start")), ("ended", period.get("end"))):
                        try:
                            hour, minute = map(int, str(clock).split(":", 1))
                            instant = datetime(date.year, date.month, date.day, hour, minute, tzinfo=zone)
                        except (ValueError, TypeError):
                            continue
                        fire_at = int(instant.timestamp())
                        if fire_at <= now - 3600 or fire_at > now + MAX_HORIZON:
                            continue
                        daily = isinstance(row, dict)
                        event = "end" if not daily and phase == "ended" and clock == last_end else "update"
                        event_id = f"day-{date.isoformat()}-{fire_at}" if daily else f"{date.isoformat()}-{index}-{phase}"
                        payload = self._broadcast_payload(date.isoformat(), index, phase, fire_at)
                        rows.append((row["channel_id"], row["environment"], row["bundle_id"], event_id,
                                     fire_at, fire_at + BROADCAST_LATE_WINDOW, event,
                                     json.dumps(payload, separators=(",", ":"))))
            if rows:
                # Coincident bells collapse to one absolute signal. Legacy
                # channels still prefer the final end event at that timestamp.
                rows = list({(r[0], r[3]): r for r in sorted(rows, key=lambda r: r[6] == "end")}.values())
                with self.lock:
                    self.db.executemany(
                        "INSERT INTO la_broadcast_plan (channel_id,environment,bundle_id,event_id,fire_at,expires_at,event,payload_json)"
                        " VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(channel_id,event_id) DO UPDATE SET"
                        " environment=excluded.environment,bundle_id=excluded.bundle_id,fire_at=excluded.fire_at,"
                        " expires_at=excluded.expires_at,event=excluded.event,payload_json=excluded.payload_json",
                        rows)
                    self.db.execute("DELETE FROM la_broadcast_plan WHERE state!='pending' AND fire_at < ?", (now - 3 * 86400,))
                    self.db.commit()

    def dispatch_due(self):
        """Send every item whose moment has come. Returns the results, which
        the tests read and the loop ignores."""
        now = int(self.now())
        self.ensure_day_channels()
        self._ensure_broadcast_plan(now)
        with self.lock:
            rows = self.db.execute(
                "SELECT p.*, d.start_token, d.environment, d.enabled, d.broadcast_enabled, d.bundle_id, d.time_zone FROM la_plan p JOIN la_devices d"
                " ON d.device_id=p.device_id WHERE p.state='pending' AND p.fire_at <= ? AND p.next_attempt_at <= ?"
                " AND p.claimed_until <= ? ORDER BY p.fire_at LIMIT 200", (now, now, now)).fetchall()
            broadcast_rows = self.db.execute(
                "SELECT * FROM la_broadcast_plan WHERE state='pending' AND fire_at <= ? AND next_attempt_at <= ?"
                " AND claimed_until <= ? ORDER BY fire_at LIMIT 200", (now, now, now)).fetchall()
            claimed_until = now + CLAIM_SECONDS
            claimed = []
            for row in rows:
                changed = self.db.execute(
                    "UPDATE la_plan SET claimed_until=? WHERE device_id=? AND item_id=? AND revision=?"
                    " AND state='pending' AND next_attempt_at <= ? AND claimed_until <= ?",
                    (claimed_until, row["device_id"], row["item_id"], row["revision"], now, now)).rowcount
                if changed:
                    claimed.append(row)
            rows = claimed
            claimed_broadcast = []
            for row in broadcast_rows:
                changed = self.db.execute(
                    "UPDATE la_broadcast_plan SET claimed_until=? WHERE channel_id=? AND event_id=?"
                    " AND state='pending' AND next_attempt_at <= ? AND claimed_until <= ?",
                    (claimed_until, row["channel_id"], row["event_id"], now, now)).rowcount
                if changed:
                    claimed_broadcast.append(row)
            broadcast_rows = claimed_broadcast
            self.db.commit()
        results = []
        for row in broadcast_rows:
            results.append(self._dispatch_broadcast(dict(row), now))
        off_dates = self.off_dates() if rows else frozenset()
        for row in rows:
            results.append(self._dispatch(dict(row), now, off_dates))
        return results

    def _dispatch_broadcast(self, row, now):
        if row["expires_at"] < now:
            return self._finish_broadcast(row["channel_id"], row["event_id"], "skipped", "expired before it could be sent")
        if self.client is None:
            return self._retry_broadcast(row, now, "APNs is not configured")
        payload = json.loads(row["payload_json"])
        with self.lock:
            is_day_channel = self.db.execute(
                "SELECT 1 FROM la_day_channels WHERE channel_id=? LIMIT 1", (row["channel_id"],)
            ).fetchone() is not None
        event = "update" if is_day_channel else row["event"]
        payload["aps"]["event"] = event
        if event == "end":
            payload["aps"]["dismissal-date"] = int(row["fire_at"])
        else:
            payload["aps"].pop("dismissal-date", None)
        result = self.client.broadcast(
            row["channel_id"], payload, environment=row["environment"],
            priority=10, expiration=0, collapse_id=f"school-{row['event_id']}", topic=row["bundle_id"])
        if result["ok"]:
            return self._finish_broadcast(row["channel_id"], row["event_id"], "sent", "")
        detail = f"{result['status']} {result.get('reason', '')}".strip()
        if self._retryable(result) and now < row["expires_at"]:
            return self._retry_broadcast(row, now, detail)
        return self._finish_broadcast(row["channel_id"], row["event_id"], "failed", detail)

    def off_dates(self):
        """Dates the global 调休 table turned into a holiday.

        A plan is rendered by the app and can be days old, so an arrangement
        published after the upload would otherwise be pushed as a normal class.
        """
        with self.lock:
            # The service also runs against a database that only holds the Live
            # Activity tables, so the calendar may simply not be there.
            if not self.db.execute(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='global_calendar'").fetchone():
                return frozenset()
            row = self.db.execute("SELECT adjustments_json FROM global_calendar WHERE id=1").fetchone()
        if row is None:
            return frozenset()
        try:
            items = json.loads(row[0] or "[]")
        except (TypeError, ValueError, json.JSONDecodeError):
            return frozenset()
        return frozenset(str(item.get("date")) for item in items
                         if isinstance(item, dict) and item.get("kind") == "off")

    @staticmethod
    def _school_day(row, payload):
        """The day this push belongs to, as the device's calendar sees it."""
        attributes = payload.get("attributes")
        if isinstance(attributes, dict) and attributes.get("dateKey"):
            return str(attributes["dateKey"])
        state = payload.get("contentState") or {}
        stamp = state.get("startDate")
        if not isinstance(stamp, (int, float)):
            stamp = row["fire_at"]
        zone = timezone.utc
        if ZoneInfo:
            try:
                zone = ZoneInfo(row.get("time_zone") or "Asia/Shanghai")
            except Exception:
                zone = timezone.utc
        return datetime.fromtimestamp(float(stamp), timezone.utc).astimezone(zone).date().isoformat()

    def _dispatch(self, row, now, off_dates=None):
        device_id, item_id, event = row["device_id"], row["item_id"], row["event"]
        with self.lock:
            current = self.db.execute(
                "SELECT revision,state FROM la_plan WHERE device_id=? AND item_id=?",
                (device_id, item_id),
            ).fetchone()
        if current is None or current["revision"] != row["revision"] or current["state"] != "pending":
            return {"deviceID": device_id, "itemID": item_id, "state": "superseded", "detail": "plan revision changed"}
        if row["expires_at"] <= now:
            # The frame this push would have shown is already over; sending it
            # would put a finished class back on the Lock Screen.
            return self._finish(device_id, item_id, "skipped", "expired before it could be sent", row["revision"])
        if not row["enabled"]:
            return self._finish(device_id, item_id, "skipped", "device disabled", row["revision"])
        if row.get("broadcast_enabled"):
            return self._finish(device_id, item_id, "skipped", "device uses school broadcast channel", row["revision"])
        if self.client is None:
            return self._retry(row, now, "APNs is not configured")
        payload = json.loads(row["payload_json"])
        # An `end` still goes out on a holiday: it only dismisses whatever is
        # on the Lock Screen, which is never the wrong thing to do.
        if event != "end":
            dates = self.off_dates() if off_dates is None else off_dates
            if dates and self._school_day(row, payload) in dates:
                return self._finish(device_id, item_id, "skipped", "调休放假，这一天不推送", row["revision"])
        if event == "start":
            token = row["start_token"]
            if not token:
                return self._retry(row, now, "waiting for push-to-start token")
        else:
            activity_id, token = self._update_token(device_id)
            if not token:
                return self._retry(row, now, "waiting for activity update token")
        result = self.client.push(
            token, aps_payload(event, payload, now), environment=row["environment"],
            push_type="liveactivity", priority=10, expiration=row["expires_at"],
            # One collapse id per activity keeps a late update from landing
            # after the push that supersedes it.
            collapse_id=f"{device_id[:8]}-{event}", topic=f"{row['bundle_id']}.push-type.liveactivity")
        if result["ok"]:
            return self._finish(device_id, item_id, "sent", "", row["revision"])
        reason = result.get("reason", "")
        if reason in ("BadDeviceToken", "Unregistered", "ExpiredToken", "DeviceTokenNotForTopic"):
            self._invalidate(device_id, event, token)
        detail = f"{result['status']} {reason}".strip()
        if self._retryable(result) and now < row["expires_at"]:
            return self._retry(row, now, detail)
        return self._finish(device_id, item_id, "failed", detail, row["revision"])

    @staticmethod
    def _retryable(result):
        status = int(result.get("status") or 0)
        return status == 0 or status in (408, 429) or 500 <= status < 600

    @staticmethod
    def _retry_delay(attempts):
        return min(RETRY_MAX_SECONDS, RETRY_BASE_SECONDS * (2 ** min(max(0, int(attempts) - 1), 6)))

    def _retry(self, row, now, detail):
        attempts = int(row["attempts"] or 0) + 1
        next_at = now + self._retry_delay(attempts)
        with self.lock:
            self.db.execute(
                "UPDATE la_plan SET attempts=?,next_attempt_at=?,claimed_until=0,detail=?"
                " WHERE device_id=? AND item_id=? AND revision=? AND state='pending'",
                (attempts, next_at, detail, row["device_id"], row["item_id"], row["revision"]))
            self.db.commit()
        return {"deviceID": row["device_id"], "itemID": row["item_id"], "state": "retrying", "detail": detail}

    def _retry_broadcast(self, row, now, detail):
        attempts = int(row["attempts"] or 0) + 1
        next_at = now + self._retry_delay(attempts)
        with self.lock:
            self.db.execute(
                "UPDATE la_broadcast_plan SET attempts=?,next_attempt_at=?,claimed_until=0,detail=?"
                " WHERE channel_id=? AND event_id=? AND state='pending'",
                (attempts, next_at, detail, row["channel_id"], row["event_id"]))
            self.db.commit()
        return {"channelID": row["channel_id"], "eventID": row["event_id"], "state": "retrying", "detail": detail}

    def _invalidate(self, device_id, event, token):
        with self.lock:
            if event == "start":
                self.db.execute("UPDATE la_devices SET start_token='' WHERE device_id=? AND start_token=?",
                                (device_id, token))
            else:
                self.db.execute("DELETE FROM la_activities WHERE device_id=? AND update_token=?", (device_id, token))
            self.db.commit()

    def _finish(self, device_id, item_id, state, detail, revision=None):
        with self.lock:
            where = "device_id=? AND item_id=?"
            params = [state, detail, _now_iso(), device_id, item_id]
            if revision is not None:
                where += " AND revision=?"
                params.append(revision)
            self.db.execute(f"UPDATE la_plan SET state=?,detail=?,sent_at=?,claimed_until=0 WHERE {where}", params)
            self.db.commit()
        return {"deviceID": device_id, "itemID": item_id, "state": state, "detail": detail}

    def _finish_broadcast(self, channel_id, event_id, state, detail):
        with self.lock:
            self.db.execute("UPDATE la_broadcast_plan SET state=?,detail=?,sent_at=?,claimed_until=0 WHERE channel_id=? AND event_id=?",
                            (state, detail, _now_iso(), channel_id, event_id))
            self.db.commit()
        return {"channelID": channel_id, "eventID": event_id, "state": state, "detail": detail}


# ---------------------------------------------------------------------------
# HTTP routing, plugged into the main server's handler
# ---------------------------------------------------------------------------

PREFIX = "/v1/live-activity"


def handle(handler, service, method, path):
    """Answer a Live Activity request, or return False so the caller falls
    through to its own routes."""
    if service is None or not path.startswith(PREFIX):
        return False
    rest = path[len(PREFIX):]
    try:
        if method == "GET" and rest == "/health":
            return _send(handler, 200, {"ok": True, "pushConfigured": service.client is not None})
        if method == "POST" and rest == "/day-channels":
            return _send(handler, 200, service.day_config(handler.body()))
        if method == "POST" and rest == "/devices":
            return _send(handler, 200, service.register(handler.body()))
        parts = [part for part in rest.split("/") if part]
        if len(parts) >= 2 and parts[0] == "devices":
            device_id = parts[1]
            device = service.authenticate(device_id, handler.headers.get("X-Device-Secret", ""))
            if device is None:
                return _send(handler, 403, {"error": "invalid device secret"})
            tail = parts[2:]
            if not tail:
                if method == "GET":
                    return _send(handler, 200, service.status(device_id))
                if method == "DELETE":
                    service.forget(device_id)
                    return _send(handler, 200, {"forgotten": True})
            elif tail == ["plan"] and method == "PUT":
                return _send(handler, 200, service.replace_plan(device_id, handler.body().get("items", [])))
            elif tail == ["activities"] and method == "POST":
                return _send(handler, 200, service.remember_activity(device_id, handler.body()))
            elif len(tail) == 2 and tail[0] == "activities" and method == "DELETE":
                service.forget_activity(device_id, tail[1])
                return _send(handler, 200, {"forgotten": True})
        return _send(handler, 404, {"error": "not found"})
    except PlanError as error:
        return _send(handler, 400, {"error": str(error)})
    except (ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        return _send(handler, 400, {"error": str(error)})


def _send(handler, status, value):
    handler.send_json(status, value)
    return True


def _channels_from_value(raw):
    channels = {}
    if isinstance(raw, str):
        try:
            raw = json.loads(raw or "{}")
        except (TypeError, ValueError, json.JSONDecodeError):
            raw = {}
    if not isinstance(raw, dict):
        return channels
    for key, value in raw.items():
        if isinstance(value, dict):
            value = value.get("channelID") or value.get("channelId")
        if not isinstance(value, str):
            continue
        environment, separator, school_id = str(key).partition(":")
        if separator and environment in ("production", "sandbox") and school_id and value.strip():
            channels[(environment, school_id)] = value.strip()
    return channels


def _client_from_config(config):
    if not config:
        return None
    path = str(config.get("keyPath") or config.get("key_path") or "").strip()
    key_id = str(config.get("keyID") or config.get("key_id") or "").strip()
    team_id = str(config.get("teamID") or config.get("team_id") or "").strip()
    bundle_id = str(config.get("bundleID") or config.get("bundle_id") or "").strip()
    if not (path and key_id and team_id and bundle_id):
        return None
    return apns.APNsClient(apns.ES256Key.from_file(path), key_id, team_id, bundle_id)


def build_service(db, lock, environ=None, config=None):
    """Create the service from WebUI settings, with environment fallback."""
    environ = os.environ if environ is None else environ
    source = config if config is not None else {
        "keyPath": environ.get("NAPTABLE_APNS_KEY_PATH", ""),
        "keyID": environ.get("NAPTABLE_APNS_KEY_ID", ""),
        "teamID": environ.get("NAPTABLE_APNS_TEAM_ID", ""),
        "bundleID": environ.get("NAPTABLE_APNS_BUNDLE_ID", ""),
        "tickSeconds": environ.get("NAPTABLE_APNS_TICK_SECONDS", "5"),
        "channels": environ.get("NAPTABLE_APNS_CHANNELS_JSON", "{}"),
    }
    client = _client_from_config(source)
    try:
        tick = float(source.get("tickSeconds", source.get("tick_seconds", 5)) or 5)
    except (TypeError, ValueError):
        tick = 5.0
    channels = _channels_from_value(source.get("channels", source.get("channels_json", {})))
    return LiveActivityService(db, lock, client=client, tick=tick, channels=channels)


def apply_config(service, config):
    """Build and apply a persisted APNs configuration to a running service."""
    client = _client_from_config(config)
    try:
        tick = float(config.get("tickSeconds", config.get("tick_seconds", 5)) or 5)
    except (TypeError, ValueError):
        tick = 5.0
    service.reconfigure(client=client, tick=tick,
                        channels=_channels_from_value(config.get("channels", {})))

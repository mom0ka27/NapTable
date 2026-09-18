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
from datetime import datetime, timezone

try:  # `python3 server/naptable_server.py` and `import server.live_activity`
    from . import apns
except ImportError:  # pragma: no cover - depends on how the server was started
    import apns

SCHEMA = """
CREATE TABLE IF NOT EXISTS la_devices (
 device_id TEXT PRIMARY KEY, secret_hash TEXT NOT NULL, start_token TEXT NOT NULL DEFAULT '',
 environment TEXT NOT NULL DEFAULT 'production', bundle_id TEXT NOT NULL DEFAULT '',
 time_zone TEXT NOT NULL DEFAULT 'Asia/Shanghai', enabled INTEGER NOT NULL DEFAULT 1,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS la_plan (
 device_id TEXT NOT NULL, item_id TEXT NOT NULL, fire_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL, event TEXT NOT NULL, payload_json TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending', detail TEXT NOT NULL DEFAULT '',
 sent_at TEXT NOT NULL DEFAULT '', PRIMARY KEY (device_id, item_id)
);
CREATE INDEX IF NOT EXISTS la_plan_due ON la_plan (state, fire_at);
CREATE TABLE IF NOT EXISTS la_activities (
 device_id TEXT NOT NULL, activity_id TEXT NOT NULL, update_token TEXT NOT NULL,
 expires_at INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL,
 PRIMARY KEY (device_id, activity_id)
);
"""

EVENTS = ("start", "update", "end")
MAX_PLAN_ITEMS = 240
# One APNs payload is capped at 4 KB; leave room for the `aps` keys this server
# adds around the uploaded content state.
MAX_ITEM_BYTES = 3200
MAX_HORIZON = 45 * 24 * 3600
ATTRIBUTES_TYPE = "ScheduleLiveActivityAttributes"


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

    def __init__(self, db, lock, client=None, now=time.time, tick=5.0):
        self.db = db
        self.lock = lock
        self.client = client
        self.now = now
        self.tick = tick
        self._stop = threading.Event()
        self._thread = None
        with self.lock:
            self.db.executescript(SCHEMA)
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

    def _run(self):
        while not self._stop.wait(self.tick):
            try:
                self.dispatch_due()
            except Exception as error:  # a bad row must not kill the loop
                print(f"live activity dispatch failed: {error}")

    # -- devices -----------------------------------------------------------

    def register(self, value):
        """Create a device row, or refresh the one identified by its secret."""
        start_token = str(value.get("startToken", "")).strip()
        if start_token and not _token_is_hex(start_token):
            raise PlanError("startToken must be hexadecimal")
        environment = value.get("environment", "production")
        if environment not in ("production", "sandbox"):
            raise PlanError("environment must be production or sandbox")
        bundle_id = str(value.get("bundleID", ""))[:120]
        time_zone = str(value.get("timeZone", "Asia/Shanghai"))[:64]
        device_id = str(value.get("deviceID", "")).strip()
        stamp = _now_iso()
        if device_id:
            row = self._device(device_id)
            if row is None:
                raise PlanError("unknown deviceID")
            with self.lock:
                self.db.execute(
                    "UPDATE la_devices SET start_token=?,environment=?,bundle_id=?,time_zone=?,enabled=1,updated_at=? WHERE device_id=?",
                    (start_token or row["start_token"], environment, bundle_id, time_zone, stamp, device_id))
                self.db.commit()
            return {"deviceID": device_id, "pushConfigured": self.client is not None}
        device_id = secrets.token_hex(16)
        secret = secrets.token_urlsafe(32)
        with self.lock:
            self.db.execute("INSERT INTO la_devices VALUES (?,?,?,?,?,?,1,?,?)",
                            (device_id, _hash(secret), start_token, environment, bundle_id, time_zone, stamp, stamp))
            self.db.commit()
        return {"deviceID": device_id, "secret": secret, "pushConfigured": self.client is not None}

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
            self.db.execute("DELETE FROM la_plan WHERE device_id=? AND state='pending'", (device_id,))
            self.db.executemany(
                "INSERT INTO la_plan (device_id,item_id,fire_at,expires_at,event,payload_json) VALUES (?,?,?,?,?,?)"
                " ON CONFLICT(device_id,item_id) DO UPDATE SET fire_at=excluded.fire_at,expires_at=excluded.expires_at,"
                "event=excluded.event,payload_json=excluded.payload_json,state='pending',detail='',sent_at=''",
                [(device_id, i["id"], i["fire_at"], i["expires_at"], i["event"], i["payload"]) for i in normalized])
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

    def dispatch_due(self):
        """Send every item whose moment has come. Returns the results, which
        the tests read and the loop ignores."""
        now = int(self.now())
        with self.lock:
            rows = self.db.execute(
                "SELECT p.*, d.start_token, d.environment, d.enabled FROM la_plan p JOIN la_devices d"
                " ON d.device_id=p.device_id WHERE p.state='pending' AND p.fire_at <= ? ORDER BY p.fire_at LIMIT 200",
                (now,)).fetchall()
        results = []
        for row in rows:
            results.append(self._dispatch(dict(row), now))
        return results

    def _dispatch(self, row, now):
        device_id, item_id, event = row["device_id"], row["item_id"], row["event"]
        if row["expires_at"] <= now:
            # The frame this push would have shown is already over; sending it
            # would put a finished class back on the Lock Screen.
            return self._finish(device_id, item_id, "skipped", "expired before it could be sent")
        if not row["enabled"]:
            return self._finish(device_id, item_id, "skipped", "device disabled")
        if self.client is None:
            return self._finish(device_id, item_id, "skipped", "APNs is not configured")
        payload = json.loads(row["payload_json"])
        if event == "start":
            token = row["start_token"]
            if not token:
                return self._finish(device_id, item_id, "skipped", "no push-to-start token")
        else:
            activity_id, token = self._update_token(device_id)
            if not token:
                return self._finish(device_id, item_id, "skipped", "no update token for this device")
        result = self.client.push(
            token, aps_payload(event, payload, now), environment=row["environment"],
            push_type="liveactivity", priority=10, expiration=row["expires_at"],
            # One collapse id per activity keeps a late update from landing
            # after the push that supersedes it.
            collapse_id=f"{device_id[:8]}-{event}")
        if result["ok"]:
            return self._finish(device_id, item_id, "sent", "")
        reason = result.get("reason", "")
        if reason in ("BadDeviceToken", "Unregistered", "ExpiredToken", "DeviceTokenNotForTopic"):
            self._invalidate(device_id, event, token)
        return self._finish(device_id, item_id, "failed", f"{result['status']} {reason}".strip())

    def _invalidate(self, device_id, event, token):
        with self.lock:
            if event == "start":
                self.db.execute("UPDATE la_devices SET start_token='' WHERE device_id=? AND start_token=?",
                                (device_id, token))
            else:
                self.db.execute("DELETE FROM la_activities WHERE device_id=? AND update_token=?", (device_id, token))
            self.db.commit()

    def _finish(self, device_id, item_id, state, detail):
        with self.lock:
            self.db.execute("UPDATE la_plan SET state=?,detail=?,sent_at=? WHERE device_id=? AND item_id=?",
                            (state, detail, _now_iso(), device_id, item_id))
            self.db.commit()
        return {"deviceID": device_id, "itemID": item_id, "state": state, "detail": detail}


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


def build_service(db, lock, environ=None):
    """Create the service with an APNs client if the environment configures one."""
    environ = os.environ if environ is None else environ
    client = apns.APNsClient.from_environment(environ)
    tick = float(environ.get("NAPTABLE_APNS_TICK_SECONDS", "5") or 5)
    return LiveActivityService(db, lock, client=client, tick=tick)

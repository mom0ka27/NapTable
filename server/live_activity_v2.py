"""Single-process v2 scheduler. SQLite transactions arbitrate every device mutation
and submission intent. No APNs request runs inside a database transaction.
Legacy tables remain audit-only once this service is attached.
"""
from contextlib import contextmanager
from datetime import datetime, timedelta
import hashlib
import json
import os
import secrets
import threading
import fcntl
from urllib.parse import parse_qs
from zoneinfo import ZoneInfo

try:
    from .live_activity_timeline import (DAY, ProtocolError, boundaries, canonical, digest,
        identifier, normalize_schedule, public_state, validate_plan)
except ImportError:
    from live_activity_timeline import (DAY, ProtocolError, boundaries, canonical, digest,
        identifier, normalize_schedule, public_state, validate_plan)

SCHEMA = """
CREATE TABLE IF NOT EXISTS la_v2_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS la_v2_devices (
 id TEXT PRIMARY KEY, secret_hash TEXT NOT NULL, environment TEXT NOT NULL, bundle TEXT NOT NULL,
 token TEXT NOT NULL DEFAULT '', mode TEXT NOT NULL DEFAULT 'remote', mode_revision INTEGER NOT NULL DEFAULT 0,
 revoked INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0, digest TEXT NOT NULL DEFAULT '',
 snapshot TEXT, handoff TEXT, error TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS la_schedule_versions (
 bundle TEXT NOT NULL, environment TEXT NOT NULL, school TEXT NOT NULL, schedule TEXT NOT NULL,
 version TEXT NOT NULL, definition TEXT NOT NULL, broadcast_until REAL NOT NULL DEFAULT 0,
 PRIMARY KEY(bundle,environment,school,schedule,version)
);
CREATE TABLE IF NOT EXISTS la_channels (
 logical_key TEXT PRIMARY KEY, bundle TEXT NOT NULL, environment TEXT NOT NULL,
 school TEXT NOT NULL, schedule TEXT NOT NULL, version TEXT NOT NULL, final_period INTEGER NOT NULL,
 channel TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'missing', error TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS la_start_jobs (
 device TEXT NOT NULL, occurrence TEXT NOT NULL, revision INTEGER NOT NULL,
 scope TEXT NOT NULL, channel_key TEXT NOT NULL, fire_at REAL NOT NULL, expires_at REAL NOT NULL,
 payload TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
 next_attempt REAL NOT NULL DEFAULT 0, detail TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(device,occurrence)
);
CREATE INDEX IF NOT EXISTS la_start_due ON la_start_jobs(state,fire_at,next_attempt);
CREATE TABLE IF NOT EXISTS la_v2_broadcasts (
 channel_key TEXT NOT NULL, day TEXT NOT NULL, fire_at REAL NOT NULL, payload TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending', next_attempt REAL NOT NULL DEFAULT 0,
 PRIMARY KEY(channel_key,fire_at)
);
CREATE INDEX IF NOT EXISTS la_v2_broadcast_due ON la_v2_broadcasts(state,fire_at);
"""


class TokenVault:
    """Use an operator-owned Fernet key outside both the DB and release tree."""
    def __init__(self, key_path=None):
        self.cipher = None
        path = key_path or os.environ.get("NAPTABLE_LA_TOKEN_KEY_PATH")
        if path:
            from cryptography.fernet import Fernet
            with open(path, "rb") as source:
                self.cipher = Fernet(source.read().strip())

    def seal(self, token):
        if not self.cipher:
            raise ProtocolError("remote push requires NAPTABLE_LA_TOKEN_KEY_PATH", 503)
        return self.cipher.encrypt(token.encode()).decode()

    def open(self, token):
        if not self.cipher:
            raise ProtocolError("token encryption key unavailable", 503)
        return self.cipher.decrypt(token.encode()).decode()


class Service:
    def __init__(self, legacy, vault=None):
        self.owner = legacy
        self.db, self.lock, self.now = legacy.db, legacy.lock, legacy.now
        self.vault = vault or TokenVault()
        self.stop_event = threading.Event()
        self.workers = []
        with self.lock:
            path = self.db.execute("PRAGMA database_list").fetchone()[2]
        if path:
            self.process_lock = open(path + '.live-activity.lock', 'a')
            try:
                fcntl.flock(self.process_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                self.process_lock.close()
                raise RuntimeError("another Live Activity scheduler owns this database")
        with self.lock:
            self.db.executescript(SCHEMA)
            self.db.execute("INSERT OR IGNORE INTO la_v2_migrations VALUES(2,?)", (self.now(),))
            self.db.execute("UPDATE la_plan SET state='cancelled',detail='protocol v2 migration' WHERE state='pending'")
            self.db.execute("UPDATE la_devices SET enabled=0,start_token=''")
            self.db.execute("DELETE FROM la_activities")
            # A crash after intent is indistinguishable from a lost APNs response.
            self.db.execute("UPDATE la_start_jobs SET state='submissionUnknown' WHERE state='submitting'")
            self.db.execute("UPDATE la_start_jobs SET state='pending' WHERE state='claimed'")
            self.db.execute("UPDATE la_v2_broadcasts SET state='pending' WHERE state='sending'")
            self.db.commit()

    @property
    def client(self):
        return self.owner.client

    @contextmanager
    def transaction(self):
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                yield self.db
                self.db.commit()
            except BaseException:
                self.db.rollback()
                raise

    def authenticate(self, device, secret):
        with self.lock:
            row = self.db.execute("SELECT * FROM la_v2_devices WHERE id=?", (device,)).fetchone()
        if row is None or not secret or not secrets.compare_digest(row["secret_hash"], hashlib.sha256(secret.encode()).hexdigest()):
            raise ProtocolError("invalid device secret", 403)
        return row

    def register(self, value, secret):
        device = identifier(value.get("deviceID") or value.get("installationId"))
        if value.get('deviceID') and value.get('installationId') and value['deviceID'] != value['installationId']:
            raise ProtocolError("installation identity mismatch")
        environment, bundle = value.get("environment"), value.get("bundleID")
        if environment not in ("production", "sandbox"):
            raise ProtocolError("invalid environment")
        if not self.client or bundle != self.client.bundle_id:
            raise ProtocolError("APNs unavailable or Bundle ID mismatch", 503)
        token = value.get("startToken", "")
        if not isinstance(token, str) or (token and (len(token) > 200 or any(c not in '0123456789abcdefABCDEF' for c in token))):
            raise ProtocolError("invalid start token")
        encrypted = self.vault.seal(token) if token else ''
        issued = None
        with self.transaction() as db:
            existing = db.execute("SELECT * FROM la_v2_devices WHERE id=?", (device,)).fetchone()
            old = db.execute("SELECT * FROM la_devices WHERE device_id=?", (device,)).fetchone()
            credential = existing or old
            if credential:
                if not secret or not secrets.compare_digest(credential['secret_hash'], hashlib.sha256(secret.encode()).hexdigest()):
                    raise ProtocolError("invalid device secret", 403)
            if existing:
                if existing['revoked']:
                    raise ProtocolError("device revoked; use a new installation registration", 409)
                if (existing['environment'], existing['bundle']) != (environment, bundle):
                    raise ProtocolError("device App/environment is immutable", 409)
                if encrypted:
                    db.execute("UPDATE la_v2_devices SET token=? WHERE id=?", (encrypted, device))
            else:
                issued = None if old else (secret or secrets.token_urlsafe(32))
                hashed = old['secret_hash'] if old else hashlib.sha256(issued.encode()).hexdigest()
                db.execute("INSERT INTO la_v2_devices(id,secret_hash,environment,bundle,token) VALUES(?,?,?,?,?)",
                           (device, hashed, environment, bundle, encrypted))
                if old:
                    # Old submitted starts cannot be reliably mapped to new occurrences.
                    unknown = db.execute("SELECT 1 FROM la_plan WHERE device_id=? AND event='start' AND state IN ('sent','submitting','submissionUnknown') AND fire_at+28800>?", (device, self.now())).fetchone()
                    if unknown:
                        db.execute("UPDATE la_v2_devices SET error='legacyActivityDrain' WHERE id=?", (device,))
                    db.execute("UPDATE la_devices SET enabled=0,start_token='' WHERE device_id=?", (device,))
                    db.execute("UPDATE la_plan SET state='cancelled' WHERE device_id=? AND state='pending'", (device,))
        result = self.status(device)
        if issued:
            result['secret'] = issued
        return result

    def status(self, device):
        with self.lock:
            row = self.db.execute("SELECT * FROM la_v2_devices WHERE id=?", (device,)).fetchone()
            if row['error'] == 'legacyActivityDrain':
                unresolved = self.db.execute("SELECT 1 FROM la_plan WHERE device_id=? AND event='start' AND state IN ('sent','submitting','submissionUnknown') AND fire_at+28800>?", (device, self.now())).fetchone()
                if not unresolved:
                    self.db.execute("UPDATE la_v2_devices SET error='' WHERE id=?", (device,))
                    self.db.commit()
                    row = self.db.execute("SELECT * FROM la_v2_devices WHERE id=?", (device,)).fetchone()
            jobs = self.db.execute("SELECT occurrence,state,fire_at,expires_at FROM la_start_jobs WHERE device=? ORDER BY fire_at", (device,)).fetchall()
        plan = json.loads(row['snapshot']) if row['snapshot'] else {}
        return {"deviceID": device, "protocolVersion": 2, "launchMode": row['mode'], "modeRevision": row['mode_revision'],
                "planRevision": row['revision'], "revoked": bool(row['revoked']), "error": row['error'],
                "coverageStart": plan.get('coverageStart'), "coverageEndExclusive": plan.get('coverageEndExclusive'),
                "pendingCount": sum(j['state'] == 'pending' for j in jobs),
                "hasStartToken": bool(row['token']), "pushConfigured": self.client is not None,
                "history": [{"occurrenceId": j['occurrence'], "state": j['state'], "end": j['expires_at']} for j in jobs if j['state'] != 'pending']}

    @staticmethod
    def key(bundle, environment, school, schedule, version, period):
        return f"{bundle}:{environment}:{school}:{schedule}:{version}:end-period-{period}"

    def config(self, query):
        bundle, environment = query.get('bundleID'), query.get('environment')
        school, schedule = identifier(query.get('schoolID')), identifier(query.get('scheduleId', 'default'))
        if schedule != 'default':
            raise ProtocolError("unsupported scheduleId")
        if not self.client or bundle != self.client.bundle_id or environment not in ('production', 'sandbox'):
            raise ProtocolError("APNs unavailable or App/environment mismatch", 503)
        with self.transaction() as db:
            row = db.execute("SELECT s.periods_json,t.timezone FROM school_configs s JOIN school_terms t ON t.school_id=s.id WHERE s.id=? AND t.is_current=1 LIMIT 1", (school,)).fetchone()
            if row is None:
                raise ProtocolError("school has no authoritative schedule", 404)
            definition = normalize_schedule(json.loads(row['periods_json']), row['timezone'])
            version = digest(definition)
            identity = (bundle, environment, school, schedule, version)
            now = self.now()
            if db.execute("SELECT 1 FROM la_channels WHERE bundle=? AND environment=? AND school=? AND schedule=? AND version=? AND state='retiring'", identity).fetchone():
                raise ProtocolError("version channels are being reclaimed; retry shortly", 503)
            db.execute("INSERT INTO la_schedule_versions VALUES(?,?,?,?,?,?,?) ON CONFLICT DO UPDATE SET broadcast_until=MAX(broadcast_until,excluded.broadcast_until)", (*identity, canonical(definition), now + 8 * DAY))
            channels = {}
            for period in definition['periods']:
                key = self.key(*identity, period['number'])
                db.execute("INSERT OR IGNORE INTO la_channels(logical_key,bundle,environment,school,schedule,version,final_period) VALUES(?,?,?,?,?,?,?)", (key, *identity, period['number']))
                channel = db.execute("SELECT channel,state FROM la_channels WHERE logical_key=?", (key,)).fetchone()
                if channel['state'] == 'ready':
                    channels[str(period['number'])] = channel['channel']
        return {"protocolVersion": 2, "schoolID": school, "scheduleId": schedule, "scheduleVersion": version,
                **definition, "channels": channels, "status": 'ready' if len(channels) == len(definition['periods']) else 'missingChannels',
                "issuedAt": now, "createBefore": now + 7 * DAY, "broadcastUntil": now + 8 * DAY}

    def replace_plan(self, device, plan):
        if not isinstance(plan, dict):
            raise ProtocolError("plan must be an object")
        with self.transaction() as db:
            row = db.execute("SELECT * FROM la_v2_devices WHERE id=?", (device,)).fetchone()
            if row['revoked'] or row['mode'] != 'remote':
                raise ProtocolError("device no longer accepts remote plans", 409)
            version = db.execute("SELECT * FROM la_schedule_versions WHERE bundle=? AND environment=? AND school=? AND schedule=? AND version=?",
                (row['bundle'], row['environment'], plan.get('schoolID'), plan.get('scheduleId'), plan.get('scheduleVersion'))).fetchone()
            if version is None:
                raise ProtocolError("unknown schedule version", 409)
            events = validate_plan(plan, json.loads(version['definition']), self.now())
            hashed = digest(plan)
            if plan['planRevision'] < row['revision'] or (plan['planRevision'] == row['revision'] and hashed != row['digest']):
                raise ProtocolError("plan revision conflict", 409)
            if plan['planRevision'] != row['revision']:
                db.execute("UPDATE la_v2_devices SET revision=?,digest=?,snapshot=? WHERE id=?", (plan['planRevision'], hashed, canonical(plan), device))
                db.execute("UPDATE la_start_jobs SET state='cancelled' WHERE device=? AND state IN ('pending','claimed')", (device,))
                self._materialize(db, row, plan, events)
        return self.status(device)

    def _materialize(self, db, device, plan, events):
        now = self.now()
        identity = (device['bundle'], device['environment'], plan['schoolID'], plan['scheduleId'], plan['scheduleVersion'])
        if db.execute("SELECT 1 FROM la_channels WHERE bundle=? AND environment=? AND school=? AND schedule=? AND version=? AND state='retiring'", identity).fetchone():
            raise ProtocolError("version channels are being reclaimed; retry shortly", 503)
        for event in events:
            if event['fireAt'] > now + 2 * DAY or event['end'] <= now:
                continue
            # Neither revision replacement nor token rotation can erase a submission.
            key = self.key(device['bundle'], device['environment'], plan['schoolID'], plan['scheduleId'], plan['scheduleVersion'], event['endPeriod'])
            db.execute("INSERT OR IGNORE INTO la_channels(logical_key,bundle,environment,school,schedule,version,final_period) VALUES(?,?,?,?,?,?,?)", (key, device['bundle'], device['environment'], plan['schoolID'], plan['scheduleId'], plan['scheduleVersion'], event['endPeriod']))
            payload = {"aps": {"timestamp": int(now), "event": "start", "attributes-type": "ScheduleLiveActivityAttributes",
                "attributes": {"semester": "", "week": 0, "dateKey": event['dateKey'], "protocolVersion": 2,
                    "scheduleScope": plan['scheduleScope'], "occurrenceId": event['occurrenceId'], "scheduleVersion": plan['scheduleVersion'],
                    "reservationStart": event['start'] - 978307200, "reservationEnd": event['end'] - 978307200, "reminderDate": event['fireAt'] - 978307200},
                "content-state": public_state(event['dateKey'], event['startPeriod'], 'upcoming', event['fireAt']),
                "stale-date": event['end'], "alert": {"title": "课程提醒", "body": "即将上课"}}}
            db.execute("INSERT INTO la_start_jobs(device,occurrence,revision,scope,channel_key,fire_at,expires_at,payload) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(device,occurrence) DO UPDATE SET revision=excluded.revision,scope=excluded.scope,channel_key=excluded.channel_key,fire_at=excluded.fire_at,expires_at=excluded.expires_at,payload=excluded.payload,state='pending' WHERE la_start_jobs.state IN ('pending','claimed','cancelled')",
                (device['id'], event['occurrenceId'], plan['planRevision'], plan['scheduleScope'], key, event['fireAt'], event['end'], canonical(payload)))
            # A changed segment must not overlap a start already submitted for its predecessor.
            for predecessor in event['supersedes']:
                old = db.execute("SELECT state FROM la_start_jobs WHERE device=? AND occurrence=?", (device['id'], predecessor)).fetchone()
                if old and old['state'] in ('submitting', 'submitted', 'submissionUnknown', 'localTaken'):
                    db.execute("UPDATE la_start_jobs SET state='superseded' WHERE device=? AND occurrence=? AND state='pending'", (device['id'], event['occurrenceId']))
        if not any(event['end'] > now for event in events):
            return
        db.execute("UPDATE la_schedule_versions SET broadcast_until=MAX(broadcast_until,?) WHERE bundle=? AND environment=? AND school=? AND schedule=? AND version=?",
                   (now + 8 * DAY, device['bundle'], device['environment'], plan['schoolID'], plan['scheduleId'], plan['scheduleVersion']))

    def handoff(self, device):
        with self.transaction() as db:
            row = db.execute("SELECT * FROM la_v2_devices WHERE id=?", (device,)).fetchone()
            if row['revoked']:
                raise ProtocolError("device revoked", 409)
            db.execute("UPDATE la_v2_devices SET mode='local',mode_revision=mode_revision+1 WHERE id=? AND mode!='local'", (device,))
            db.execute("UPDATE la_start_jobs SET state='localTaken' WHERE device=? AND state IN ('pending','claimed')", (device,))
        return self.status(device)

    def recovery(self, device, value):
        occurrence = identifier(value.get('occurrenceId'))
        with self.transaction() as db:
            row = db.execute("SELECT revoked FROM la_v2_devices WHERE id=?", (device,)).fetchone()
            if row['revoked']:
                raise ProtocolError("device revoked", 409)
            changed = db.execute("UPDATE la_start_jobs SET state='localTaken' WHERE device=? AND occurrence=? AND state IN ('pending','claimed')", (device, occurrence)).rowcount
        return {"mayStart": bool(changed), "occurrenceId": occurrence}

    def forget(self, device):
        with self.transaction() as db:
            db.execute("UPDATE la_v2_devices SET revoked=1,token='',snapshot=NULL WHERE id=?", (device,))
            db.execute("UPDATE la_start_jobs SET state='cancelled' WHERE device=? AND state IN ('pending','claimed')", (device,))
        return {"forgotten": True}

    def materialize(self):
        with self.transaction() as db:
            rows = db.execute("SELECT * FROM la_v2_devices WHERE revoked=0 AND mode='remote' AND snapshot IS NOT NULL").fetchall()
            for row in rows:
                plan = json.loads(row['snapshot'])
                version = db.execute("SELECT definition FROM la_schedule_versions WHERE bundle=? AND environment=? AND school=? AND schedule=? AND version=?", (row['bundle'], row['environment'], plan['schoolID'], plan['scheduleId'], plan['scheduleVersion'])).fetchone()
                # Validate against the original accepted coverage, not today's clock.
                events = validate_plan(plan, json.loads(version[0]), plan['coverageStart'])
                self._materialize(db, row, plan, events)

    def validate_client(self, client):
        if client is None:
            return
        with self.lock:
            outstanding = self.db.execute("SELECT 1 FROM la_schedule_versions WHERE bundle!=? AND broadcast_until>? LIMIT 1", (client.bundle_id, self.now())).fetchone()
        if outstanding:
            raise ProtocolError("cannot change Bundle ID while broadcast promises remain", 409)

    def maintain_channels(self):
        if not self.client:
            return
        with self.lock:
            rows = self.db.execute("SELECT c.* FROM la_channels c JOIN la_schedule_versions v USING(bundle,environment,school,schedule,version) WHERE c.state='missing' AND v.broadcast_until>? AND c.bundle=?", (self.now(), self.client.bundle_id)).fetchall()
        for row in rows:
            try:
                channel = self.client.create_channel(environment=row['environment'])
                with self.transaction() as db:
                    db.execute("UPDATE la_channels SET channel=?,state='ready',error='' WHERE logical_key=?", (channel, row['logical_key']))
            except Exception as error:
                with self.transaction() as db:
                    db.execute("UPDATE la_channels SET error=? WHERE logical_key=?", (str(error)[:200], row['logical_key']))
        # Claim reclamation in the same write boundary as mapping issuance.
        # Config requests encountering retiring rows fail without signing a lease.
        with self.transaction() as db:
            expired = db.execute("SELECT c.* FROM la_channels c JOIN la_schedule_versions v USING(bundle,environment,school,schedule,version) WHERE v.broadcast_until<=? AND c.bundle=?", (self.now(), self.client.bundle_id)).fetchall()
            for row in expired:
                db.execute("UPDATE la_channels SET state='retiring' WHERE logical_key=?", (row['logical_key'],))
        for row in expired:
            try:
                if row['channel']:
                    self.client.delete_channel(row['channel'], environment=row['environment'])
                with self.transaction() as db:
                    db.execute("DELETE FROM la_v2_broadcasts WHERE channel_key=?", (row['logical_key'],))
                    db.execute("DELETE FROM la_channels WHERE logical_key=? AND state='retiring'", (row['logical_key'],))
            except Exception as error:
                with self.transaction() as db:
                    db.execute("UPDATE la_channels SET error=? WHERE logical_key=?", (str(error)[:200], row['logical_key']))

    def health(self):
        with self.lock:
            rows = self.db.execute("SELECT school,environment,version,final_period,state,error FROM la_channels ORDER BY school,environment,version,final_period").fetchall()
            starts = dict(self.db.execute("SELECT state,COUNT(*) FROM la_start_jobs GROUP BY state").fetchall())
            broadcasts = dict(self.db.execute("SELECT state,COUNT(*) FROM la_v2_broadcasts GROUP BY state").fetchall())
        return {"protocolVersion": 2, "channels": [dict(row) for row in rows], "starts": starts, "broadcasts": broadcasts}

    def drain_legacy(self):
        with self.lock:
            switched = self.db.execute("SELECT applied_at FROM la_v2_migrations WHERE version=2").fetchone()[0]
        if not self.client:
            return
        if self.now() > switched + 3 * DAY:
            with self.lock:
                rows = self.db.execute("SELECT * FROM la_day_channels WHERE bundle_id=?", (self.client.bundle_id,)).fetchall()
            for row in rows:
                try:
                    self.client.delete_channel(row['channel_id'], environment=row['environment'])
                    with self.transaction() as db:
                        db.execute("DELETE FROM la_day_channels WHERE channel_id=?", (row['channel_id'],))
                        db.execute("DELETE FROM la_broadcast_plan WHERE channel_id=?", (row['channel_id'],))
                except Exception:
                    # Keep provenance for the next cleanup attempt.
                    continue
            return
        # Existing two-day reservations still need their original date channels.
        # Never provision additional legacy channels or dispatch legacy starts.
        self.owner._ensure_broadcast_plan(int(self.now()))
        with self.lock:
            rows = self.db.execute("SELECT * FROM la_broadcast_plan WHERE state='pending' AND fire_at<=? AND next_attempt_at<=? ORDER BY fire_at DESC LIMIT 200", (self.now(), self.now())).fetchall()
        for row in rows:
            self.owner._dispatch_broadcast(dict(row), int(self.now()))

    def dispatch_starts(self):
        if not self.client:
            return
        now = self.now()
        with self.lock:
            candidates = self.db.execute("SELECT device,occurrence FROM la_start_jobs WHERE state='pending' AND fire_at<=? AND next_attempt<=? ORDER BY fire_at LIMIT 100", (now, now)).fetchall()
        for candidate in candidates:
            with self.transaction() as db:
                row = db.execute("SELECT j.*,d.token,d.environment,d.bundle,d.mode,d.revoked,c.channel,c.state AS channel_state FROM la_start_jobs j JOIN la_v2_devices d ON j.device=d.id JOIN la_channels c ON j.channel_key=c.logical_key WHERE j.device=? AND j.occurrence=? AND j.state='pending'", tuple(candidate)).fetchone()
                if row is None:
                    continue
                if row['expires_at'] <= now or row['revoked'] or row['mode'] != 'remote':
                    db.execute("UPDATE la_start_jobs SET state='expired' WHERE device=? AND occurrence=?", tuple(candidate))
                    continue
                if row['bundle'] != self.client.bundle_id or not row['token'] or row['channel_state'] != 'ready':
                    continue
                try:
                    token = self.vault.open(row['token'])
                except Exception:
                    db.execute("UPDATE la_v2_devices SET error='tokenKeyUnavailable' WHERE id=?", (row['device'],))
                    continue
                db.execute("UPDATE la_start_jobs SET state='submitting',attempts=attempts+1 WHERE device=? AND occurrence=?", tuple(candidate))
            payload = json.loads(row['payload'])
            payload['aps']['timestamp'] = int(now)
            payload['aps']['input-push-channel'] = row['channel']
            payload['aps']['attributes']['broadcastChannel'] = row['channel']
            try:
                result = self.client.push(token, payload, environment=row['environment'], expiration=0, topic=row['bundle'] + '.push-type.liveactivity')
            except Exception:
                result = {"ok": False, "status": 0, "certainty": "unknown", "reason": "transport failure"}
            status = result.get('status', 0)
            state = 'terminal'
            if result.get('ok') and status == 200:
                state = 'submitted'
            elif result.get('certainty') == 'unknown' or (not status and result.get('certainty') != 'notSent'):
                state = 'submissionUnknown'
            elif result.get('certainty') == 'notSent' or status in (408, 429) or 500 <= status < 600:
                state = 'pending'
            with self.transaction() as db:
                current = db.execute("SELECT mode,revoked FROM la_v2_devices WHERE id=?", (row['device'],)).fetchone()
                if state == 'pending' and (current['mode'] != 'remote' or current['revoked']):
                    state = 'cancelled'
                db.execute("UPDATE la_start_jobs SET state=?,next_attempt=?,detail=? WHERE device=? AND occurrence=? AND state='submitting'",
                    (state, now + min(300, 5 * 2 ** min(row['attempts'], 6)), result.get('reason', '')[:200], row['device'], row['occurrence']))

    def dispatch_broadcasts(self):
        if not self.client:
            return
        now = self.now()
        with self.transaction() as db:
            versions = db.execute("SELECT c.*,v.definition,v.broadcast_until FROM la_channels c JOIN la_schedule_versions v USING(bundle,environment,school,schedule,version) WHERE c.state='ready' AND v.broadcast_until>? AND c.bundle=?", (now, self.client.bundle_id)).fetchall()
            for row in versions:
                schedule = json.loads(row['definition'])
                today = datetime.fromtimestamp(now, ZoneInfo(schedule['timeZone'])).date()
                for day in (today, today + timedelta(days=1)):
                    for stamp, payload in boundaries(schedule, day.isoformat(), row['final_period']):
                        if now - 60 <= stamp <= row['broadcast_until']:
                            db.execute("INSERT OR IGNORE INTO la_v2_broadcasts(channel_key,day,fire_at,payload) VALUES(?,?,?,?)", (row['logical_key'], day.isoformat(), stamp, canonical(payload)))
            db.execute("UPDATE la_v2_broadcasts SET state='expired' WHERE state='pending' AND fire_at<?", (now - 60,))
            rows = db.execute("SELECT b.*,c.channel,c.environment,c.bundle,v.definition FROM la_v2_broadcasts b JOIN la_channels c ON b.channel_key=c.logical_key JOIN la_schedule_versions v ON c.bundle=v.bundle AND c.environment=v.environment AND c.school=v.school AND c.schedule=v.schedule AND c.version=v.version WHERE b.state='pending' AND b.fire_at<=? AND b.next_attempt<=? AND c.bundle=? ORDER BY b.fire_at DESC LIMIT 200", (now, now, self.client.bundle_id)).fetchall()
        for row in rows:
            today = datetime.fromtimestamp(now, ZoneInfo(json.loads(row['definition'])['timeZone'])).date().isoformat()
            if row['day'] != today:
                with self.transaction() as db:
                    db.execute("UPDATE la_v2_broadcasts SET state='expired' WHERE channel_key=? AND fire_at=?", (row['channel_key'], row['fire_at']))
                continue
            with self.transaction() as db:
                newer = db.execute("SELECT 1 FROM la_v2_broadcasts WHERE channel_key=? AND day=? AND fire_at>? AND (state IN ('sent','sending') OR next_attempt>0)", (row['channel_key'], row['day'], row['fire_at'])).fetchone()
                if newer:
                    db.execute("UPDATE la_v2_broadcasts SET state='superseded' WHERE channel_key=? AND fire_at=?", (row['channel_key'], row['fire_at']))
                    continue
                changed = db.execute("UPDATE la_v2_broadcasts SET state='sending' WHERE channel_key=? AND fire_at=? AND state='pending'", (row['channel_key'], row['fire_at'])).rowcount
            if not changed:
                continue
            try:
                result = self.client.broadcast(row['channel'], json.loads(row['payload']), environment=row['environment'], expiration=0, topic=row['bundle'])
            except Exception:
                result = {'ok': False}
            with self.transaction() as db:
                db.execute("UPDATE la_channels SET error=? WHERE logical_key=?", ('' if result.get('ok') else str(result.get('reason') or 'broadcast failed')[:200], row['channel_key']))
                if result.get('status') == 410 or result.get('reason') in ('ChannelNotFound', 'BadChannelId', 'BadChannelID'):
                    db.execute("UPDATE la_channels SET state='missing',channel='' WHERE logical_key=?", (row['channel_key'],))
                db.execute("UPDATE la_v2_broadcasts SET state=?,next_attempt=? WHERE channel_key=? AND fire_at=?", ('sent' if result.get('ok') else 'pending', now + 5, row['channel_key'], row['fire_at']))

    def start(self):
        if self.workers:
            return
        for name, action, delay in [('legacy-drain', self.drain_legacy, 5), ('channels' , self.maintain_channels, 60), ('materialize', self.materialize, 60), ('starts', self.dispatch_starts, 1), ('broadcasts', self.dispatch_broadcasts, 1)]:
            def run(action=action, delay=delay):
                while not self.stop_event.is_set():
                    try:
                        action()
                    except Exception as error:
                        print(f'live activity v2 worker: {type(error).__name__}: {error}')
                    self.stop_event.wait(delay)
            worker = threading.Thread(target=run, name='live-activity-' + name, daemon=True)
            self.workers.append(worker)
            worker.start()

    def stop(self):
        self.stop_event.set()
        for worker in self.workers:
            worker.join(timeout=5)
        if hasattr(self, "process_lock") and not any(worker.is_alive() for worker in self.workers):
            self.process_lock.close()


def handle(handler, service, method, path):
    prefix = '/v2/live-activity'
    if not path.startswith(prefix):
        return False
    def body():
        value = handler.body()
        if not isinstance(value, dict):
            raise ProtocolError("request body must be an object")
        return value
    try:
        rest = path[len(prefix):]
        if rest == '/devices' and method == 'POST':
            result = service.register(body(), handler.headers.get('X-Device-Secret', ''))
        elif rest == '/broadcast-config' and method == 'GET':
            query = parse_qs(handler.path.partition('?')[2])
            result = service.config({key: values[-1] for key, values in query.items()})
        else:
            parts = rest.strip('/').split('/')
            if len(parts) < 2 or parts[0] != 'devices':
                raise ProtocolError('not found', 404)
            device = identifier(parts[1])
            service.authenticate(device, handler.headers.get('X-Device-Secret', ''))
            tail = '/'.join(parts[2:])
            if not tail and method == 'GET':
                result = service.status(device)
            elif not tail and method == 'DELETE':
                result = service.forget(device)
            elif tail == 'plan' and method == 'PUT':
                result = service.replace_plan(device, body())
            elif tail == 'local-handoff' and method == 'POST':
                result = service.handoff(device)
            elif tail == 'foreground-recovery' and method == 'POST':
                result = service.recovery(device, body())
            else:
                raise ProtocolError('not found', 404)
        handler.send_json(200, result)
    except ProtocolError as error:
        handler.send_json(error.status, {'error': str(error)})
    except (ValueError, KeyError, TypeError) as error:
        handler.send_json(400, {'error': str(error)})
    return True

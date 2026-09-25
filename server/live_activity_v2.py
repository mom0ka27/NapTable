"""Single-process v2 scheduler.

The schedule lives in memory: today's and tomorrow's occurrences of every
device, rebuilt from the stored timetable on start, on upload, at UTC+8
midnight and when a followed share changes. The database keeps only what
cannot be recomputed: devices, timetables, activity tokens, channels, and
`la_starts`, the ledger of occurrences someone has taken on (the phone's own
reservation, or a start this server submitted). An occurrence without a
ledger row is pending. SQLite transactions arbitrate every submission intent;
no APNs request runs inside one.
"""
from contextlib import contextmanager
from datetime import date, datetime, timedelta
import hashlib
import heapq
import json
import os
import secrets
import threading
import fcntl
from typing import NamedTuple
from urllib.parse import parse_qs
from zoneinfo import ZoneInfo

try:
    from .live_activity_timeline import DAY, ProtocolError, boundaries, canonical, digest, identifier, normalize_schedule, public_state
    from . import live_activity_schedule as schedule_engine
except ImportError:
    from live_activity_timeline import DAY, ProtocolError, boundaries, canonical, digest, identifier, normalize_schedule, public_state
    import live_activity_schedule as schedule_engine

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
CREATE TABLE IF NOT EXISTS la_starts (
 device TEXT NOT NULL, occurrence TEXT NOT NULL, day TEXT NOT NULL, state TEXT NOT NULL,
 fire_at REAL NOT NULL, expires_at REAL NOT NULL, detail TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(device, occurrence)
);
CREATE INDEX IF NOT EXISTS la_starts_expiry ON la_starts(expires_at);
CREATE TABLE IF NOT EXISTS la_v2_broadcasts (
 channel_key TEXT NOT NULL, day TEXT NOT NULL, fire_at REAL NOT NULL, payload TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending', next_attempt REAL NOT NULL DEFAULT 0,
 PRIMARY KEY(channel_key,fire_at)
);
CREATE INDEX IF NOT EXISTS la_v2_broadcast_due ON la_v2_broadcasts(state,fire_at);
CREATE TABLE IF NOT EXISTS la_activity_tokens (
 device TEXT NOT NULL, occurrence TEXT NOT NULL, token TEXT NOT NULL,
 day TEXT NOT NULL, end_at REAL NOT NULL, updated_at REAL NOT NULL,
 PRIMARY KEY(device, occurrence)
);
CREATE TABLE IF NOT EXISTS la_timetables (
 device TEXT PRIMARY KEY, revision INTEGER NOT NULL, digest TEXT NOT NULL, body TEXT NOT NULL,
 push_mode TEXT NOT NULL, school TEXT NOT NULL DEFAULT '', version TEXT NOT NULL DEFAULT '',
 follow_scope TEXT NOT NULL DEFAULT '', follow_seen TEXT NOT NULL DEFAULT '', updated_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS la_timetable_follow ON la_timetables(follow_scope);
CREATE TABLE IF NOT EXISTS la_v2_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

# Ledger states: `local` is the phone's own reservation. Every other state is a
# start this server submitted (`submitting`, `submitted`, `submissionUnknown`,
# `terminal`, `cancelled`) or, carried over from the client-built plan, a
# reservation made under it (`localTaken`); none of those is ever sent again.
# The states of the former job table that migration 6 carries into the ledger:
CARRIED = ('local', 'submitting', 'submitted', 'submissionUnknown', 'terminal', 'localTaken')


class Occurrence(NamedTuple):
    """What the schedule keeps of one occurrence; its push is rebuilt from the timetable when sent."""
    id: str
    fire_at: float
    end: float
    refresh: tuple
    alerts: tuple


class Redraws:
    """A token-mode activity's refreshes: its refresh instants, then its end.
    `sent` is the last instant dealt with (sent, failed or passed)."""
    __slots__ = ('day', 'stamps', 'alerts', 'sent', 'attempts', 'retry_at')

    def __init__(self, day, stamps, alerts, sent=0):
        self.day, self.stamps, self.alerts, self.sent = day, stamps, alerts, sent
        self.attempts, self.retry_at = 0, 0

    def unsent(self):
        return [stamp for stamp in self.stamps if stamp > self.sent]


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
        self.plans = {}      # device → {date: (Occurrence, ...)}: today and tomorrow, UTC+8
        self.due = []        # heap of (instant, device, occurrence) to try a start at
        self.retries = {}    # (device, occurrence) → (attempts, next attempt) of a start
        self.redraws = {}    # (device, occurrence) → Redraws of a token-mode activity
        self.redraw_due = [] # heap of (instant, device, occurrence) to try a refresh at
        self.built = None    # the UTC+8 day every plan was last built on
        self._after = []     # memory changes waiting for the transaction to commit
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
            self.db.execute("INSERT OR IGNORE INTO la_v2_migrations VALUES(3,?)", (self.now(),))
            self._migrate_ledger()
            self.db.execute("UPDATE la_plan SET state='cancelled',detail='protocol v2 migration' WHERE state='pending'")
            self.db.execute("UPDATE la_devices SET enabled=0,start_token=''")
            self.db.execute("DELETE FROM la_activities")
            # A crash after intent is indistinguishable from a lost APNs response.
            self.db.execute("UPDATE la_starts SET state='submissionUnknown' WHERE state='submitting'")
            self.db.execute("UPDATE la_v2_broadcasts SET state='pending' WHERE state='sending'")
            self.db.commit()
        self.load()

    def _migrate_ledger(self):
        """Migration 6: the schedule moves to memory. Starts already taken on
        carry over to the ledger; pending ones and queued refreshes are rebuilt
        from the timetables on load."""
        tables = {row[0] for row in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if 'la_start_jobs' in tables:
            columns = {row[1] for row in self.db.execute("PRAGMA table_info(la_start_jobs)")}
            marks = ','.join('?' * len(CARRIED))
            for row in self.db.execute(f"SELECT * FROM la_start_jobs WHERE state IN ({marks}) AND expires_at>?", (*CARRIED, self.now() - DAY)).fetchall():
                day = row['day'] if 'day' in columns and row['day'] else schedule_engine.today(row['fire_at']).isoformat()
                self.db.execute("INSERT OR IGNORE INTO la_starts VALUES(?,?,?,?,?,?,?)",
                                (row['device'], row['occurrence'], day, row['state'], row['fire_at'], row['expires_at'], row['detail']))
            self.db.execute("DROP TABLE la_start_jobs")
        self.db.execute("DROP TABLE IF EXISTS la_token_updates")
        self.db.execute("INSERT OR IGNORE INTO la_v2_migrations VALUES(6,?)", (self.now(),))

    def load(self):
        """Build every device's plan and queue the refreshes of activities still
        running. Runs before any worker starts, so nothing due is missed."""
        with self.lock:
            devices = [row[0] for row in self.db.execute("SELECT t.device FROM la_timetables t JOIN la_v2_devices d ON d.id=t.device WHERE d.revoked=0")]
        for device in devices:
            with self.transaction() as db:
                self._rebuild(db, device)
        with self.lock:
            now = self.now()
            for row in self.db.execute("SELECT device,occurrence,day,end_at FROM la_activity_tokens WHERE end_at>?", (now - 60,)).fetchall():
                found = self._find(row['device'], row['occurrence'])
                # An activity whose course changed after it started: only its end is known.
                item = found[1] if found else Occurrence(row['occurrence'], 0, row['end_at'], (), ())
                self._track(row['device'], row['occurrence'], row['day'], item)
            self.built = schedule_engine.today(now)

    @property
    def client(self):
        return self.owner.client

    @contextmanager
    def transaction(self):
        """One write. Memory changes staged in `self._after` apply once it commits,
        still under the lock, and are dropped if it rolls back."""
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            self._after = []
            try:
                yield self.db
                self.db.commit()
            except BaseException:
                self.db.rollback()
                self._after = []
                raise
            after, self._after = self._after, []
            for apply in after:
                apply()

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
        now = self.now()
        with self.lock:
            row = self.db.execute("SELECT * FROM la_v2_devices WHERE id=?", (device,)).fetchone()
            if row['error'] == 'legacyActivityDrain':
                unresolved = self.db.execute("SELECT 1 FROM la_plan WHERE device_id=? AND event='start' AND state IN ('sent','submitting','submissionUnknown') AND fire_at+28800>?", (device, now)).fetchone()
                if not unresolved:
                    self.db.execute("UPDATE la_v2_devices SET error='' WHERE id=?", (device,))
                    self.db.commit()
                    row = self.db.execute("SELECT * FROM la_v2_devices WHERE id=?", (device,)).fetchone()
            history = self.db.execute("SELECT occurrence,state,expires_at FROM la_starts WHERE device=? ORDER BY fire_at", (device,)).fetchall()
            timetable = self.db.execute("SELECT revision,push_mode,follow_scope FROM la_timetables WHERE device=?", (device,)).fetchone()
            pending = len(self._pending(device, {item['occurrence'] for item in history}, now))
        return {"deviceID": device, "protocolVersion": 2, "revoked": bool(row['revoked']), "error": row['error'],
                "pendingCount": pending, "hasStartToken": bool(row['token']), "pushConfigured": self.client is not None,
                "history": [{"occurrenceId": item['occurrence'], "state": item['state'], "end": item['expires_at']} for item in history],
                "timetableRevision": timetable['revision'] if timetable else 0,
                "pushMode": timetable['push_mode'] if timetable else None, "following": bool(timetable and timetable['follow_scope'])}

    @staticmethod
    def key(bundle, environment, school, schedule, version, period):
        return f"{bundle}:{environment}:{school}:{schedule}:{version}:end-period-{period}"


    def forget(self, device):
        with self.transaction() as db:
            db.execute("UPDATE la_v2_devices SET revoked=1,token='',snapshot=NULL WHERE id=?", (device,))
            db.execute("DELETE FROM la_timetables WHERE device=?", (device,))
            db.execute("DELETE FROM la_activity_tokens WHERE device=?", (device,))
            self._after.append(lambda: self._drop(device))
        return {"forgotten": True}

    def _drop(self, device):
        self.plans.pop(device, None)
        for key in [key for key in self.redraws if key[0] == device]:
            del self.redraws[key]

    def forget_activity(self, device, occurrence):
        occurrence = identifier(occurrence)
        with self.transaction() as db:
            db.execute("DELETE FROM la_activity_tokens WHERE device=? AND occurrence=?", (device, occurrence))
            self._after.append(lambda: self.redraws.pop((device, occurrence), None))
        return {"occurrenceId": occurrence, "pending": 0}

    # MARK: Server-built schedule
    #
    # The device uploads its timetable once; `self.plans` keeps today and
    # tomorrow (UTC+8) in memory. Upload, the midnight run and a followed share
    # changing each rebuild those two days and swap the result in.

    def _share(self, db, scope=None, code=None):
        if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='shares'").fetchone():
            return None
        if code is not None:
            return db.execute("SELECT * FROM shares WHERE code=? AND revoked=0", (code.upper(),)).fetchone()
        return db.execute("SELECT * FROM shares WHERE schedule_scope=? AND revoked=0 ORDER BY created_at DESC LIMIT 1", (scope,)).fetchone()

    @staticmethod
    def _parse_timetable(body):
        """The fields the schedule needs, checked; anything else is ignored and never stored."""
        if not isinstance(body, dict):
            raise ProtocolError("timetable must be an object")
        revision = body.get("revision")
        if type(revision) is not int or not 1 <= revision < 2**53:
            raise ProtocolError("invalid revision")
        _, own = schedule_engine.own_timetable(body.get("own"))
        settings = body.get("settings")
        if not isinstance(settings, dict) or settings.get("leadMinutes") not in schedule_engine.LEADS:
            raise ProtocolError("leadMinutes must be 15, 30 or 60")
        kept = {"leadMinutes": settings["leadMinutes"], "perPeriod": settings.get("perPeriod", False)}
        if not isinstance(kept["perPeriod"], bool):
            raise ProtocolError("perPeriod must be a boolean")
        if settings.get("sharedLeadMinutes") is not None:
            if settings["sharedLeadMinutes"] not in schedule_engine.LEADS:
                raise ProtocolError("sharedLeadMinutes must be 15, 30 or 60")
            kept["sharedLeadMinutes"] = settings["sharedLeadMinutes"]
        normalized = {"revision": revision, "own": own, "settings": kept, "conflicts": {}}
        follow = body.get("follow")
        if follow is not None:
            code = follow.get("share") if isinstance(follow, dict) else None
            if not isinstance(code, str) or not 1 <= len(code) <= 32:
                raise ProtocolError("follow needs a share code")
            normalized["follow"] = {"share": code.upper()}
        conflicts = body.get("conflicts", {})
        if not isinstance(conflicts, dict) or len(conflicts) > 2000:
            raise ProtocolError("invalid conflicts")
        for key, value in conflicts.items():
            if isinstance(key, str) and len(key) <= 20 and isinstance(value, str) and len(value) <= 160:
                normalized["conflicts"][key] = value
        return normalized

    def _tables(self, db, row):
        """(own table, share table, share texts, share row) of a stored timetable."""
        body = json.loads(row['body'])
        own = schedule_engine.own_table(body['own'])
        share = texts = None
        record = self._share(db, scope=row['follow_scope']) if row['follow_scope'] else None
        if record is not None:
            share, texts = schedule_engine.share_table(record)
        return body, own, share, texts or {}, record

    def _channel_version(self, db, device, own_body):
        """The school's current version when the own timetable runs on its bells:
        only then can a channel broadcast drive the activity."""
        school = own_body.get("schoolID")
        if not school or not self.client:
            return None
        row = db.execute("SELECT s.periods_json,t.timezone FROM school_configs s JOIN school_terms t ON t.school_id=s.id WHERE s.id=? AND t.is_current=1 LIMIT 1", (school,)).fetchone() \
            if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='school_configs'").fetchone() else None
        if row is None:
            return None
        try:
            definition = normalize_schedule(json.loads(row['periods_json']), row['timezone'])
        except ProtocolError:
            return None
        if [(period['start'], period['end']) for period in definition['periods']] != [(p['start'], p['end']) for p in own_body['periods']]:
            return None
        version = digest(definition)
        identity = (device['bundle'], device['environment'], school, 'default', version)
        if db.execute("SELECT 1 FROM la_channels WHERE bundle=? AND environment=? AND school=? AND schedule=? AND version=? AND state='retiring'", identity).fetchone():
            return None
        db.execute("INSERT INTO la_schedule_versions VALUES(?,?,?,?,?,?,?) ON CONFLICT DO UPDATE SET broadcast_until=MAX(broadcast_until,excluded.broadcast_until)",
                   (*identity, canonical(definition), self.now() + 8 * DAY))
        for period in definition['periods']:
            db.execute("INSERT OR IGNORE INTO la_channels(logical_key,bundle,environment,school,schedule,version,final_period) VALUES(?,?,?,?,?,?,?)",
                       (self.key(*identity, period['number']), *identity, period['number']))
        return school, version


    def put_timetable(self, device, body):
        body = self._parse_timetable(body)
        revision, follow = body['revision'], body.get('follow')
        hashed = digest(body)
        now = self.now()
        with self.transaction() as db:
            row = db.execute("SELECT * FROM la_v2_devices WHERE id=?", (device,)).fetchone()
            if row['revoked']:
                raise ProtocolError("device revoked", 409)
            stored = db.execute("SELECT * FROM la_timetables WHERE device=?", (device,)).fetchone()
            if stored and (revision < stored['revision'] or (revision == stored['revision'] and hashed != stored['digest'])):
                raise ProtocolError("timetable revision conflict", 409)
            if not stored or revision != stored['revision']:
                scope = seen = ''
                if follow is not None:
                    share = self._share(db, code=follow['share'])
                    if share is None:
                        raise ProtocolError("followed share not found", 404)
                    scope, seen = share['schedule_scope'], share['updated_at']
                channel = None if follow is not None else self._channel_version(db, row, body['own'])
                db.execute("INSERT INTO la_timetables VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device) DO UPDATE SET revision=excluded.revision,digest=excluded.digest,body=excluded.body,"
                           "push_mode=excluded.push_mode,school=excluded.school,version=excluded.version,follow_scope=excluded.follow_scope,follow_seen=excluded.follow_seen,updated_at=excluded.updated_at",
                           (device, revision, hashed, canonical(body), 'channel' if channel else 'token', channel[0] if channel else '', channel[1] if channel else '', scope, seen, now))
                # The client-built plan this device may have uploaded before is not kept.
                db.execute("UPDATE la_v2_devices SET snapshot=NULL WHERE id=?", (device,))
                self._rebuild(db, device)
            stored = db.execute("SELECT * FROM la_timetables WHERE device=?", (device,)).fetchone()
            _, own, share, _, _ = self._tables(db, stored)
            taken = {row[0] for row in db.execute("SELECT occurrence FROM la_starts WHERE device=?", (device,))}
        with self.lock:
            pending = len(self._pending(device, taken, now))
        # The rest of the term only feeds the settings page: computed outside the write lock.
        first = schedule_engine.today(now)
        found, omitted = schedule_engine.conflicts_between(device, first, min((share or own).last_day(), first + timedelta(days=200)),
                                                           own, share, body['settings'], body['conflicts'], now)
        return {"revision": revision, "pushMode": stored['push_mode'], "following": bool(stored['follow_scope']),
                "conflicts": found, "omitted": omitted, "pendingCount": pending}

    def _payload(self, occurrence, stored, texts, scope, channel):
        """The start push, built when it is sent or claimed: the plan keeps its times only."""
        tokens = stored['push_mode'] == 'token'
        attributes = {"semester": "", "week": 0, "dateKey": occurrence['dateKey'], "protocolVersion": 2,
                      "scheduleScope": scope, "occurrenceId": occurrence['occurrenceId'], "scheduleVersion": stored['version'],
                      "reservationStart": occurrence['start'] - 978307200, "reservationEnd": occurrence['end'] - 978307200,
                      "reminderDate": occurrence['reminder'] - 978307200}
        if tokens:
            attributes['pushMode'] = 'token'
        else:
            attributes['broadcastChannel'] = channel
        # The phone renders its own courses from its timetable by the time alone.
        # Their classes travel with periods, times and text, the share living here:
        # the phone's copy of the share may be older.
        if occurrence['shared']:
            attributes['shared'] = [dict(item, **texts.get(item['course'], {})) for item in occurrence['shared']]
        payload = {"aps": {"timestamp": int(self.now()), "event": "start", "attributes-type": "ScheduleLiveActivityAttributes",
                           "attributes": attributes,
                           "content-state": public_state(occurrence['dateKey'], None if tokens else occurrence['lastPeriod'], 'upcoming', occurrence['reminder']),
                           "stale-date": occurrence['end'], "alert": {"title": "课程提醒", "body": "即将上课"}}}
        if tokens:
            payload['aps']['input-push-token'] = 1
        else:
            payload['aps']['input-push-channel'] = channel
        # APNs refuses Live Activity payloads over 4 KB: text goes first, then the list.
        if len(canonical(payload).encode()) > 3900:
            attributes['shared'] = [{key: item[key] for key in ('course', 'first', 'last', 'start', 'end')} for item in attributes['shared']]
        if len(canonical(payload).encode()) > 3900:
            attributes.pop('shared')
        return payload


    def _source(self, db, device):
        """What building a device's day needs: (stored row, body, own table, share
        table, share texts, conflict choices, lead scope), or None without a timetable."""
        stored = db.execute("SELECT * FROM la_timetables WHERE device=?", (device,)).fetchone()
        if stored is None:
            return None
        body, own, share, texts, record = self._tables(db, stored)
        # A followed share that went away leaves the reader's own courses only.
        conflicts = body.get('conflicts', {}) if share is not None or not stored['follow_scope'] else {}
        scope = record['schedule_scope'] if record is not None else body['own']['scope']
        return stored, body, own, share, texts, conflicts, scope

    @staticmethod
    def _day(device, source, day, now):
        _, body, own, share, _, conflicts, _ = source
        return schedule_engine.build_day(device, day, own, share, body['settings'], conflicts, now)[0]

    def _resolve(self, db, device, occurrence, day):
        """One occurrence recomputed from the timetable, with what its push needs:
        (occurrence, stored row, share texts, lead scope)."""
        source = self._source(db, device)
        if source is None:
            return None, None, {}, ''
        found = next((item for item in self._day(device, source, day, 0) if item['occurrenceId'] == occurrence), None)
        return found, source[0], source[4], source[6]

    def _channel(self, db, owner, stored, occurrence):
        """(logical key, ready channel id) of a channel-mode occurrence; ('', None) in token mode."""
        if stored['push_mode'] == 'token':
            return '', None
        key = self.key(owner['bundle'], owner['environment'], stored['school'], 'default', stored['version'], occurrence['lastPeriod'])
        row = db.execute("SELECT channel FROM la_channels WHERE logical_key=? AND state='ready'", (key,)).fetchone()
        return key, row['channel'] if row else None

    def _find(self, device, occurrence):
        """(day, Occurrence) of an occurrence in the plan, or None."""
        for day, items in self.plans.get(device, {}).items():
            for item in items:
                if item.id == occurrence:
                    return day, item
        return None

    def _pending(self, device, taken, now):
        return [item for items in self.plans.get(device, {}).values() for item in items if item.id not in taken and item.end > now]

    def _rebuild(self, db, device):
        """Recompute today and tomorrow for one device. The plan swaps in once the
        transaction commits; the ledger only loses reservations whose course is gone."""
        owner = db.execute("SELECT revoked FROM la_v2_devices WHERE id=?", (device,)).fetchone()
        source = self._source(db, device) if owner is not None and not owner['revoked'] else None
        if source is None:
            self._after.append(lambda: self._drop(device))
            return
        now = self.now()
        first = schedule_engine.today(now)
        ledger = {row['occurrence']: row for row in db.execute("SELECT * FROM la_starts WHERE device=? AND expires_at>?",
                                                                  (device, schedule_engine.instant(first, "00:00")))}
        plan = {}
        for day in (first, first + timedelta(days=1)):
            built = self._day(device, source, day, now)
            fresh = {occurrence['occurrenceId'] for occurrence in built}
            kept = []
            for occurrence in built:
                taken = ledger.get(occurrence['occurrenceId'])
                if taken is None:
                    # A changed course must not start again beside an activity already started for it.
                    if any(key not in fresh and row['state'] != 'local' and row['fire_at'] < occurrence['end'] and row['expires_at'] > occurrence['start']
                           for key, row in ledger.items()):
                        continue
                elif taken['state'] == 'local' and (taken['fire_at'], taken['expires_at']) != (occurrence['reminder'], occurrence['end']):
                    db.execute("UPDATE la_starts SET fire_at=?,expires_at=? WHERE device=? AND occurrence=?",
                               (occurrence['reminder'], occurrence['end'], device, occurrence['occurrenceId']))
                kept.append(Occurrence(occurrence['occurrenceId'], occurrence['reminder'], occurrence['end'],
                                       tuple(schedule_engine.refresh_at(occurrence)), tuple(occurrence['alertAt'])))
            for key, row in ledger.items():
                if row['day'] == day.isoformat() and row['state'] == 'local' and key not in fresh:
                    db.execute("DELETE FROM la_starts WHERE device=? AND occurrence=?", (device, key))
            plan[day] = tuple(kept)
        self._after.append(lambda: self._install(device, plan, set(ledger)))

    def _install(self, device, plan, taken):
        """Swap a rebuilt plan in. An occurrence new or moved is queued; an entry
        left behind in the heap is recognized as stale when it falls due."""
        before = {item.id: item for items in self.plans.get(device, {}).values() for item in items}
        self.plans[device] = plan
        for day, items in plan.items():
            for item in items:
                old = before.get(item.id)
                if item.id not in taken and (old is None or old.fire_at != item.fire_at):
                    heapq.heappush(self.due, (item.fire_at, device, item.id))
                activity = self.redraws.get((device, item.id))
                if activity is not None and old is not None and (old.refresh, old.alerts, old.end) != (item.refresh, item.alerts, item.end):
                    # Already started: its unsent refreshes follow the new schedule.
                    self._track(device, item.id, activity.day, item)

    def _requeue(self, device, occurrence, when=None):
        found = self._find(device, occurrence)
        if found is not None:
            heapq.heappush(self.due, (found[1].fire_at if when is None else when, device, occurrence))

    def _track(self, device, occurrence, day, item):
        """Queue an activity's refreshes, then its end. One already dealt with is
        not sent again; of those already past, dispatch sends the latest only."""
        current = self.redraws.get((device, occurrence))
        activity = Redraws(day, item.refresh + (item.end,), frozenset(item.alerts), current.sent if current else 0)
        self.redraws[(device, occurrence)] = activity
        for stamp in activity.unsent():
            heapq.heappush(self.redraw_due, (stamp, device, occurrence))

    def claim(self, device, value):
        """Hand the nearest `slots` pending occurrences to the phone's own
        reservations and return what it needs to reserve them."""
        if not isinstance(value, dict) or set(value) != {"slots"} or type(value["slots"]) is not int or not 0 <= value["slots"] <= 16:
            raise ProtocolError("expected slots 0–16")
        now = self.now()
        with self.transaction() as db:
            owner = db.execute("SELECT * FROM la_v2_devices WHERE id=?", (device,)).fetchone()
            if owner['revoked']:
                raise ProtocolError("device revoked", 409)
            taken = {row[0] for row in db.execute("SELECT occurrence FROM la_starts WHERE device=?", (device,))}
            # A reminder about to fire is safer left to the server than raced.
            fresh = sorted(((day, item) for day, items in self.plans.get(device, {}).items() for item in items
                            if item.id not in taken and item.fire_at > now + 30), key=lambda pair: pair[1].fire_at)
            for day, item in fresh[:value['slots']]:
                db.execute("INSERT INTO la_starts(device,occurrence,day,state,fire_at,expires_at) VALUES(?,?,?,'local',?,?)",
                           (device, item.id, day.isoformat(), item.fire_at, item.end))
            rows = db.execute("SELECT * FROM la_starts WHERE device=? AND state='local' AND expires_at>? ORDER BY fire_at", (device, now)).fetchall()
            source = self._source(db, device)
            days, claimed = {}, []
            for row in rows if source else ():
                if row['day'] not in days:
                    days[row['day']] = {item['occurrenceId']: item for item in self._day(device, source, date.fromisoformat(row['day']), 0)}
                occurrence = days[row['day']].get(row['occurrence'])
                if occurrence is None:
                    continue
                stored, texts, scope = source[0], source[4], source[6]
                _, channel = self._channel(db, owner, stored, occurrence)
                attributes = self._payload(occurrence, stored, texts, scope, channel)['aps']['attributes']
                claimed.append({"occurrenceId": row['occurrence'], "dateKey": row['day'], "reminder": occurrence['reminder'],
                                "start": occurrence['start'], "end": occurrence['end'], "pushMode": stored['push_mode'],
                                "scheduleScope": scope, "scheduleVersion": stored['version'], "channel": channel,
                                "shared": attributes.get('shared', [])})
        return {"claims": claimed}

    def release(self, device, occurrence):
        """A reservation the phone could not make goes back to the server."""
        occurrence = identifier(occurrence)
        with self.transaction() as db:
            changed = db.execute("DELETE FROM la_starts WHERE device=? AND occurrence=? AND state='local'", (device, occurrence)).rowcount
            if changed:
                self._after.append(lambda: self._requeue(device, occurrence))
        return {"occurrenceId": occurrence, "released": bool(changed)}

    def register_token(self, device, occurrence, value):
        """Token mode: the phone sends the activity's token only; the refresh
        instants come from the schedule."""
        occurrence = identifier(occurrence)
        token = value.get("token")
        if set(value) != {"token"} or not isinstance(token, str) or not 16 <= len(token) <= 512 or any(c not in "0123456789abcdefABCDEF" for c in token):
            raise ProtocolError("invalid activity push token")
        sealed = self.vault.seal(token)
        now = self.now()
        with self.transaction() as db:
            if db.execute("SELECT revoked FROM la_v2_devices WHERE id=?", (device,)).fetchone()['revoked']:
                raise ProtocolError("device revoked", 409)
            found = self._find(device, occurrence)
            if found is None:
                # Its course changed after it started: the activity keeps running to its end.
                row = db.execute("SELECT day,fire_at,expires_at FROM la_starts WHERE device=? AND occurrence=? AND state!='local'", (device, occurrence)).fetchone()
                found = (date.fromisoformat(row['day']), Occurrence(occurrence, row['fire_at'], row['expires_at'], (), ())) if row else None
            if found is None or found[1].end <= now:
                raise ProtocolError("unknown or finished occurrence", 404)
            day, item = found
            db.execute("INSERT INTO la_activity_tokens VALUES(?,?,?,?,?,?) ON CONFLICT(device,occurrence) DO UPDATE SET token=excluded.token,day=excluded.day,end_at=excluded.end_at,updated_at=excluded.updated_at",
                       (device, occurrence, sealed, day.isoformat(), item.end, now))
            self._after.append(lambda: self._track(device, occurrence, day.isoformat(), item))
        with self.lock:
            activity = self.redraws.get((device, occurrence))
            return {"occurrenceId": occurrence, "pending": len(activity.unsent()) if activity else 0}

    def nightly(self):
        """At UTC+8 midnight build the new tomorrow for every device, drop
        finished starts and keep channels promised. On start the plans are
        fresh, so only the upkeep runs."""
        now = self.now()
        day = schedule_engine.today(now)
        with self.lock:
            done = self.db.execute("SELECT value FROM la_v2_meta WHERE key='nightly'").fetchone()
            if done and done[0] == day.isoformat():
                return
            devices = [] if self.built == day else [row[0] for row in self.db.execute(
                "SELECT t.device FROM la_timetables t JOIN la_v2_devices d ON d.id=t.device WHERE d.revoked=0")]
        for device in devices:
            # One short transaction each, so dispatch never waits behind the whole run.
            with self.transaction() as db:
                self._rebuild(db, device)
        with self.transaction() as db:
            db.execute("DELETE FROM la_starts WHERE expires_at<?", (now - DAY,))
            for row in db.execute("SELECT DISTINCT bundle, environment, school, version FROM la_timetables t JOIN la_v2_devices d ON d.id=t.device WHERE d.revoked=0 AND t.push_mode='channel'").fetchall():
                db.execute("UPDATE la_schedule_versions SET broadcast_until=MAX(broadcast_until,?) WHERE bundle=? AND environment=? AND school=? AND schedule='default' AND version=?",
                           (now + 8 * DAY, *row))
            db.execute("INSERT INTO la_v2_meta VALUES('nightly',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (day.isoformat(),))
            self.built = day
            self.retries = {key: value for key, value in self.retries.items() if self._find(*key)}

    def follow_shares(self):
        """Rebuild followers whose share was replaced, resynced or revoked since
        their last build, nearest reminder first."""
        now = self.now()
        with self.lock:
            if not self.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='shares'").fetchone():
                return
            stale = [row for row in self.db.execute(
                "SELECT t.device, t.follow_seen, COALESCE((SELECT s.updated_at FROM shares s WHERE s.schedule_scope=t.follow_scope AND s.revoked=0 ORDER BY s.created_at DESC LIMIT 1), '') AS current "
                "FROM la_timetables t JOIN la_v2_devices d ON d.id=t.device WHERE d.revoked=0 AND t.follow_scope!=''").fetchall() if row['current'] != row['follow_seen']]
            nearest = {row['device']: min((item.fire_at for item in self._pending(row['device'], (), now) if item.fire_at > now), default=float('inf')) for row in stale}
        for row in sorted(stale, key=lambda row: nearest[row['device']]):
            with self.transaction() as db:
                db.execute("UPDATE la_timetables SET follow_seen=? WHERE device=?", (row['current'], row['device']))
                self._rebuild(db, row['device'])

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
        now = self.now()
        with self.lock:
            rows = self.db.execute("SELECT school,environment,version,final_period,state,error FROM la_channels ORDER BY school,environment,version,final_period").fetchall()
            starts = dict(self.db.execute("SELECT state,COUNT(*) FROM la_starts GROUP BY state").fetchall())
            taken = {tuple(row) for row in self.db.execute("SELECT device,occurrence FROM la_starts")}
            scheduled = sum(1 for device, days in self.plans.items() for items in days.values() for item in items
                            if item.end > now and (device, item.id) not in taken)
            broadcasts = dict(self.db.execute("SELECT state,COUNT(*) FROM la_v2_broadcasts GROUP BY state").fetchall())
            updates = {"activities": len(self.redraws), "pending": sum(len(activity.unsent()) for activity in self.redraws.values())}
            timetables = dict(self.db.execute("SELECT push_mode,COUNT(*) FROM la_timetables GROUP BY push_mode").fetchall())
            following = self.db.execute("SELECT COUNT(*) FROM la_timetables WHERE follow_scope!=''").fetchone()[0]
            nightly = self.db.execute("SELECT value FROM la_v2_meta WHERE key='nightly'").fetchone()
        return {"protocolVersion": 2, "channels": [dict(row) for row in rows], "starts": dict(starts, pending=scheduled), "broadcasts": broadcasts,
                "tokenUpdates": updates, "timetables": timetables, "following": following, "nightly": nightly[0] if nightly else None}

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

    def _push_all(self, items):
        """Send `(environment, notification)` pairs, one concurrent batch per
        environment, and return the results in the order given."""
        results = [None] * len(items)
        for environment in sorted({environment for environment, _ in items}):
            positions = [k for k, (env, _) in enumerate(items) if env == environment]
            try:
                batch = self.client.push_many([items[k][1] for k in positions], environment=environment)
            except Exception:
                batch = [{"ok": False, "status": 0, "certainty": "unknown", "reason": "transport failure"}] * len(positions)
            for k, result in zip(positions, batch):
                results[k] = result
        return results


    def dispatch_starts(self):
        if not self.client:
            return
        now = self.now()
        with self.lock:
            due = []
            while self.due and self.due[0][0] <= now and len(due) < 100:
                _, device, occurrence = heapq.heappop(self.due)
                if (device, occurrence) not in due:
                    due.append((device, occurrence))
        claimed = []
        for device, occurrence in due:
            with self.transaction() as db:
                found = self._find(device, occurrence)
                # Gone from the plan, moved later or backing off: whatever still counts is queued again already.
                if found is None or found[1].fire_at > now or self.retries.get((device, occurrence), (0, 0))[1] > now:
                    continue
                day, item = found
                if item.end <= now:
                    continue
                # The phone reserved it, or it went already.
                if db.execute("SELECT 1 FROM la_starts WHERE device=? AND occurrence=?", (device, occurrence)).fetchone():
                    continue
                owner = db.execute("SELECT * FROM la_v2_devices WHERE id=?", (device,)).fetchone()
                if owner is None or owner['revoked']:
                    continue
                # Built now from the timetable: the plan keeps its times only.
                built, stored, texts, scope = self._resolve(db, device, occurrence, day)
                if built is None:
                    continue
                key, channel = self._channel(db, owner, stored, built)
                # Token-mode starts carry `input-push-token` and reference no channel; a missing one waits.
                if owner['bundle'] != self.client.bundle_id or not owner['token'] or (key and channel is None):
                    self._after.append(lambda device=device, occurrence=occurrence: self._requeue(device, occurrence, now + 5))
                    continue
                try:
                    token = self.vault.open(owner['token'])
                except Exception:
                    db.execute("UPDATE la_v2_devices SET error='tokenKeyUnavailable' WHERE id=?", (device,))
                    self._after.append(lambda device=device, occurrence=occurrence: self._requeue(device, occurrence, now + 60))
                    continue
                payload = self._payload(built, stored, texts, scope, channel)
                db.execute("INSERT INTO la_starts(device,occurrence,day,state,fire_at,expires_at) VALUES(?,?,?,'submitting',?,?)",
                           (device, occurrence, day.isoformat(), built['reminder'], built['end']))
            payload['aps']['timestamp'] = int(now)
            # APNs keeps it for a phone that is offline at the reminder, until the course ends.
            claimed.append(((device, occurrence), owner['environment'], {"device_token": token, "payload": payload, "expiration": int(built['end']),
                                                                         "topic": owner['bundle'] + '.push-type.liveactivity'}))
        # Every intent is on disk before the first byte goes out; the batch then costs one round trip.
        for (activity, _, _), result in zip(claimed, self._push_all([(environment, item) for _, environment, item in claimed])):
            status = result.get('status', 0)
            state = 'terminal'
            if result.get('ok') and status == 200:
                state = 'submitted'
            elif result.get('certainty') == 'unknown' or (not status and result.get('certainty') != 'notSent'):
                state = 'submissionUnknown'
            elif result.get('certainty') == 'notSent' or status in (408, 429) or 500 <= status < 600:
                state = 'pending'
            with self.transaction() as db:
                current = db.execute("SELECT revoked FROM la_v2_devices WHERE id=?", (activity[0],)).fetchone()
                if state == 'pending' and current is not None and not current['revoked']:
                    # Not delivered: the intent goes, and the start is tried again later.
                    db.execute("DELETE FROM la_starts WHERE device=? AND occurrence=? AND state='submitting'", activity)
                    attempts = self.retries.get(activity, (0, 0))[0] + 1
                    retry = now + min(300, 5 * 2 ** min(attempts, 6))
                    def again(activity=activity, attempts=attempts, retry=retry):
                        self.retries[activity] = (attempts, retry)
                        self._requeue(*activity, retry)
                    self._after.append(again)
                    continue
                db.execute("UPDATE la_starts SET state=?,detail=? WHERE device=? AND occurrence=? AND state='submitting'",
                           ('cancelled' if state == 'pending' else state, result.get('reason', '')[:200], *activity))
                self._after.append(lambda activity=activity: self.retries.pop(activity, None))

    def plan_broadcasts(self):
        """Queue today's and tomorrow's boundaries. Once a minute is enough: the
        dispatcher only needs a boundary queued before it falls due."""
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

    def dispatch_broadcasts(self):
        if not self.client:
            return
        now = self.now()
        with self.transaction() as db:
            db.execute("UPDATE la_v2_broadcasts SET state='expired' WHERE state='pending' AND fire_at<?", (now - 60,))
            rows = db.execute("SELECT b.*,c.channel,c.environment,c.bundle,v.definition FROM la_v2_broadcasts b JOIN la_channels c ON b.channel_key=c.logical_key JOIN la_schedule_versions v ON c.bundle=v.bundle AND c.environment=v.environment AND c.school=v.school AND c.schedule=v.schedule AND c.version=v.version WHERE b.state='pending' AND b.fire_at<=? AND b.next_attempt<=? AND c.bundle=? ORDER BY b.fire_at DESC LIMIT 200", (now, now, self.client.bundle_id)).fetchall()
        claimed = []
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
            if changed:
                claimed.append(row)
        # A bell touches every channel of every school at once: one batch per environment.
        results = [None] * len(claimed)
        for environment in sorted({row['environment'] for row in claimed}):
            positions = [k for k, row in enumerate(claimed) if row['environment'] == environment]
            try:
                batch = self.client.broadcast_many([{"channel_id": claimed[k]['channel'], "payload": json.loads(claimed[k]['payload']),
                    "expiration": 0, "topic": claimed[k]['bundle']} for k in positions], environment=environment)
            except Exception:
                batch = [{'ok': False}] * len(positions)
            for k, result in zip(positions, batch):
                results[k] = result
        for row, result in zip(claimed, results):
            with self.transaction() as db:
                db.execute("UPDATE la_channels SET error=? WHERE logical_key=?", ('' if result.get('ok') else str(result.get('reason') or 'broadcast failed')[:200], row['channel_key']))
                if result.get('status') == 410 or result.get('reason') in ('ChannelNotFound', 'BadChannelId', 'BadChannelID'):
                    db.execute("UPDATE la_channels SET state='missing',channel='' WHERE logical_key=?", (row['channel_key'],))
                db.execute("UPDATE la_v2_broadcasts SET state=?,next_attempt=? WHERE channel_key=? AND fire_at=?", ('sent' if result.get('ok') else 'pending', now + 5, row['channel_key'], row['fire_at']))


    def dispatch_token_updates(self):
        if not self.client:
            return
        now = self.now()
        with self.transaction() as db:
            db.execute("DELETE FROM la_activity_tokens WHERE end_at<?", (now - DAY,))
            due = set()
            while self.redraw_due and self.redraw_due[0][0] <= now and len(due) < 200:
                _, device, occurrence = heapq.heappop(self.redraw_due)
                due.add((device, occurrence))
            claimed = []
            for activity in sorted(due):
                redraws = self.redraws.get(activity)
                if redraws is None or redraws.retry_at > now:
                    continue
                # Like the broadcasts: only the newest due refresh of an activity is worth sending.
                past = [stamp for stamp in redraws.stamps if redraws.sent < stamp <= now]
                if not past:
                    continue
                stamp = past[-1]
                last = stamp == redraws.stamps[-1]
                expires = stamp + 60 if last else redraws.stamps[redraws.stamps.index(stamp) + 1]
                if expires <= now:
                    self.redraws.pop(activity)
                    continue
                owner = db.execute("SELECT d.revoked,d.environment,d.bundle,t.token FROM la_v2_devices d LEFT JOIN la_activity_tokens t ON t.device=d.id AND t.occurrence=? WHERE d.id=?",
                                   (activity[1], activity[0])).fetchone()
                if owner is None or owner['revoked'] or not owner['token']:
                    self.redraws.pop(activity)
                    continue
                if owner['bundle'] != self.client.bundle_id:
                    continue
                claimed.append((activity, redraws, stamp, expires, last, owner))
        items, sendable = [], []
        for activity, redraws, stamp, expires, last, owner in claimed:
            stamp = int(stamp)
            aps = {"timestamp": stamp, "event": 'end' if last else 'update', "content-state": {"broadcastDateKey": redraws.day,
                   "broadcastTimestamp": stamp, "updatedAt": stamp, "startDate": stamp, "endDate": stamp}}
            aps.update({"dismissal-date": stamp} if last else {"stale-date": stamp + 60})
            if not last and stamp in redraws.alerts:
                # The same reminder a start carries: a course joined an activity already on screen.
                aps['alert'] = {"title": "课程提醒", "body": "即将上课"}
            try:
                token = self.vault.open(owner['token'])
            except Exception:
                token = None
            sendable.append(token is not None)
            if token is not None:
                items.append((owner['environment'], {"device_token": token, "payload": {"aps": aps}, "push_type": "liveactivity", "priority": 10,
                    "expiration": int(expires), "collapse_id": activity[1][:64], "topic": owner['bundle'] + '.push-type.liveactivity'}))
        sent = iter(self._push_all(items))
        for (activity, redraws, stamp, _, last, _), ok in zip(claimed, sendable):
            result = next(sent) if ok else {"ok": False, "status": 0, "certainty": "notSent", "reason": "token key unavailable"}
            status, reason = result.get('status', 0), str(result.get('reason') or '')
            with self.transaction() as db:
                current = self.redraws.get(activity)
                if status == 410 or (status == 400 and reason in ('BadDeviceToken', 'DeviceTokenNotForTopic')):
                    db.execute("DELETE FROM la_activity_tokens WHERE device=? AND occurrence=?", activity)
                    self.redraws.pop(activity, None)
                elif current is None:
                    continue
                elif not (result.get('ok') and status == 200) and (result.get('certainty') in ('notSent', 'unknown') or status in (408, 429) or 500 <= status < 600):
                    # An update is idempotent, so retrying is safe until the next refresh replaces it.
                    current.attempts += 1
                    current.retry_at = now + min(60, 5 * 2 ** current.attempts)
                    heapq.heappush(self.redraw_due, (current.retry_at, *activity))
                else:
                    # Sent, or refused for good: either way the next one is the next refresh.
                    current.sent, current.attempts = max(current.sent, stamp), 0
                    if last:
                        self.redraws.pop(activity, None)

    def start(self):
        if self.workers:
            return
        for name, action, delay in [('legacy-drain', self.drain_legacy, 5), ('channels', self.maintain_channels, 60), ('broadcast-plan', self.plan_broadcasts, 60), ('starts', self.dispatch_starts, 1), ('broadcasts', self.dispatch_broadcasts, 1), ('token-updates', self.dispatch_token_updates, 1), ('nightly', self.nightly, 30), ('follow-shares', self.follow_shares, 30)]:
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
            elif tail == 'timetable' and method == 'PUT':
                result = service.put_timetable(device, body())
            elif tail == 'claims' and method == 'POST':
                result = service.claim(device, body())
            elif len(parts) == 4 and parts[2] == 'claims' and method == 'DELETE':
                result = service.release(device, parts[3])
            elif len(parts) == 4 and parts[2] == 'activities' and method == 'PUT':
                result = service.register_token(device, parts[3], body())
            elif len(parts) == 4 and parts[2] == 'activities' and method == 'DELETE':
                result = service.forget_activity(device, parts[3])
            else:
                raise ProtocolError('not found', 404)
        handler.send_json(200, result)
    except ProtocolError as error:
        handler.send_json(error.status, {'error': str(error)})
    except (ValueError, KeyError, TypeError) as error:
        handler.send_json(400, {'error': str(error)})
    return True

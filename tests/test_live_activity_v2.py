"""v2 registration, channels, broadcasts, start delivery and the HTTP contract."""
import copy
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest

from server.live_activity import LiveActivityService
from server.live_activity_v2 import Service, TokenVault
from server.live_activity_timeline import ProtocolError, boundaries, normalize_schedule


class TestVault:
    def seal(self, value): return 'encrypted:' + value[::-1]
    def open(self, value): return value.removeprefix('encrypted:')[::-1]


class APNs:
    bundle_id = 'me.mom0ka27.naptable'
    def __init__(self):
        self.channels, self.starts, self.broadcasts, self.deleted = [], [], [], []
        self.result = {'ok': True, 'status': 200, 'certainty': 'accepted'}
        self.on_push = None
    def create_channel(self, **kwargs):
        channel = 'channel-' + str(len(self.channels))
        self.channels.append(channel)
        return channel
    def delete_channel(self, channel, **kwargs): self.deleted.append(channel)
    def push(self, token, payload, **kwargs):
        self.starts.append((token, payload, kwargs))
        if self.on_push: self.on_push()
        return self.result
    def push_many(self, items, environment='production'):
        self.batches = getattr(self, 'batches', []) + [len(items)]
        return [self.push(item.pop('device_token'), item.pop('payload'), environment=environment, **item) for item in items]
    def broadcast(self, channel, payload, **kwargs):
        self.broadcasts.append((channel, payload, kwargs))
        return self.result
    def broadcast_many(self, items, environment='production'):
        self.broadcast_batches = getattr(self, 'broadcast_batches', []) + [len(items)]
        return [self.broadcast(item.pop('channel_id'), item.pop('payload'), environment=environment, **item) for item in items]


class V2Tests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:', check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.addCleanup(self.db.close)
        self.lock = threading.RLock()
        self.clock = 1790033400  # 2026-09-22 07:30 Asia/Taipei
        self.client = APNs()
        self.legacy = LiveActivityService(self.db, self.lock, client=self.client, now=lambda: self.clock)
        self.service = Service(self.legacy, TestVault())
        self.db.executescript("CREATE TABLE school_configs(id TEXT, periods_json TEXT); CREATE TABLE school_terms(school_id TEXT,timezone TEXT,is_current INTEGER);")
        self.periods = [{'start': '08:00', 'end': '08:50'}, {'start': '09:00', 'end': '09:50'}, {'start': '10:00', 'end': '10:50'}, {'start': '11:00', 'end': '11:50'}]
        self.db.execute('INSERT INTO school_configs VALUES(?,?)', ('school', json.dumps(self.periods)))
        self.db.execute("INSERT INTO school_terms VALUES('school','Asia/Taipei',1)")
        self.db.commit()
        self.registration = {'installationId': 'installation-1', 'bundleID': self.client.bundle_id, 'environment': 'sandbox', 'startToken': 'ab12'}
        self.device = self.service.register(self.registration, 'persisted-secret')
        self.id = self.device['deviceID']
        self.timetable = {'revision': 1, 'settings': {'leadMinutes': 30},
                          'own': {'scope': 'scope-1', 'schoolID': 'school', 'periods': self.periods, 'semesterStartMonday': '2026-09-07', 'weekCount': 18,
                                  'courses': [{'id': 'math', 'day': 2, 'first': 1, 'last': 2, 'weeks': []}]}}
        # Running on the school's bells, the timetable takes the school channels.
        self.service.put_timetable(self.id, self.timetable)
        self.service.maintain_channels()
        self.channels = {str(row['final_period']): row['channel'] for row in self.db.execute('SELECT final_period,channel FROM la_channels')}

    def upload(self, **changes):
        return self.service.put_timetable(self.id, dict(copy.deepcopy(self.timetable), **changes))

    def occurrence(self):
        """Today's occurrence: math, 08:00–09:50, reminding at 07:30."""
        return self.service.plans[self.id][min(self.service.plans[self.id])][0]

    def ledger(self):
        row = self.db.execute('SELECT state FROM la_starts WHERE device=?', (self.id,)).fetchone()
        return row[0] if row else None

    def test_upload_promises_eight_days_and_a_new_bell_is_a_new_version(self):
        self.assertEqual(len(self.client.channels), 4)
        self.assertEqual(self.db.execute('SELECT broadcast_until FROM la_schedule_versions').fetchone()[0] - self.clock, 8 * 86400)
        changed = copy.deepcopy(self.periods)
        changed[0]['start'] = '07:55'
        self.db.execute('UPDATE school_configs SET periods_json=?', (json.dumps(changed),)); self.db.commit()
        self.upload(revision=2, own=dict(self.timetable['own'], periods=changed))
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM la_schedule_versions').fetchone()[0], 2)
        self.service.maintain_channels()
        self.assertEqual(len(self.client.channels), 8)

    def test_registration_requires_secret(self):
        for secret in ('', 'wrong'):
            with self.assertRaises(ProtocolError) as error: self.service.register(self.registration, secret)
            self.assertEqual(error.exception.status, 403)
        self.assertNotIn('ab12', self.db.execute('SELECT token FROM la_v2_devices').fetchone()[0])

    def test_first_registration_can_recover_lost_response(self):
        again = self.service.register(self.registration, 'persisted-secret')
        self.assertEqual(again['deviceID'], self.id)
        self.assertNotIn('secret', again)

    def test_start_has_channel_and_no_personal_content(self):
        self.service.dispatch_starts()
        token, payload, options = self.client.starts[0]
        self.assertEqual(token, 'ab12')
        self.assertEqual(payload['aps']['input-push-channel'], self.channels['2'])
        self.assertEqual(options['expiration'], int(self.occurrence().end), 'An offline phone still gets it until the course ends')
        self.assertNotIn('math', json.dumps(payload))
        self.assertEqual(self.ledger(), 'submitted')
        self.clock += 10
        self.service.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1)

    def test_unknown_is_never_replayed_by_revision_token_or_restart(self):
        self.client.result = {'ok': False, 'status': 0, 'certainty': 'unknown'}
        self.service.dispatch_starts()
        self.assertEqual(self.ledger(), 'submissionUnknown')
        self.upload(revision=2, settings={'leadMinutes': 15})
        self.service.register(dict(self.registration, startToken='cd34'), 'persisted-secret')
        self.clock += 900
        self.service.dispatch_starts()
        restarted = Service(self.legacy, TestVault())
        restarted.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1)

    def test_explicit_rejection_retries_within_expiry(self):
        self.client.result = {'ok': False, 'status': 429, 'certainty': 'rejected'}
        self.service.dispatch_starts()
        self.assertIsNone(self.ledger(), 'Not delivered: the intent goes')
        self.clock += 5; self.service.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1, 'still backing off')
        self.clock += 5; self.client.result = {'ok': True, 'status': 200}
        self.service.dispatch_starts()
        self.assertEqual((len(self.client.starts), self.ledger()), (2, 'submitted'))

    def test_delete_during_retry_does_not_resurrect(self):
        self.client.on_push = lambda: self.service.forget(self.id)
        self.client.result = {'ok': False, 'status': 503, 'certainty': 'rejected'}
        self.service.dispatch_starts()
        self.assertEqual(self.ledger(), 'cancelled')
        self.service.forget(self.id)
        self.assertTrue(self.service.status(self.id)['revoked'])
        with self.assertRaises(ProtocolError): self.service.register(self.registration, 'persisted-secret')

    def test_public_end_does_not_depend_on_devices_or_holidays(self):
        self.service.forget(self.id)
        self.db.executescript("CREATE TABLE global_calendar(id INTEGER, adjustments_json TEXT); INSERT INTO global_calendar VALUES(1,'[{\"date\":\"2026-09-22\",\"kind\":\"off\"}]');")
        schedule = normalize_schedule(self.periods, 'Asia/Taipei')
        self.clock = boundaries(schedule, '2026-09-22', 2)[-1][0]
        self.service.plan_broadcasts(); self.service.dispatch_broadcasts()
        received = {channel: payload['aps']['event'] for channel, payload, _ in self.client.broadcasts}
        self.assertEqual(received[self.channels['2']], 'end')
        self.assertEqual(self.client.broadcast_batches, [len(received)], 'Every channel at the bell leaves in one batch')
        self.assertEqual(received[self.channels['4']], 'update')
        self.assertNotIn(self.channels['1'], received)

    def test_previous_day_end_is_not_sent_after_midnight(self):
        from server.live_activity_timeline import timestamp, canonical, public_state
        self.clock = timestamp('2026-09-23', '00:00', 'Asia/Taipei') + 10
        key = self.db.execute('SELECT logical_key FROM la_channels LIMIT 1').fetchone()[0]
        stamp = self.clock - 30
        payload = {'aps': {'timestamp': stamp, 'event': 'end', 'content-state': public_state('2026-09-22', 1, 'ended', stamp)}}
        self.db.execute("INSERT INTO la_v2_broadcasts(channel_key,day,fire_at,payload) VALUES(?,?,?,?)", (key, '2026-09-22', stamp, canonical(payload)))
        self.db.commit()
        self.service.plan_broadcasts(); self.service.dispatch_broadcasts()
        self.assertFalse(any(p['aps']['content-state']['broadcastDateKey'] == '2026-09-22' for _, p, _ in self.client.broadcasts))

    def test_channel_reclamation_obeys_the_promise(self):
        self.service.maintain_channels(); self.assertEqual(self.client.deleted, [])
        self.clock += 8 * 86400 + 1
        self.service.maintain_channels()
        self.assertEqual(len(self.client.deleted), 4)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM la_channels').fetchone()[0], 0)

    def test_timezone_validation(self):
        with self.assertRaises(ProtocolError): normalize_schedule(self.periods, 'Not/AZone')

    def test_legacy_migration_stops_pending_and_requires_secret(self):
        old = self.legacy.register({'bundleID': self.client.bundle_id, 'startToken': '12'})
        with self.assertRaises(ProtocolError): self.service.register(dict(self.registration, installationId=old['deviceID']), '')
        migrated = self.service.register(dict(self.registration, installationId=old['deviceID']), old['secret'])
        self.assertEqual(migrated['deviceID'], old['deviceID'])
        self.assertEqual(self.legacy._device(old['deviceID'])['enabled'], 0)

    def test_cross_language_fixture_public_boundaries(self):
        fixture = json.loads((Path(__file__).parent / 'fixtures/live-activity-v2.json').read_text())
        schedule = normalize_schedule(fixture['periods'], fixture['timeZone'])
        generated = boundaries(schedule, fixture['dateKey'], 2)
        self.assertEqual(generated[-1][1], fixture['end'])
        self.assertEqual(generated[0][1], fixture['update'])

    def test_token_vault_real_encryption(self):
        try:
            from cryptography.fernet import Fernet
        except ImportError:
            self.skipTest('install server/requirements.txt for encryption integration')
        with tempfile.NamedTemporaryFile() as file:
            file.write(Fernet.generate_key()); file.flush()
            vault = TokenVault(file.name)
            sealed = vault.seal('secret-token')
            self.assertNotIn('secret-token', sealed)
            self.assertEqual(vault.open(sealed), 'secret-token')
            with self.assertRaises(Exception): vault.open(sealed[:-3] + 'abc')



class HTTPV2Tests(unittest.TestCase):
    setUp = V2Tests.setUp
    occurrence = V2Tests.occurrence
    """Exercise the actual Handler integration without starting any APNs worker."""

    def test_http_contract(self):
        from http.client import HTTPConnection
        from server.naptable_server import Handler
        from server_support import FastServer
        self.legacy.v2 = self.service
        handler = type('V2Handler', (Handler,), {'live_activity': self.legacy})
        http = FastServer(('127.0.0.1', 0), handler)
        thread = threading.Thread(target=lambda: http.serve_forever(poll_interval=0.01), daemon=True)
        thread.start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        def request(method, path, value=None, secret='persisted-secret'):
            connection = HTTPConnection('127.0.0.1', http.server_port, timeout=5)
            try:
                connection.request(method, path, body=json.dumps(value) if value is not None else None,
                    headers={'Content-Type': 'application/json', 'X-Device-Secret': secret})
                response = connection.getresponse()
                return response.status, json.loads(response.read())
            finally: connection.close()
        api = '/v2/live-activity'
        self.clock -= 3600  # before the reminder, so the phone may still claim it
        device = api + '/devices/' + self.id
        self.assertEqual(request('POST', api + '/devices', self.registration, 'wrong')[0], 403)
        self.assertEqual(request('POST', api + '/devices', [1, 2])[0], 400)
        self.assertEqual(request('POST', '/v1/live-activity/devices', {})[0], 426)
        self.assertEqual(request('PUT', device + '/timetable', dict(self.timetable, revision=2))[1]['pendingCount'], 1)
        self.assertEqual(request('PUT', device + '/timetable', dict(self.timetable, revision=2), 'wrong')[0], 403)
        # The client-built plan and its handover are gone.
        for method, path in (('PUT', '/plan'), ('POST', '/local-handoff'), ('POST', '/remote-resume'), ('POST', '/foreground-recovery')):
            self.assertEqual(request(method, device + path, {})[0], 404, path)
        self.assertEqual(request('GET', api + '/broadcast-config?schoolID=school')[0], 404)
        self.assertEqual(request('POST', device + '/claims', {'slots': 1})[1]['claims'][0]['occurrenceId'], self.occurrence().id)
        self.assertEqual(request('DELETE', device + '/claims/' + self.occurrence().id)[1]['released'], True)
        activity = device + '/activities/' + self.occurrence().id
        body = {'token': 'ab' * 16}
        self.assertEqual(request('PUT', activity, body, 'wrong')[0], 403)
        self.assertEqual(request('PUT', activity, dict(body, refreshAt=[1790035200]))[0], 400)
        self.assertEqual(request('PUT', activity, body)[0], 200)
        self.assertEqual(request('PUT', device + '/activities/unknown', body)[0], 404)
        self.assertEqual(request('DELETE', activity)[0], 200)
        self.assertEqual(request('DELETE', activity)[0], 200)
        self.assertEqual(request('PUT', device + '/activities/bad%20id', body)[0], 400)
        self.assertEqual(request('GET', device)[1]['timetableRevision'], 2)
        self.assertEqual(request('DELETE', device)[0], 200)
        self.assertEqual(request('DELETE', device)[0], 200)
        self.assertEqual(request('PUT', activity, body)[0], 409)


if __name__ == '__main__': unittest.main()

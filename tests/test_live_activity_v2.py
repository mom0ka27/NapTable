"""v2 transaction, lifecycle and cross-language contract regressions."""
import copy
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest

from server.live_activity import LiveActivityService
from server.live_activity_v2 import Service, TokenVault
from server.live_activity_timeline import ProtocolError, boundaries, normalize_schedule, validate_plan


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
    def broadcast(self, channel, payload, **kwargs):
        self.broadcasts.append((channel, payload, kwargs))
        return self.result


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
        self.query = {'schoolID': 'school', 'scheduleId': 'default', 'bundleID': self.client.bundle_id, 'environment': 'sandbox', 'deviceID': self.id}
        self.config = self.service.config(self.query, 'persisted-secret')
        self.service.maintain_channels()
        self.config = self.service.config(self.query, 'persisted-secret')
        self.plan = dict(protocolVersion=2, planRevision=1, scheduleScope='scope-1', schoolID='school', scheduleId='default', scheduleVersion=self.config['scheduleVersion'], coverageStart=self.clock, coverageEndExclusive=self.clock + 180 * 86400, leadMinutes=30,
            items=[dict(occurrenceId='occurrence-1', supersedes=[], dateKey='2026-09-22', startPeriod=1, endPeriod=2)], busyIntervals=[])

    def job(self):
        return self.db.execute('SELECT * FROM la_start_jobs WHERE device=?', (self.id,)).fetchone()

    def test_config_is_immutable_cross_day_and_retains_eight_days(self):
        self.assertEqual(len(self.client.channels), 4)
        self.assertEqual(self.config['broadcastUntil'] - self.clock, 8 * 86400)
        self.clock += 86400
        self.assertEqual(self.service.config(self.query, 'persisted-secret')['channels'], self.config['channels'])
        changed = copy.deepcopy(self.periods)
        changed[0]['start'] = '07:55'
        self.db.execute('UPDATE school_configs SET periods_json=?', (json.dumps(changed),)); self.db.commit()
        new = self.service.config(self.query, 'persisted-secret')
        self.assertNotEqual(new['scheduleVersion'], self.config['scheduleVersion'])
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM la_schedule_versions').fetchone()[0], 2)
        self.service.maintain_channels()
        self.assertEqual(len(self.client.channels), 8)

    def test_registration_requires_secret_and_preserves_local_mode(self):
        for secret in ('', 'wrong'):
            with self.assertRaises(ProtocolError) as error: self.service.register(self.registration, secret)
            self.assertEqual(error.exception.status, 403)
        self.service.handoff(self.id)
        self.assertEqual(self.service.register(self.registration, 'persisted-secret')['launchMode'], 'local')
        self.assertNotIn('ab12', self.db.execute('SELECT token FROM la_v2_devices').fetchone()[0])

    def test_first_registration_can_recover_lost_response(self):
        again = self.service.register(self.registration, 'persisted-secret')
        self.assertEqual(again['deviceID'], self.id)
        self.assertNotIn('secret', again)

    def test_plan_revisions_and_atomic_validation(self):
        self.service.replace_plan(self.id, self.plan)
        self.service.replace_plan(self.id, self.plan)
        changed = copy.deepcopy(self.plan); changed['leadMinutes'] = 60
        with self.assertRaises(ProtocolError) as error: self.service.replace_plan(self.id, changed)
        self.assertEqual(error.exception.status, 409)
        changed['planRevision'] = 2; changed['items'][0]['endPeriod'] = 99
        with self.assertRaises(ProtocolError): self.service.replace_plan(self.id, changed)
        self.assertEqual(self.service.status(self.id)['planRevision'], 1)
        self.assertEqual(self.job()['state'], 'pending')

    def test_start_has_channel_and_no_personal_content(self):
        self.service.replace_plan(self.id, self.plan)
        self.clock = self.job()['fire_at']
        self.service.dispatch_starts()
        token, payload, options = self.client.starts[0]
        self.assertEqual(token, 'ab12')
        self.assertEqual(payload['aps']['input-push-channel'], self.config['channels']['2'])
        self.assertEqual(options['expiration'], int(self.job()['expires_at']), 'An offline phone still gets it until the course ends')
        self.assertNotIn('courseName', json.dumps(payload))
        self.assertEqual(self.job()['state'], 'submitted')

    def test_unknown_is_never_replayed_by_revision_token_or_restart(self):
        self.client.result = {'ok': False, 'status': 0, 'certainty': 'unknown'}
        self.service.replace_plan(self.id, self.plan); self.clock = self.job()['fire_at']
        self.service.dispatch_starts()
        self.assertEqual(self.job()['state'], 'submissionUnknown')
        self.plan['planRevision'] = 2
        self.service.replace_plan(self.id, self.plan)
        self.service.register(dict(self.registration, startToken='cd34'), 'persisted-secret')
        restarted = Service(self.legacy, TestVault())
        restarted.materialize(); restarted.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1)

    def test_crash_after_submitting_is_unknown_after_restart(self):
        self.service.replace_plan(self.id, self.plan)
        self.db.execute("UPDATE la_start_jobs SET state='submitting'"); self.db.commit()
        Service(self.legacy, TestVault())
        self.assertEqual(self.job()['state'], 'submissionUnknown')

    def test_explicit_rejection_retries_within_expiry(self):
        self.client.result = {'ok': False, 'status': 429, 'certainty': 'rejected'}
        self.service.replace_plan(self.id, self.plan); self.clock = self.job()['fire_at']
        self.service.dispatch_starts()
        self.assertEqual(self.job()['state'], 'pending')
        self.clock += 10; self.client.result = {'ok': True, 'status': 200}
        self.service.dispatch_starts()
        self.assertEqual(len(self.client.starts), 2)

    def test_handoff_during_submission_returns_history_and_stops_future_starts(self):
        self.service.replace_plan(self.id, self.plan); self.clock = self.job()['fire_at']
        history = []
        self.client.on_push = lambda: history.append(self.service.handoff(self.id))
        self.service.dispatch_starts()
        self.assertEqual(history[0]['history'][0]['state'], 'submitting')
        with self.assertRaises(ProtocolError): self.service.replace_plan(self.id, self.plan)
        self.assertEqual(self.service.handoff(self.id)['modeRevision'], 1)

    def test_remote_resume_restarts_handed_over_occurrences_but_not_submissions(self):
        submitted = dict(occurrenceId='occurrence-0', supersedes=[], dateKey='2026-09-22', startPeriod=1, endPeriod=1)
        self.plan['items'].insert(0, submitted)
        self.plan['items'][1].update(startPeriod=2, endPeriod=2)
        self.service.replace_plan(self.id, self.plan)
        self.db.execute("UPDATE la_start_jobs SET state='submitted' WHERE occurrence='occurrence-0'"); self.db.commit()
        self.service.handoff(self.id)
        resumed = self.service.resume_remote(self.id)
        self.assertEqual((resumed['launchMode'], resumed['modeRevision']), ('remote', 2))
        self.assertEqual(self.service.resume_remote(self.id)['modeRevision'], 2)
        self.plan['planRevision'] = 2; self.plan['pushMode'] = 'token'
        self.service.replace_plan(self.id, self.plan)
        states = dict(self.db.execute('SELECT occurrence,state FROM la_start_jobs WHERE device=?', (self.id,)).fetchall())
        self.assertEqual(states, {'occurrence-0': 'submitted', 'occurrence-1': 'pending'})
        self.service.forget(self.id)
        with self.assertRaises(ProtocolError) as error: self.service.resume_remote(self.id)
        self.assertEqual(error.exception.status, 409)

    def test_delete_during_retry_does_not_resurrect(self):
        self.service.replace_plan(self.id, self.plan); self.clock = self.job()['fire_at']
        self.client.on_push = lambda: self.service.forget(self.id)
        self.client.result = {'ok': False, 'status': 503, 'certainty': 'rejected'}
        self.service.dispatch_starts()
        self.assertEqual(self.job()['state'], 'cancelled')
        self.service.forget(self.id)
        self.assertTrue(self.service.status(self.id)['revoked'])
        with self.assertRaises(ProtocolError): self.service.register(self.registration, 'persisted-secret')

    def test_local_recovery_claim_is_once_only(self):
        self.service.replace_plan(self.id, self.plan)
        self.assertTrue(self.service.recovery(self.id, {'occurrenceId': 'occurrence-1'})['mayStart'])
        self.assertFalse(self.service.recovery(self.id, {'occurrenceId': 'occurrence-1'})['mayStart'])
        self.service.materialize(); self.service.dispatch_starts()
        self.assertEqual(self.client.starts, [])

    def test_snapshot_materializes_48_hours_and_rolls_without_upload(self):
        self.plan['items'][0]['dateKey'] = '2026-09-25'
        self.service.replace_plan(self.id, self.plan)
        self.assertIsNone(self.job())
        self.clock += 2 * 86400
        self.service.materialize()
        self.assertIsNotNone(self.job())

    def test_public_end_does_not_depend_on_devices_or_holidays(self):
        self.service.forget(self.id)
        self.db.executescript("CREATE TABLE global_calendar(id INTEGER, adjustments_json TEXT); INSERT INTO global_calendar VALUES(1,'[{\"date\":\"2026-09-22\",\"kind\":\"off\"}]');")
        schedule = normalize_schedule(self.periods, 'Asia/Taipei')
        self.clock = boundaries(schedule, '2026-09-22', 2)[-1][0]
        self.service.plan_broadcasts(); self.service.dispatch_broadcasts()
        received = {channel: payload['aps']['event'] for channel, payload, _ in self.client.broadcasts}
        self.assertEqual(received[self.config['channels']['2']], 'end')
        self.assertEqual(received[self.config['channels']['4']], 'update')
        self.assertNotIn(self.config['channels']['1'], received)

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

    def test_channel_reclamation_obeys_mapping_promise(self):
        self.service.maintain_channels(); self.assertEqual(self.client.deleted, [])
        self.clock += 8 * 86400 + 1
        self.service.maintain_channels()
        self.assertEqual(len(self.client.deleted), 4)
        self.assertEqual(self.service.config(self.query, 'persisted-secret')['status'], 'missingChannels')

    def test_scope_switch_cancels_only_unsubmitted(self):
        self.service.replace_plan(self.id, self.plan)
        self.clock = self.job()['fire_at']; self.service.dispatch_starts()
        self.plan.update(planRevision=2, scheduleScope='scope-2', items=[])
        self.service.replace_plan(self.id, self.plan)
        self.assertEqual(self.job()['state'], 'submitted')

    def test_payload_fields_are_strict_and_overlap_requires_resolution(self):
        for mutate in (lambda p: p.update(courseName='private'), lambda p: p['items'][0].update(teacher='private'), lambda p: p.update(leadMinutes=120), lambda p: p.update(busyIntervals=[{'start': self.clock + 1800, 'end': self.clock + 3600}])):
            plan = copy.deepcopy(self.plan); mutate(plan)
            with self.assertRaises(ProtocolError): self.service.replace_plan(self.id, plan)

    def test_lead_is_clipped_by_prior_busy_time(self):
        self.plan['busyIntervals'] = [{'start': self.clock - 60, 'end': self.clock + 600}]
        events = validate_plan(self.plan, normalize_schedule(self.periods, 'Asia/Taipei'), self.clock)
        self.assertEqual(events[0]['fireAt'], self.clock + 600)

    def test_mapping_requires_a_registered_installation(self):
        before = self.db.execute('SELECT broadcast_until FROM la_schedule_versions').fetchone()[0]
        self.clock += 3600
        for query, secret in ((dict(self.query, deviceID='stranger'), 'persisted-secret'), (self.query, 'wrong'), (self.query, '')):
            with self.assertRaises(ProtocolError) as error: self.service.config(query, secret)
            self.assertEqual(error.exception.status, 403)
        self.assertEqual(self.db.execute('SELECT broadcast_until FROM la_schedule_versions').fetchone()[0], before, 'A refused request extends nothing')
        self.service.forget(self.id)
        with self.assertRaises(ProtocolError): self.service.config(self.query, 'persisted-secret')

    def test_app_environment_timezone_validation(self):
        for query in (dict(self.query, bundleID='other'), dict(self.query, environment='wrong')):
            with self.assertRaises(ProtocolError): self.service.config(query, 'persisted-secret')
        with self.assertRaises(ProtocolError): normalize_schedule(self.periods, 'Not/AZone')

    def test_superseding_submitted_occurrence_cannot_create_duplicate(self):
        self.service.replace_plan(self.id, self.plan); self.clock = self.job()['fire_at']; self.service.dispatch_starts()
        self.plan['planRevision'] = 2
        self.plan['items'][0].update(occurrenceId='replacement', supersedes=['occurrence-1'])
        self.service.replace_plan(self.id, self.plan); self.service.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1)

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


class TokenModeTests(unittest.TestCase):
    """Followed shares: per-activity token pushes. Channel plans must stay exactly as before."""
    setUp = V2Tests.setUp
    job = V2Tests.job
    token = 'ab' * 16
    start, middle, end = 1790035200, 1790038200, 1790041800  # 08:00, 08:50, 09:50 Asia/Taipei

    def activity(self, **changes):
        return dict(dict(token=self.token, dateKey='2026-09-22', refreshAt=[self.start, self.middle], end=self.end), **changes)

    def updates(self):
        return [tuple(row) for row in self.db.execute('SELECT fire_at,event,state FROM la_token_updates ORDER BY fire_at')]

    def test_push_mode_is_optional_and_validated(self):
        schedule = normalize_schedule(self.periods, 'Asia/Taipei')
        for mode in (None, 'channel', 'token'):
            plan = dict(self.plan, **({} if mode is None else {'pushMode': mode}))
            self.assertEqual(len(validate_plan(plan, schedule, self.clock)), 1)
        for mode in ('broadcast', 1, None):
            with self.assertRaises(ProtocolError) as error: validate_plan(dict(self.plan, pushMode=mode), schedule, self.clock)
            self.assertEqual(error.exception.status, 400)

    def test_channel_plan_materializes_exactly_as_before(self):
        from server.live_activity_timeline import digest, public_state
        self.service.replace_plan(self.id, self.plan)
        row = self.db.execute('SELECT digest,snapshot FROM la_v2_devices WHERE id=?', (self.id,)).fetchone()
        self.assertEqual(row['digest'], digest(self.plan))
        self.assertNotIn('pushMode', json.loads(row['snapshot']))
        job = self.job()
        self.assertEqual(job['channel_key'], self.service.key(self.client.bundle_id, 'sandbox', 'school', 'default', self.config['scheduleVersion'], 2))
        expected = {'aps': {'timestamp': self.clock, 'event': 'start', 'attributes-type': 'ScheduleLiveActivityAttributes',
            'attributes': {'semester': '', 'week': 0, 'dateKey': '2026-09-22', 'protocolVersion': 2, 'scheduleScope': 'scope-1',
                'occurrenceId': 'occurrence-1', 'scheduleVersion': self.config['scheduleVersion'], 'reservationStart': self.start - 978307200,
                'reservationEnd': self.end - 978307200, 'reminderDate': self.clock - 978307200},
            'content-state': public_state('2026-09-22', 1, 'upcoming', self.clock), 'stale-date': self.end,
            'alert': {'title': '课程提醒', 'body': '即将上课'}}}
        self.assertEqual(json.loads(job['payload']), expected)
        self.clock = job['fire_at']; self.service.dispatch_starts()
        sent = self.client.starts[0][1]['aps']
        self.assertEqual(sent['input-push-channel'], self.config['channels']['2'])
        self.assertEqual(sent['attributes']['broadcastChannel'], self.config['channels']['2'])
        self.assertNotIn('input-push-token', sent); self.assertNotIn('pushMode', sent['attributes'])
        # An explicit "channel" materializes the same job; only the digest reflects the extra key.
        self.id = self.service.register(dict(self.registration, installationId='installation-2'), 'other-secret')['deviceID']
        self.service.replace_plan(self.id, dict(self.plan, pushMode='channel'))
        self.assertEqual((self.job()['channel_key'], json.loads(self.job()['payload'])), (job['channel_key'], expected))
        self.assertNotEqual(digest(dict(self.plan, pushMode='token')), digest(self.plan))

    def test_token_start_uses_input_push_token_without_channels(self):
        self.clock += 3600 * 24 - 7200  # next day 05:30; mapping promise must not grow
        self.plan.update(coverageStart=self.clock, pushMode='token')
        self.plan['items'][0]['dateKey'] = '2026-09-23'
        promised = self.db.execute('SELECT broadcast_until FROM la_schedule_versions').fetchone()[0]
        self.db.execute("UPDATE la_channels SET state='missing',channel=''"); self.db.commit()
        self.service.replace_plan(self.id, self.plan)
        self.assertEqual(self.db.execute('SELECT broadcast_until FROM la_schedule_versions').fetchone()[0], promised)
        self.assertEqual(self.job()['channel_key'], '')
        self.clock = self.job()['fire_at']; self.service.dispatch_starts()
        token, payload, _ = self.client.starts[0]
        self.assertEqual(token, 'ab12')
        self.assertEqual(payload['aps']['input-push-token'], 1)
        self.assertNotIn('input-push-channel', payload['aps'])
        self.assertNotIn('broadcastChannel', payload['aps']['attributes'])
        self.assertEqual(payload['aps']['attributes']['pushMode'], 'token')
        self.assertEqual(self.job()['state'], 'submitted')

    def test_activity_registration_validation(self):
        result = self.service.register_activity(self.id, 'occurrence-1', self.activity())
        self.assertEqual(result, {'occurrenceId': 'occurrence-1', 'pending': 3})
        self.assertEqual(self.updates(), [(self.start, 'update', 'pending'), (self.middle, 'update', 'pending'), (self.end, 'end', 'pending')])
        self.assertEqual([row[0] for row in self.db.execute('SELECT expires_at FROM la_token_updates ORDER BY fire_at')], [self.middle, self.end, self.end + 60])
        stored = self.db.execute('SELECT token FROM la_activity_tokens').fetchone()[0]
        self.assertNotIn(self.token, stored)
        for bad in (self.activity(courseName='x'), {'token': self.token}, self.activity(token='xyz' * 8), self.activity(token='ab'),
                    self.activity(token='a' * 513), self.activity(refreshAt=[self.middle, self.start]), self.activity(refreshAt=[self.start, self.start]),
                    self.activity(refreshAt=list(range(self.clock, self.clock + 65))), self.activity(refreshAt=[self.clock - 61]),
                    self.activity(refreshAt=[self.end]), self.activity(end=self.clock), self.activity(end=self.clock + 8 * 86400 + 1, refreshAt=[]),
                    self.activity(end=self.clock + 8 * 3600 + 1, refreshAt=[]), self.activity(dateKey='2026-9-22'), self.activity(refreshAt=[{'courseName': 'x'}])):
            with self.assertRaises(ProtocolError) as error: self.service.register_activity(self.id, 'occurrence-1', bad)
            self.assertEqual(error.exception.status, 400)
        self.assertEqual(len(self.service.register_activity(self.id, 'occurrence-1', self.activity(refreshAt=[self.clock - 60]))), 2)
        self.service.handoff(self.id)
        self.assertEqual(self.service.register_activity(self.id, 'occurrence-1', self.activity())['pending'], 3, 'local mode keeps token refreshes')
        self.service.forget(self.id)
        with self.assertRaises(ProtocolError) as error: self.service.register_activity(self.id, 'occurrence-1', self.activity())
        self.assertEqual(error.exception.status, 409)

    def test_replacement_only_touches_unsent_refreshes(self):
        self.service.register_activity(self.id, 'occurrence-1', self.activity())
        self.clock = self.start; self.service.dispatch_token_updates()
        self.service.register_activity(self.id, 'occurrence-1', self.activity(token='cd' * 16, refreshAt=[self.start, self.start + 1800]))
        self.assertEqual(self.updates(), [(self.start, 'update', 'sent'), (self.start + 1800, 'update', 'pending'), (self.end, 'end', 'pending')])
        self.clock = self.start + 1800; self.service.dispatch_token_updates()
        self.assertEqual(self.client.starts[-1][0], 'cd' * 16)

    def test_dispatch_sends_newest_due_refresh_only(self):
        self.service.register_activity(self.id, 'occurrence-1', self.activity())
        self.clock = self.start - 1; self.service.dispatch_token_updates()
        self.assertEqual(self.client.starts, [])
        self.clock = self.start; self.service.dispatch_token_updates()
        token, payload, options = self.client.starts[0]
        self.assertEqual(token, self.token)
        self.assertEqual(payload, {'aps': {'timestamp': self.start, 'event': 'update', 'stale-date': self.start + 60, 'content-state': {
            'broadcastDateKey': '2026-09-22', 'broadcastTimestamp': self.start, 'updatedAt': self.start, 'startDate': self.start, 'endDate': self.start}}})
        self.assertEqual(options, {'environment': 'sandbox', 'push_type': 'liveactivity', 'priority': 10, 'expiration': self.middle,
                                   'collapse_id': 'occurrence-1', 'topic': self.client.bundle_id + '.push-type.liveactivity'})
        self.service.dispatch_token_updates()
        self.assertEqual(len(self.client.starts), 1, 'a sent refresh is never repeated')
        # Offline past both the second refresh and the end: only the end goes out.
        self.clock = self.end + 30; self.service.dispatch_token_updates()
        self.assertEqual(len(self.client.starts), 2)
        aps = self.client.starts[1][1]['aps']
        self.assertEqual((aps['event'], aps['dismissal-date']), ('end', self.end)); self.assertNotIn('stale-date', aps)
        self.assertEqual(self.updates(), [(self.start, 'update', 'sent'), (self.middle, 'update', 'expired'), (self.end, 'end', 'sent')])
        # Two unexpired due refreshes (a retry left behind by a newer one): the older is superseded.
        self.service.register_activity(self.id, 'occurrence-2', self.activity(end=self.end + 3600, refreshAt=[self.end + 60, self.end + 120]))
        self.db.execute("UPDATE la_token_updates SET expires_at=? WHERE occurrence='occurrence-2'", (self.end + 7200,)); self.db.commit()
        self.clock = self.end + 150; self.service.dispatch_token_updates()
        self.assertEqual(self.client.starts[-1][1]['aps']['timestamp'], self.end + 120)
        self.assertEqual(self.updates()[3:5], [(self.end + 60, 'update', 'superseded'), (self.end + 120, 'update', 'sent')])

    def test_expired_refreshes_are_not_sent(self):
        self.service.register_activity(self.id, 'occurrence-1', self.activity())
        self.clock = self.end + 61; self.service.dispatch_token_updates()
        self.assertEqual(self.client.starts, [])
        self.assertEqual({state for _, _, state in self.updates()}, {'expired'})

    def test_invalid_token_cancels_the_activity(self):
        self.service.register_activity(self.id, 'occurrence-1', self.activity())
        self.client.result = {'ok': False, 'status': 410, 'reason': 'Unregistered', 'certainty': 'rejected'}
        self.clock = self.start; self.service.dispatch_token_updates()
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM la_activity_tokens').fetchone()[0], 0)
        self.assertEqual({state for _, _, state in self.updates()}, {'cancelled'})
        self.client.result = {'ok': True, 'status': 200}
        self.service.register_activity(self.id, 'occurrence-2', self.activity())
        self.clock = self.middle; self.service.dispatch_token_updates()
        self.assertEqual([options['collapse_id'] for _, _, options in self.client.starts], ['occurrence-1', 'occurrence-2'])
        self.client.result = {'ok': False, 'status': 400, 'reason': 'BadDeviceToken', 'certainty': 'rejected'}
        self.clock = self.end; self.service.dispatch_token_updates()
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM la_activity_tokens').fetchone()[0], 0)

    def test_throttled_refresh_retries_until_it_expires(self):
        self.service.register_activity(self.id, 'occurrence-1', self.activity())
        self.clock = self.start
        for result in ({'ok': False, 'status': 429, 'certainty': 'rejected'}, {'ok': False, 'status': 503, 'certainty': 'rejected'}, {'ok': False, 'status': 0, 'certainty': 'unknown'}):
            self.client.result = result
            self.service.dispatch_token_updates()
            self.assertEqual(self.updates()[0][2], 'pending')
            self.clock += 4; self.service.dispatch_token_updates()  # still backing off
            self.clock += 60
        self.assertEqual(len(self.client.starts), 3)
        self.client.result = {'ok': True, 'status': 200}
        self.service.dispatch_token_updates()
        self.assertEqual(self.updates()[0][2], 'sent')
        self.client.result = {'ok': False, 'status': 500, 'certainty': 'rejected'}
        self.clock = self.middle; self.service.dispatch_token_updates()
        self.clock = self.end - 1; self.service.dispatch_token_updates()
        self.clock = self.end + 61; self.service.dispatch_token_updates()
        self.assertEqual(self.updates()[1:], [(self.middle, 'update', 'expired'), (self.end, 'end', 'expired')])

    def test_delete_and_forget_stop_refreshes(self):
        self.service.register_activity(self.id, 'occurrence-1', self.activity())
        self.service.register_activity(self.id, 'occurrence-2', self.activity())
        self.assertEqual(self.service.forget_activity(self.id, 'occurrence-1'), {'occurrenceId': 'occurrence-1', 'pending': 0})
        self.service.forget_activity(self.id, 'occurrence-1')
        self.clock = self.start; self.service.dispatch_token_updates()
        self.assertEqual([options['collapse_id'] for _, _, options in self.client.starts], ['occurrence-2'])
        self.service.forget(self.id)
        self.clock = self.middle; self.service.dispatch_token_updates()
        self.assertEqual(len(self.client.starts), 1)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM la_activity_tokens').fetchone()[0], 0)

    def test_token_never_reaches_health_details_or_logs(self):
        import contextlib, io
        self.service.register_activity(self.id, 'occurrence-1', self.activity())
        self.client.result = {'ok': False, 'status': 403, 'reason': 'InvalidProviderToken', 'certainty': 'rejected'}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.clock = self.start; self.service.dispatch_token_updates()
        health = self.service.health()
        self.assertEqual(health['tokenUpdates'], {'failed': 1, 'pending': 2})
        dump = json.dumps(health) + output.getvalue() + json.dumps([dict(row) for row in self.db.execute('SELECT * FROM la_token_updates')])
        self.assertNotIn(self.token, dump)
        self.assertNotIn('courseName', json.dumps(self.client.starts))


if __name__ == '__main__': unittest.main()

class HTTPV2Tests(unittest.TestCase):
    setUp = V2Tests.setUp
    """Exercise the actual Handler integration without starting any APNs worker."""

    def test_http_contract_and_legacy_retirement(self):
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
        # Name server distinctly from the imported http module.
        api = '/v2/live-activity'
        from urllib.parse import urlencode
        mapping = api + '/broadcast-config?' + urlencode(self.query)
        self.assertEqual(request('GET', mapping)[0], 200)
        self.assertEqual(request('GET', mapping, secret='')[0], 403, 'Anonymous callers cannot extend broadcasts')
        self.assertEqual(request('POST', api + '/devices', self.registration, 'wrong')[0], 403)
        self.assertEqual(request('POST', api + '/devices', [1, 2])[0], 400)
        self.assertEqual(request('POST', '/v1/live-activity/devices', {})[0], 426)
        self.assertEqual(request('PUT', api + '/devices/' + self.id + '/plan', self.plan)[0], 200)
        self.assertEqual(request('POST', api + '/devices/' + self.id + '/local-handoff', {})[1]['launchMode'], 'local')
        self.assertEqual(request('PUT', api + '/devices/' + self.id + '/plan', self.plan)[0], 409)
        self.assertEqual(request('POST', api + '/devices/' + self.id + '/remote-resume', {})[1]['launchMode'], 'remote')
        self.assertEqual(request('POST', api + '/devices/' + self.id + '/local-handoff', {})[1]['launchMode'], 'local')
        activity = api + '/devices/' + self.id + '/activities/occurrence-1'
        body = dict(token='ab' * 16, dateKey='2026-09-22', refreshAt=[1790035200], end=1790041800)
        self.assertEqual(request('PUT', activity, body, 'wrong')[0], 403)
        self.assertEqual(request('PUT', activity, dict(body, teacher='x'))[0], 400)
        self.assertEqual(request('PUT', activity, body), (200, {'occurrenceId': 'occurrence-1', 'pending': 2}))
        self.assertEqual(request('DELETE', activity)[0], 200)
        self.assertEqual(request('DELETE', activity)[0], 200)
        self.assertEqual(request('PUT', api + '/devices/' + self.id + '/activities/bad%20id', body)[0], 400)
        self.assertEqual(request('DELETE', api + '/devices/' + self.id)[0], 200)
        self.assertEqual(request('DELETE', api + '/devices/' + self.id)[0], 200)
        self.assertEqual(request('PUT', activity, body)[0], 409)


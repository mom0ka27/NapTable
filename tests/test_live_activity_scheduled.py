"""The server-built schedule: timetable upload, the in-memory plan, the ledger, claims and pushes."""
import copy
import json
import sqlite3
import threading
import unittest

from server.live_activity import LiveActivityService
from server.live_activity_schedule import instant
from server.live_activity_timeline import ProtocolError
from server.live_activity_v2 import Service
from test_live_activity_v2 import APNs, TestVault

from datetime import date

TUESDAY = date(2026, 9, 22)
PERIODS = [{"start": "08:00", "end": "08:50"}, {"start": "09:00", "end": "09:50"},
           {"start": "10:00", "end": "10:50"}, {"start": "11:00", "end": "11:50"}]
SHARE_COLUMNS = ("code TEXT, schedule_scope TEXT, owner TEXT, revoked INTEGER, created_at TEXT, updated_at TEXT, payload_json TEXT, "
                 "class_time_list_json TEXT, term_snapshot_json TEXT, semester_start_monday TEXT, adjustments_json TEXT")


def at(clock, day=TUESDAY):
    return instant(day, clock)


class ScheduledTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:', check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.addCleanup(self.db.close)
        self.clock = at("07:00")
        self.client = APNs()
        self.legacy = LiveActivityService(self.db, threading.RLock(), client=self.client, now=lambda: self.clock)
        self.service = Service(self.legacy, TestVault())
        self.db.executescript("CREATE TABLE school_configs(id TEXT, periods_json TEXT); CREATE TABLE school_terms(school_id TEXT,timezone TEXT,is_current INTEGER);"
                              f"CREATE TABLE shares({SHARE_COLUMNS});")
        self.db.execute('INSERT INTO school_configs VALUES(?,?)', ('school', json.dumps(PERIODS)))
        self.db.execute("INSERT INTO school_terms VALUES('school','Asia/Shanghai',1)")
        self.db.commit()
        self.id = self.service.register({'installationId': 'installation-1', 'bundleID': self.client.bundle_id,
                                         'environment': 'sandbox', 'startToken': 'ab12cd34'}, 'persisted-secret')['deviceID']
        self.body = {"revision": 1, "settings": {"leadMinutes": 30},
                     "own": {"scope": "own-scope", "schoolID": "school", "periods": PERIODS, "semesterStartMonday": "2026-09-07",
                             "weekCount": 18, "adjustments": [],
                             "courses": [{"id": "math", "day": 2, "first": 1, "last": 2, "weeks": []},
                                         {"id": "english", "day": 3, "first": 3, "last": 3, "weeks": []}]}}

    def jobs(self, state=None, service=None):
        """Today's and tomorrow's occurrences as the plan holds them, with their ledger state."""
        service = service or self.service
        ledger = dict(self.db.execute("SELECT occurrence,state FROM la_starts WHERE device=?", (self.id,)).fetchall())
        rows = [dict(occurrence=item.id, day=day.isoformat(), fire_at=item.fire_at, expires_at=item.end, refresh=item.refresh,
                     alerts=item.alerts, state=ledger.get(item.id, 'pending'))
                for day, items in service.plans.get(self.id, {}).items() for item in items]
        return sorted((row for row in rows if state is None or row['state'] == state), key=lambda row: row['fire_at'])

    def ledger(self):
        return dict(self.db.execute("SELECT occurrence,state FROM la_starts WHERE device=?", (self.id,)).fetchall())

    def restart(self):
        return Service(self.legacy, TestVault())

    def payload(self, row):
        """The start push of an occurrence, built as dispatch builds it."""
        with self.service.transaction() as db:
            occurrence, stored, texts, scope = self.service._resolve(db, self.id, row['occurrence'], date.fromisoformat(row['day']))
            return self.service._payload(occurrence, stored, texts, scope, 'channel-id')

    def channel_key(self, row):
        with self.service.transaction() as db:
            occurrence, stored, _, _ = self.service._resolve(db, self.id, row['occurrence'], date.fromisoformat(row['day']))
            owner = db.execute("SELECT * FROM la_v2_devices WHERE id=?", (self.id,)).fetchone()
            return self.service._channel(db, owner, stored, occurrence)[0]

    def upload(self, **changes):
        body = copy.deepcopy(self.body)
        body.update(changes)
        return self.service.put_timetable(self.id, body)

    def share(self, code='SHARE1', scope='share-scope', updated='2026-09-20T00:00:00', courses=None, revoked=0):
        courses = courses if courses is not None else [
            {"id": 7, "name": "高数", "teacher": "王", "classroom": "A101", "week_time": 2, "start_time": 1, "time_count": 0, "weeks": []}]
        self.db.execute("INSERT INTO shares VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                        (code, scope, 'A', revoked, updated, updated, json.dumps(courses, ensure_ascii=False),
                         json.dumps([{"start": "09:30", "end": "10:30"}, {"start": "14:00", "end": "15:00"}]),
                         json.dumps({"weekCount": 18}), "2026-09-07", "[]"))
        self.db.commit()

    # MARK: Upload

    def test_upload_builds_today_and_tomorrow_on_the_school_channel(self):
        result = self.upload()
        self.assertEqual((result['pushMode'], result['pendingCount'], result['conflicts']), ('channel', 2, []))
        today, tomorrow = self.jobs()
        self.assertEqual((today['day'], today['fire_at'], today['expires_at']), ("2026-09-22", at("07:30"), at("09:50")))
        self.assertEqual(tomorrow['day'], "2026-09-23")
        self.assertTrue(self.channel_key(today).endswith(':end-period-2'))
        # My own courses travel as the time window alone; the phone renders them itself.
        attributes = self.payload(today)['aps']['attributes']
        self.assertEqual((attributes['reservationStart'] + 978307200, attributes['reservationEnd'] + 978307200), (at("08:00"), at("09:50")))
        self.assertEqual(attributes['broadcastChannel'], 'channel-id')
        for field in ('frames', 'shared', 'pushMode'):
            self.assertNotIn(field, attributes)
        # A mapping the school's bells do not match falls back to per-activity pushes.
        other = copy.deepcopy(self.body['own'])
        other['periods'] = [dict(period, start="07:55") if index == 0 else period for index, period in enumerate(PERIODS)]
        self.assertEqual(self.upload(revision=2, own=other)['pushMode'], 'token')
        self.assertEqual(self.payload(self.jobs()[0])['aps']['input-push-token'], 1)

    def test_upload_keeps_only_what_the_schedule_needs(self):
        for broken in ({"settings": {"leadMinutes": 45}}, {"settings": {"leadMinutes": 30, "sharedLeadMinutes": 20}},
                       {"follow": {"scope": "x"}}, {"revision": 0}):
            with self.assertRaises(ProtocolError):
                self.upload(**broken)
        named = copy.deepcopy(self.body['own'])
        named['courses'][0].update(name='高数', teacher='王')
        self.upload(own=named, timeZone="Asia/Shanghai", settings={"leadMinutes": 30, "persistent": True})
        stored = json.loads(self.db.execute("SELECT body FROM la_timetables").fetchone()[0])
        self.assertNotIn('高数', json.dumps(stored, ensure_ascii=False))
        self.assertNotIn('timeZone', stored)
        self.assertEqual(stored['settings'], {"leadMinutes": 30, "perPeriod": False})
        # Unknown fields do not change the revision's content.
        self.upload()
        with self.assertRaises(ProtocolError) as error:
            self.upload(settings={"leadMinutes": 60})
        self.assertEqual(error.exception.status, 409)

    def test_rebuild_keeps_the_ledger_and_never_starts_a_course_twice(self):
        self.upload()
        today = self.jobs()[0]
        self.service.claim(self.id, {"slots": 1})
        # A new lead moves the reminder but keeps the occurrence and its claim.
        self.upload(revision=2, settings={"leadMinutes": 15})
        moved = self.jobs()[0]
        self.assertEqual((moved['occurrence'], moved['state'], moved['fire_at']), (today['occurrence'], 'local', at("07:45")))
        self.assertEqual(self.db.execute("SELECT fire_at FROM la_starts").fetchone()[0], at("07:45"))
        # Once started, a changed course may not start again beside it.
        self.db.execute("UPDATE la_starts SET state='submitted'"); self.db.commit()
        longer = copy.deepcopy(self.body['own'])
        longer['courses'][0]['last'] = 3
        self.upload(revision=3, own=longer)
        self.assertEqual([row['day'] for row in self.jobs()], ["2026-09-23"])
        self.assertEqual(self.ledger(), {today['occurrence']: 'submitted'})
        # A claimed course that is dropped leaves the phone's reservation to be undone.
        tomorrow = self.service.claim(self.id, {"slots": 1})['claims'][0]['occurrenceId']
        self.assertEqual(self.ledger()[tomorrow], 'local')
        dropped = copy.deepcopy(longer)
        dropped['courses'] = dropped['courses'][:1]
        self.upload(revision=4, own=dropped)
        self.assertEqual((self.jobs(), self.ledger()), ([], {today['occurrence']: 'submitted'}))

    def test_starts_of_the_old_plan_carry_over_and_are_not_repeated(self):
        self.db.execute("CREATE TABLE la_start_jobs (device TEXT NOT NULL, occurrence TEXT NOT NULL, revision INTEGER NOT NULL, scope TEXT NOT NULL, "
                        "channel_key TEXT NOT NULL, fire_at REAL NOT NULL, expires_at REAL NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending', "
                        "attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0, detail TEXT NOT NULL DEFAULT '', PRIMARY KEY(device,occurrence))")
        for occurrence, state in (('client-uuid', 'submitted'), ('handed-over', 'localTaken'), ('queued', 'pending')):
            self.db.execute("INSERT INTO la_start_jobs(device,occurrence,revision,scope,channel_key,fire_at,expires_at,payload,state) VALUES(?,?,?,?,?,?,?,?,?)",
                            (self.id, occurrence, 1, 'own-scope', '', at("06:50"), at("09:50"), '{}', state))
        self.db.execute("CREATE TABLE la_token_updates (device TEXT)"); self.db.commit()
        self.service = self.restart()
        self.assertEqual(self.ledger(), {'client-uuid': 'submitted', 'handed-over': 'localTaken'})
        self.assertEqual(self.db.execute("SELECT day FROM la_starts WHERE occurrence='client-uuid'").fetchone()[0], "2026-09-22")
        tables = {row[0] for row in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertFalse({'la_start_jobs', 'la_token_updates'} & tables)
        self.upload()
        self.assertEqual([row['day'] for row in self.jobs()], ["2026-09-23"])

    def test_conflicts_are_reported_for_the_term(self):
        clashing = copy.deepcopy(self.body['own'])
        clashing['courses'].append({"id": "physics", "day": 2, "first": 2, "last": 2, "weeks": [3]})
        result = self.upload(own=clashing)
        self.assertEqual([item['id'] for item in result['conflicts']], ["2026-09-22:2"])
        self.assertEqual([row['day'] for row in self.jobs()], ["2026-09-23"])
        resolved = self.upload(revision=2, own=clashing, conflicts={"2026-09-22:2": "physics"})
        self.assertEqual(len(resolved['conflicts']), 1)
        self.assertEqual([row['day'] for row in self.jobs()], ["2026-09-22", "2026-09-22", "2026-09-23"])

    # MARK: Following a share

    def test_following_merges_both_tables_with_separate_leads(self):
        self.share()
        result = self.upload(follow={"share": "share1"}, settings={"leadMinutes": 60, "sharedLeadMinutes": 15})
        self.assertEqual((result['pushMode'], result['following']), ('token', True))
        merged = self.jobs()[0]
        # Mine 08:00–09:50 reminds at 07:00; theirs 09:30–10:30 joins at 09:15.
        self.assertEqual((merged['fire_at'], merged['expires_at']), (at("07:00"), at("10:30")))
        payload = self.payload(merged)
        attributes = payload['aps']['attributes']
        self.assertEqual(attributes['scheduleScope'], 'share-scope')
        # The phone names the share's timetable itself; its activities carry that name.
        self.upload(revision=2, follow={"share": "share1", "scope": "phone-scope"}, settings={"leadMinutes": 60, "sharedLeadMinutes": 15})
        self.assertEqual(self.payload(self.jobs()[0])['aps']['attributes']['scheduleScope'], 'phone-scope')
        self.upload(revision=3, follow={"share": "share1"}, settings={"leadMinutes": 60, "sharedLeadMinutes": 15})
        # Their class travels whole, in case the phone's copy of the share is older.
        self.assertEqual(attributes['shared'], [{"course": "7", "first": 1, "last": 1, "start": at("09:30"), "end": at("10:30"),
                                                 "name": "高数", "teacher": "王", "location": "A101"}])
        self.assertLess(len(json.dumps(payload, ensure_ascii=False).encode()), 1500)
        self.assertEqual(merged['alerts'], (at("09:15"),))
        self.assertNotIn('高数', json.dumps(json.loads(self.db.execute("SELECT body FROM la_timetables").fetchone()[0])))
        with self.assertRaises(ProtocolError) as error:
            self.upload(revision=4, follow={"share": "NOPE"})
        self.assertEqual(error.exception.status, 404)

    def test_a_changed_or_revoked_share_rebuilds_its_followers(self):
        self.share()
        self.upload(follow={"share": "SHARE1"}, settings={"leadMinutes": 30, "sharedLeadMinutes": 30})
        self.service.follow_shares()
        before = {row['occurrence'] for row in self.jobs()}
        # The publisher moves the class to the afternoon and rotates the code.
        self.db.execute("UPDATE shares SET revoked=1"); self.db.commit()
        self.share(code='SHARE2', updated='2026-09-22T06:00:00', courses=[
            {"id": 7, "name": "高数", "week_time": 2, "start_time": 2, "time_count": 0, "weeks": []}])
        self.service.follow_shares()
        today = [row for row in self.jobs() if row['day'] == '2026-09-22']
        self.assertEqual([(row['fire_at'], row['expires_at']) for row in today], [(at("07:30"), at("09:50")), (at("13:30"), at("15:00"))])
        self.assertNotEqual({row['occurrence'] for row in self.jobs()}, before)
        # Revoked for good: only my own courses remain.
        self.db.execute("UPDATE shares SET revoked=1"); self.db.commit()
        self.service.follow_shares()
        self.assertEqual(['shared' in self.payload(row)['aps']['attributes'] for row in self.jobs()], [False, False])
        self.service.follow_shares()

    # MARK: Claims, tokens and dispatch

    def test_claims_hand_the_nearest_reminders_to_the_phone(self):
        self.upload()
        claimed = self.service.claim(self.id, {"slots": 1})['claims']
        self.assertEqual([item['dateKey'] for item in claimed], ["2026-09-22"])
        self.assertEqual((claimed[0]['reminder'], claimed[0]['start'], claimed[0]['end']), (at("07:30"), at("08:00"), at("09:50")))
        self.assertEqual((claimed[0]['pushMode'], claimed[0]['shared']), ('channel', []))
        # Claimed reminders stay with the phone; asking again returns them with the next one.
        again = self.service.claim(self.id, {"slots": 1})['claims']
        self.assertEqual([item['dateKey'] for item in again], ["2026-09-22", "2026-09-23"])
        self.clock = at("07:31")
        self.service.dispatch_starts()
        self.assertEqual(self.client.starts, [])
        # A reservation the phone could not make goes back to the server.
        self.assertTrue(self.service.release(self.id, claimed[0]['occurrenceId'])['released'])
        self.service.maintain_channels()
        self.service.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1)
        payload = self.client.starts[0][1]
        self.assertEqual(payload['aps']['input-push-channel'], payload['aps']['attributes']['broadcastChannel'])
        # A reminder due within 30 seconds is not worth racing for.
        self.clock = at("09:30", date(2026, 9, 23)) - 20
        self.service.release(self.id, again[1]['occurrenceId'])
        self.assertEqual(self.service.claim(self.id, {"slots": 4})['claims'], [])
        with self.assertRaises(ProtocolError):
            self.service.claim(self.id, {"slots": 99})

    def test_a_token_alone_queues_the_scheduled_refreshes(self):
        self.share()
        self.upload(follow={"share": "SHARE1"}, settings={"leadMinutes": 60, "sharedLeadMinutes": 15})
        merged = self.jobs()[0]
        result = self.service.register_token(self.id, merged['occurrence'], {"token": "abcdef0123456789"})
        redraws = self.service.redraws[(self.id, merged['occurrence'])]
        self.assertEqual(redraws.stamps, merged['refresh'] + (at("10:30"),))
        self.assertEqual(redraws.alerts, {at("09:15")})
        self.assertEqual(result['pending'], len(redraws.stamps))
        self.assertNotIn("abcdef0123456789", self.db.execute("SELECT token FROM la_activity_tokens").fetchone()[0])
        for bad in ({"token": "xyz" * 8}, {"token": "ab"}, {"token": "abcdef0123456789", "refreshAt": []}):
            with self.assertRaises(ProtocolError) as error:
                self.service.register_token(self.id, merged['occurrence'], bad)
            self.assertEqual(error.exception.status, 400)
        with self.assertRaises(ProtocolError) as error:
            self.service.register_token(self.id, 'missing', {"token": "abcdef0123456789"})
        self.assertEqual(error.exception.status, 404)
        # The share moves after the start: the refreshes follow, the start stays history.
        self.db.execute("INSERT INTO la_starts VALUES(?,?,?,?,?,?,'')", (self.id, merged['occurrence'], merged['day'], 'submitted', merged['fire_at'], merged['expires_at']))
        self.db.execute("UPDATE shares SET updated_at='later', payload_json=?", (json.dumps([
            {"id": 7, "name": "高数", "week_time": 2, "start_time": 2, "time_count": 0, "weeks": []}]),))
        self.db.commit()
        self.service.follow_shares()
        after = self.service.redraws[(self.id, merged['occurrence'])]
        self.assertEqual((after.stamps[-1], after.alerts), (at("09:50"), frozenset()))
        self.assertEqual(self.jobs()[0]['state'], 'submitted')

    def test_a_row_its_timetable_no_longer_has_is_not_sent(self):
        self.upload()
        self.service.maintain_channels()
        # The stored timetable changes without a rebuild (as between two runs).
        self.db.execute("UPDATE la_timetables SET body=?", (json.dumps(dict(self.body, own=dict(self.body['own'], courses=[]))),)); self.db.commit()
        self.clock = at("07:31")
        self.service.dispatch_starts()
        self.assertEqual((self.client.starts, self.ledger()), ([], {}))

    # MARK: Restarts and failures

    def test_a_restart_rebuilds_the_plan_and_sends_only_what_is_still_due(self):
        self.upload()
        self.service.maintain_channels()
        self.clock = at("07:31")
        self.client.result = {'ok': False, 'status': 0, 'certainty': 'unknown'}
        self.service.dispatch_starts()
        restarted = self.restart()
        self.assertEqual([row['state'] for row in self.jobs(service=restarted)], ['submissionUnknown', 'pending'])
        restarted.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1, 'a start whose fate is unknown never goes again')
        # Down past tomorrow's reminder: it still goes once the server is back, until the course ends.
        self.client.result = {'ok': True, 'status': 200}
        self.clock = at("10:10", date(2026, 9, 23))
        self.restart().dispatch_starts()
        self.assertEqual(len(self.client.starts), 2)

    def test_a_crash_after_the_intent_leaves_the_start_unknown(self):
        self.upload()
        self.db.execute("INSERT INTO la_starts VALUES(?,?,?,?,?,?,'')", (self.id, self.jobs()[0]['occurrence'], "2026-09-22", 'submitting', at("07:30"), at("09:50")))
        self.db.commit()
        restarted = self.restart()
        self.assertEqual(self.jobs(service=restarted)[0]['state'], 'submissionUnknown')

    def test_a_claim_survives_a_restart(self):
        self.upload()
        self.service.maintain_channels()
        self.service.claim(self.id, {"slots": 1})
        self.clock = at("07:31")
        self.service.dispatch_starts()
        self.restart().dispatch_starts()
        self.assertEqual(self.client.starts, [])

    def test_a_rolled_back_rebuild_leaves_the_plan_alone(self):
        self.upload()
        before = self.jobs()
        self.db.execute("UPDATE la_timetables SET body=?", (json.dumps(dict(self.body, own=dict(self.body['own'], courses=[]))),)); self.db.commit()
        with self.assertRaises(RuntimeError):
            with self.service.transaction() as db:
                self.service._rebuild(db, self.id)
                raise RuntimeError()
        self.assertEqual(self.jobs(), before)

    def test_nightly_builds_the_new_tomorrow_once(self):
        self.upload()
        # Plans built on start (or upload) are fresh: the first run only does the upkeep.
        self.service.nightly()
        self.assertEqual({row['day'] for row in self.jobs()}, {"2026-09-22", "2026-09-23"})
        self.assertEqual(self.db.execute("SELECT value FROM la_v2_meta WHERE key='nightly'").fetchone()[0], "2026-09-22")
        self.db.execute("INSERT INTO la_starts VALUES(?,?,?,?,?,?,'')", (self.id, 'old', "2026-09-22", 'submitted', at("07:30"), at("09:50")))
        self.db.commit()
        # Midnight passes: Tuesday leaves the plan; Thursday has no class.
        self.clock = instant(date(2026, 9, 23), "00:01")
        self.service.nightly()
        self.assertEqual([row['day'] for row in self.jobs()], ["2026-09-23"])
        self.assertEqual(self.db.execute("SELECT value FROM la_v2_meta WHERE key='nightly'").fetchone()[0], "2026-09-23")
        self.clock = instant(date(2026, 9, 24), "00:01")
        self.db.execute("UPDATE la_timetables SET body=?", (json.dumps(dict(self.body, own=dict(self.body['own'], courses=self.body['own']['courses'] + [
            {"id": "physics", "day": 5, "first": 1, "last": 1, "weeks": []}]))),)); self.db.commit()
        self.service.nightly()
        self.assertEqual([row['day'] for row in self.jobs()], ["2026-09-25"])
        self.assertEqual(self.ledger(), {}, 'finished starts go a day after they end')
        promised = self.db.execute("SELECT broadcast_until FROM la_schedule_versions").fetchone()[0]
        self.assertEqual(promised, self.clock + 8 * 86400)

    def test_forget_drops_the_timetable(self):
        self.upload()
        self.service.forget(self.id)
        self.assertIsNone(self.db.execute("SELECT 1 FROM la_timetables").fetchone())
        self.assertEqual(self.jobs(), [])
        self.service.nightly()
        with self.assertRaises(ProtocolError):
            self.upload(revision=2)


class RedrawTests(unittest.TestCase):
    """Token mode: the refreshes of an activity already on screen, queued in memory."""
    setUp = ScheduledTests.setUp
    upload, share, jobs, restart = ScheduledTests.upload, ScheduledTests.share, ScheduledTests.jobs, ScheduledTests.restart
    token = 'ab' * 16

    def started(self, token=None):
        """Follow the share and register the merged activity: 07:00–10:30, refreshing at
        08:00, 09:15 (their class joins, with its reminder), 09:30 and 09:50."""
        self.share()
        self.upload(follow={"share": "SHARE1"}, settings={"leadMinutes": 60, "sharedLeadMinutes": 15})
        self.occurrence = self.jobs()[0]['occurrence']
        self.service.register_token(self.id, self.occurrence, {"token": token or self.token})

    def sent(self):
        return [(payload['aps']['timestamp'], payload['aps']['event'], 'alert' in payload['aps']) for _, payload, _ in self.client.starts]

    def test_each_refresh_goes_once_and_the_joining_class_sounds_its_reminder(self):
        self.started()
        for clock in ("07:59", "08:00", "08:00", "09:15", "09:30", "09:50", "10:30"):
            self.clock = at(clock)
            self.service.dispatch_token_updates()
        self.assertEqual(self.sent(), [(at("08:00"), 'update', False), (at("09:15"), 'update', True), (at("09:30"), 'update', False),
                                       (at("09:50"), 'update', False), (at("10:30"), 'end', False)])
        token, payload, options = self.client.starts[0]
        self.assertEqual(token, self.token)
        self.assertEqual(payload, {'aps': {'timestamp': at("08:00"), 'event': 'update', 'stale-date': at("08:00") + 60, 'content-state': {
            'broadcastDateKey': '2026-09-22', 'broadcastTimestamp': at("08:00"), 'updatedAt': at("08:00"), 'startDate': at("08:00"), 'endDate': at("08:00")}}})
        self.assertEqual(options, {'environment': 'sandbox', 'push_type': 'liveactivity', 'priority': 10, 'expiration': at("09:15"),
                                   'collapse_id': self.occurrence[:64], 'topic': self.client.bundle_id + '.push-type.liveactivity'})
        self.assertEqual(self.client.starts[-1][1]['aps']['dismissal-date'], at("10:30"))
        self.assertNotIn((self.id, self.occurrence), self.service.redraws, 'done once the end went')

    def test_offline_through_refreshes_sends_the_newest_only(self):
        self.started()
        self.clock = at("09:40")
        self.service.dispatch_token_updates()
        self.clock = at("10:30") + 30
        self.service.dispatch_token_updates()
        self.assertEqual(self.sent(), [(at("09:30"), 'update', False), (at("10:30"), 'end', False)])

    def test_an_end_long_past_is_not_sent(self):
        self.started()
        self.clock = at("10:30") + 61
        self.service.dispatch_token_updates()
        self.assertEqual(self.client.starts, [])
        self.assertEqual(self.service.redraws, {})

    def test_activities_refreshing_together_leave_as_one_batch(self):
        self.started()
        other = self.service.register({'installationId': 'installation-2', 'bundleID': self.client.bundle_id, 'environment': 'sandbox'}, 'other')['deviceID']
        mine = self.id
        self.id = other
        self.upload(follow={"share": "SHARE1"}, settings={"leadMinutes": 60, "sharedLeadMinutes": 15})
        self.service.register_token(other, self.jobs()[0]['occurrence'], {"token": 'cd' * 16})
        self.clock = at("08:00"); self.client.batches = []
        self.service.dispatch_token_updates()
        self.assertEqual(self.client.batches, [2], 'A bell costs one round trip')
        self.assertEqual(sorted(token for token, _, _ in self.client.starts), ['ab' * 16, 'cd' * 16])
        self.id = mine

    def test_an_invalid_token_ends_the_activity(self):
        self.started()
        self.client.result = {'ok': False, 'status': 410, 'reason': 'Unregistered', 'certainty': 'rejected'}
        self.clock = at("08:00"); self.service.dispatch_token_updates()
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM la_activity_tokens').fetchone()[0], 0)
        self.assertEqual(self.service.redraws, {})
        self.clock = at("09:15"); self.service.dispatch_token_updates()
        self.assertEqual(len(self.client.starts), 1)

    def test_a_throttled_refresh_retries_until_the_next_replaces_it(self):
        self.started()
        self.clock = at("08:00")
        for result in ({'ok': False, 'status': 429, 'certainty': 'rejected'}, {'ok': False, 'status': 503, 'certainty': 'rejected'}, {'ok': False, 'status': 0, 'certainty': 'unknown'}):
            self.client.result = result
            self.service.dispatch_token_updates()
            self.clock += 4; self.service.dispatch_token_updates()  # still backing off
            self.clock += 60
        self.assertEqual([stamp for stamp, _, _ in self.sent()], [at("08:00")] * 3)
        self.client.result = {'ok': True, 'status': 200}
        self.service.dispatch_token_updates()
        self.assertEqual(len(self.client.starts), 4)
        # Refused for good: the next refresh still goes.
        self.client.result = {'ok': False, 'status': 400, 'reason': 'BadPayload', 'certainty': 'rejected'}
        self.clock = at("09:15"); self.service.dispatch_token_updates()
        self.client.result = {'ok': True, 'status': 200}
        self.clock = at("09:30"); self.service.dispatch_token_updates()
        self.assertEqual([stamp for stamp, _, _ in self.sent()][-2:], [at("09:15"), at("09:30")])

    def test_forgetting_stops_refreshes(self):
        self.started()
        self.assertEqual(self.service.forget_activity(self.id, self.occurrence), {'occurrenceId': self.occurrence, 'pending': 0})
        self.service.forget_activity(self.id, self.occurrence)
        self.clock = at("08:00"); self.service.dispatch_token_updates()
        self.assertEqual(self.client.starts, [])
        self.service.register_token(self.id, self.occurrence, {"token": self.token})
        self.service.forget(self.id)
        self.clock = at("09:15"); self.service.dispatch_token_updates()
        self.assertEqual(self.client.starts, [])
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM la_activity_tokens').fetchone()[0], 0)
        with self.assertRaises(ProtocolError) as error:
            self.service.register_token(self.id, self.occurrence, {"token": self.token})
        self.assertEqual(error.exception.status, 409)

    def test_a_restart_picks_up_where_it_left_off(self):
        self.started()
        self.clock = at("08:00"); self.service.dispatch_token_updates()
        # Down from before 09:15 to after 09:30: the current display goes once, then the rest.
        self.clock = at("09:31")
        restarted = self.restart()
        restarted.dispatch_token_updates()
        self.clock = at("09:50"); restarted.dispatch_token_updates()
        self.assertEqual([stamp for stamp, _, _ in self.sent()], [at("08:00"), at("09:30"), at("09:50")])

    def test_the_token_never_reaches_health_or_logs(self):
        import contextlib, io
        self.started()
        self.client.result = {'ok': False, 'status': 403, 'reason': 'InvalidProviderToken', 'certainty': 'rejected'}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.clock = at("08:00"); self.service.dispatch_token_updates()
        health = self.service.health()
        self.assertEqual(health['tokenUpdates'], {'activities': 1, 'pending': 4})
        self.assertNotIn(self.token, json.dumps(health) + output.getvalue())


if __name__ == "__main__":
    unittest.main()

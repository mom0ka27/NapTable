import os
import tempfile
import threading
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from server.naptable_server import Store
from tests.server_support import JSONClientMixin, LiveServer


class UsageTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = Store(self.directory.name + '/usage.sqlite3')
        self.http = LiveServer(self.store)
        self.env = patch.dict(os.environ, {'NAPTABLE_ADMIN_TOKEN': 'usage-admin'})
        self.env.start()
        self.device = str(uuid.uuid4())
        self.secret = 'a' * 64
        self.value = dict(consentVersion=1, schoolID='nju', systemName='iOS', systemVersion='26.0',
                          deviceModel='iPhone17,1', appVersion='1.0')

    def tearDown(self):
        self.http.shutdown()
        self.store.close(); self.directory.cleanup(); self.env.stop()

    def report(self, value=None, device=None, secret=None, expect=200):
        return self.req('POST', '/v1/usage/devices/' + (device or self.device),
                        self.value if value is None else value,
                        {'X-Device-Secret': self.secret if secret is None else secret}, expect)

    def stats(self):
        return self.req('GET', '/v1/admin/stats', headers={'X-Admin-Token': 'usage-admin'})

    def test_dedup_update_school_and_distributions_without_live_activity(self):
        self.report(); self.report()
        stats = self.stats()
        self.assertEqual(stats['totalUsers'], 1)
        self.assertEqual(stats['schools'][0]['users'], 1)
        self.assertEqual(stats['systemVersions'], [{'name': 'iOS 26.0', 'users': 1}])
        self.assertEqual(stats['schools'][0]['deviceModels'], [{'name': 'iPhone 16 Pro', 'users': 1}])
        self.report(dict(self.value, schoolID='', systemVersion='26.1'))
        stats = self.stats()
        self.assertEqual(stats['totalUsers'], 1)
        self.assertEqual(stats['unassignedUsers'], 1)
        self.assertEqual(stats['schools'][0]['users'], 0)
        self.assertEqual(stats['systemVersions'][0]['name'], 'iOS 26.1')
        self.report(device=str(uuid.uuid4()))
        self.assertEqual(self.stats()['totalUsers'], 2)

    def test_auth_consent_validation_and_no_course_payloads(self):
        self.req('GET', '/v1/admin/stats', expect=403)
        for value in [None, [], dict(self.value, consentVersion=0), dict(self.value, consentVersion=True),
                      dict(self.value, courses=[{'name': 'private'}]), dict(self.value, schoolID='missing'),
                      dict(self.value, deviceModel='x' * 81)]:
            self.req('POST', '/v1/usage/devices/' + self.device, value,
                     {'X-Device-Secret': self.secret}, expect=400)
        self.report(secret='', expect=400)
        self.report()
        self.report(secret='b' * 64, expect=403)
        self.assertEqual(self.stats()['totalUsers'], 1)
        with self.store.lock:
            row = self.store.db.execute('SELECT * FROM usage_devices').fetchone()
            self.assertNotEqual(row['secret_hash'], self.secret)

    def test_thirteen_reports_count_once_even_when_properties_change(self):
        for index in range(13):
            self.report(dict(self.value, schoolID='nju' if index % 2 == 0 else '',
                             appVersion=f'1.{index}', systemVersion=f'26.{index}'))
        stats = self.stats()
        self.assertEqual((stats['totalUsers'], stats['todayUsers'], stats['newUsersToday'], stats['weeklyUsers']), (1, 1, 1, 1))
        self.assertEqual(stats['schools'][0]['users'], 1)
        self.assertEqual(stats['appVersions'], [{'name': '1.12', 'users': 1}])
        row = self.store.db.execute('SELECT active,new FROM usage_daily').fetchone()
        self.assertEqual(tuple(row), (1, 1))

    def test_model_names_apply_to_existing_rows_and_group_hardware_variants(self):
        # Simulate raw rows written by older clients, before a mapping existed.
        for model in ('iPhone18,4', 'iPhone11,4', 'iPhone11,6', 'iPad13,18', 'iPhone99,1',
                      'Simulator (iPhone18,4)', 'Mac14,2'):
            self.report(dict(self.value, deviceModel=model), device=str(uuid.uuid4()))
        expected = [{'name': name, 'users': count} for name, count in (
            ('iPhone XS Max', 2), ('Mac14,2', 1), ('Simulator (iPhone Air)', 1),
            ('iPad (10th generation)', 1), ('iPhone Air', 1), ('iPhone99,1', 1))]
        stats = self.stats()
        self.assertEqual(stats['totalUsers'], 7, 'Matching model names do not identify the same phone')
        self.assertEqual(stats['deviceModels'], expected)
        self.assertEqual(stats['schools'][0]['deviceModels'], expected)
        stored = {row[0] for row in self.store.db.execute('SELECT device_model FROM usage_devices')}
        self.assertIn('iPhone18,4', stored, 'Keep raw identifiers for future mapping corrections')

    def test_thirty_day_window_and_ninety_day_retention(self):
        self.report()
        old = str(uuid.uuid4())
        self.report(device=old)
        with self.store.lock, self.store.db:
            self.store.db.execute('UPDATE usage_devices SET last_seen=? WHERE installation_id=?',
                ((datetime.now(timezone.utc) - timedelta(days=31)).isoformat(), self.device))
            self.store.db.execute('UPDATE usage_devices SET last_seen=? WHERE installation_id=?',
                ((datetime.now(timezone.utc) - timedelta(days=91)).isoformat(), old))
        self.assertEqual(self.stats()['totalUsers'], 0)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM usage_devices').fetchone()[0], 1)
        self.report()
        self.assertEqual(self.stats()['totalUsers'], 1)

    def test_deleted_school_and_reopen(self):
        self.report()
        self.store.delete_school('nju')
        stats = self.stats()
        self.assertEqual(stats['schools'], [])
        self.assertEqual(stats['unassignedUsers'], 1)
        reopened = Store(self.directory.name + '/usage.sqlite3')
        try:
            self.assertEqual(reopened.usage_stats()['totalUsers'], 1)
        finally:
            reopened.close()

    def test_today_week_new_and_daily_counts(self):
        self.report(); self.report()
        stats = self.stats()
        self.assertEqual((stats['todayUsers'], stats['newUsersToday'], stats['weeklyUsers']), (1, 1, 1))
        self.assertEqual(len(stats['daily']), 30)
        self.assertEqual(stats['daily'][-1], {'date': datetime.now(timezone(timedelta(hours=8))).date().isoformat(),
                                              'users': 1, 'newUsers': 1})
        self.assertEqual(stats['schools'][0]['todayUsers'], 1)
        self.assertEqual(stats['appVersions'], [{'name': '1.0', 'users': 1}])
        # Seen three days ago and back today: active again, not new.
        with self.store.lock, self.store.db:
            self.store.db.execute('UPDATE usage_devices SET first_seen=?,last_seen=?',
                                  ((datetime.now(timezone.utc) - timedelta(days=3)).isoformat(),) * 2)
            self.store.db.execute('DELETE FROM usage_daily')
        stats = self.stats()
        self.assertEqual((stats['todayUsers'], stats['newUsersToday'], stats['weeklyUsers']), (0, 0, 1))
        self.report()
        self.assertEqual((self.stats()['todayUsers'], self.stats()['newUsersToday']), (1, 0))
        with self.store.lock:
            row = self.store.db.execute('SELECT * FROM usage_daily').fetchone()
        self.assertEqual((row['active'], row['new']), (1, 0))

    def test_daily_table_holds_counts_only_and_keeps_yesterday(self):
        self.report()
        yesterday = (datetime.now(timezone(timedelta(hours=8))) - timedelta(days=1)).date().isoformat()
        with self.store.lock, self.store.db:
            self.store.db.execute("INSERT INTO usage_daily VALUES (?,5,2)", (yesterday,))
            self.store.db.execute("INSERT INTO usage_daily VALUES ('2000-01-01',9,9)")
            columns = [row[1] for row in self.store.db.execute('PRAGMA table_info(usage_daily)')]
        self.assertEqual(columns, ['day', 'active', 'new'])
        stats = self.stats()
        self.assertEqual(stats['yesterdayUsers'], 5)
        self.assertEqual(stats['daily'][-2], {'date': yesterday, 'users': 5, 'newUsers': 2})
        self.report(device=str(uuid.uuid4()))
        with self.store.lock:
            days = [row[0] for row in self.store.db.execute('SELECT day FROM usage_daily ORDER BY day')]
        self.assertNotIn('2000-01-01', days)

    def feature_counts(self, key, stats=None):
        stats = stats or self.stats()
        return next(item for group in ('styles', 'features', 'widgets')
                    for item in stats['featureUsage'][group] if item['id'] == key)

    def feature_report(self, features, at, **kwargs):
        with patch('server.naptable_server.datetime') as clock:
            clock.now.return_value = at
            clock.fromisoformat.side_effect = datetime.fromisoformat
            self.report(dict(self.value, consentVersion=2, usageFeatures=features), **kwargs)

    def test_features_require_observed_duration_strictly_over_24_hours(self):
        now = datetime.now(timezone.utc)
        start = now - timedelta(days=2)
        features = {'style.paper': 'a' * 32, 'background': 'b' * 32}
        self.feature_report(features, start)
        self.assertEqual(self.feature_counts('style.paper')['users'], 0, 'Querying later cannot qualify an abandoned trial')
        self.feature_report(features, start + timedelta(days=1))
        self.assertEqual(self.feature_counts('style.paper')['users'], 0, 'Exactly 24 hours is not over one day')
        self.feature_report(features, start + timedelta(days=1, seconds=1))
        self.feature_report(features, now)
        stats = self.stats()
        self.assertEqual(self.feature_counts('style.paper', stats)['users'], 1)
        self.assertEqual(self.feature_counts('background', stats)['observedUsers'], 1)
        self.assertEqual(self.feature_counts('style.paper', stats['schools'][0])['users'], 1)

    def test_each_feature_has_its_own_clock_and_resets_on_reenable(self):
        now = datetime.now(timezone.utc)
        self.feature_report({'background': 'a' * 32}, now - timedelta(days=3))
        self.feature_report({'background': 'a' * 32, 'separateBackgrounds': 'b' * 32}, now)
        self.assertEqual(self.feature_counts('background')['users'], 1)
        self.assertEqual(self.feature_counts('separateBackgrounds')['users'], 0)
        self.feature_report({'background': ''}, now)
        self.assertEqual(self.feature_counts('background')['observedUsers'], 0)
        self.feature_report({'background': 'c' * 32}, now)
        self.assertEqual(self.feature_counts('background')['users'], 0)

    def test_offline_session_change_and_style_switch_restart_duration(self):
        now = datetime.now(timezone.utc)
        self.feature_report({'style.minimal': 'a' * 32, 'liveActivity': 'b' * 32}, now - timedelta(days=2))
        self.feature_report({'style.minimal': '', 'style.board': 'c' * 32, 'liveActivity': 'd' * 32}, now)
        self.assertEqual(self.feature_counts('style.minimal')['observedUsers'], 0)
        self.assertEqual(self.feature_counts('style.board')['users'], 0)
        self.assertEqual(self.feature_counts('liveActivity')['users'], 0, 'An offline off/on cycle changes the interval ID')

    def test_unknown_widget_state_does_not_clear_or_extend_duration(self):
        now = datetime.now(timezone.utc)
        self.feature_report({'widget.upcoming.small': 'a' * 32}, now - timedelta(days=2))
        self.feature_report({}, now)
        self.assertEqual(self.feature_counts('widget.upcoming.small')['users'], 0)
        self.assertEqual(self.feature_counts('widget.upcoming.small')['observedUsers'], 1)
        self.feature_report({'widget.upcoming.small': 'a' * 32}, now)
        self.assertEqual(self.feature_counts('widget.upcoming.small')['users'], 1)

    def test_features_validation_consent_and_auth(self):
        for features in (None, [], {'imagePath': '/private/photo.jpg'}, {'background': True},
                         {'background': 'x' * 32}, {'background': 'a' * 33},
                         {'style.minimal': 'a' * 32, 'style.board': 'b' * 32}):
            self.report(dict(self.value, consentVersion=2, usageFeatures=features), expect=400)
        self.report(dict(self.value, usageFeatures={'background': 'a' * 32}), expect=400)
        now = datetime.now(timezone.utc)
        self.feature_report({'background': 'a' * 32}, now - timedelta(days=2))
        self.feature_report({'background': 'a' * 32}, now, secret='b' * 64, expect=403)
        self.assertEqual(self.feature_counts('background')['users'], 0)
        self.report()  # Legacy client after a downgrade: feature states are no longer known.
        self.assertEqual(self.feature_counts('background')['observedUsers'], 0)

    def test_feature_window_retention_and_long_absence(self):
        now = datetime.now(timezone.utc)
        self.feature_report({'background': 'a' * 32}, now - timedelta(days=33))
        self.feature_report({'background': 'a' * 32}, now - timedelta(days=31))
        self.assertEqual(self.feature_counts('background')['users'], 0)
        self.feature_report({'background': 'a' * 32}, now)
        self.assertEqual(self.feature_counts('background')['users'], 0, 'A 30-day absence restarts qualification')
        with self.store.lock, self.store.db:
            self.store.db.execute('UPDATE usage_devices SET last_seen=?', ((now - timedelta(days=91)).isoformat(),))
        self.stats()
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM usage_features').fetchone()[0], 0)

    def test_feature_dedup_multiple_widgets_school_change_and_reopen(self):
        now = datetime.now(timezone.utc)
        features = {'widget.upcoming.small': 'a' * 32, 'widget.twoday.large': 'b' * 32}
        for stamp in (now - timedelta(days=2), now, now):
            self.feature_report(features, stamp)
        self.feature_report(features, now, device=str(uuid.uuid4()))
        self.assertEqual(self.feature_counts('widget.upcoming.small')['users'], 1)
        self.assertEqual(self.feature_counts('widget.upcoming.small')['observedUsers'], 2)
        self.value['schoolID'] = ''
        self.feature_report(features, now)
        self.assertEqual(self.feature_counts('widget.twoday.large', self.stats()['schools'][0])['users'], 0)
        reopened = Store(self.directory.name + '/usage.sqlite3')
        try:
            self.assertEqual(self.feature_counts('widget.twoday.large', reopened.usage_stats())['users'], 1)
        finally:
            reopened.close()

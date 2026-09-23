import os
import tempfile
import threading
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from server.naptable_server import Handler, Store
from tests.server_support import FastServer, JSONClientMixin


class UsageTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = Store(self.directory.name + '/usage.sqlite3')
        handler = type('UsageHandler', (Handler,), {'store': self.store, 'live_activity': None})
        self.http = FastServer(('127.0.0.1', 0), handler)
        self.thread = threading.Thread(target=self.http.serve_forever)
        self.thread.start()
        self.env = patch.dict(os.environ, {'NAPTABLE_ADMIN_TOKEN': 'usage-admin'})
        self.env.start()
        self.device = str(uuid.uuid4())
        self.secret = 'a' * 64
        self.value = dict(consentVersion=1, schoolID='nju', systemName='iOS', systemVersion='26.0',
                          deviceModel='iPhone17,1', appVersion='1.0')

    def tearDown(self):
        self.http.shutdown(); self.http.server_close(); self.thread.join()
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
        self.assertEqual(stats['schools'][0]['deviceModels'], [{'name': 'iPhone17,1', 'users': 1}])
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

"""Per-device subscriptions and the switch that gates Live Activity reminders."""
import os
import sqlite3
import tempfile
import threading
import unittest

from server.live_activity_timeline import ProtocolError
from server.naptable_server import Store
from server.subscriptions import Subscriptions, SubscriptionError
from tests.server_support import JSONClientMixin, LiveServer
from tests.test_live_activity_v2 import V2Tests


class SubscriptionTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:', check_same_thread=False)
        self.addCleanup(self.db.close)
        self.clock = 1790033400
        self.subscriptions = Subscriptions(self.db, threading.RLock(), now=lambda: self.clock)

    def subscribe(self, device, expires, revoked=0, transaction='t1'):
        self.db.execute("INSERT INTO device_subscriptions VALUES(?,?,'monthly','production',?,?,?)",
                        (device, transaction, expires, revoked, self.clock))
        self.db.commit()

    def test_switch_off_lets_every_device_in(self):
        self.assertTrue(self.subscriptions.allows(self.db, 'any', '2026-09-22'))
        self.assertEqual(self.subscriptions.entitlement(self.db, 'any'), {'required': False, 'subscriptionExpiresAt': None, 'source': 'free'})

    def test_switch_on_needs_a_running_subscription_on_that_device(self):
        changed = []
        self.subscriptions.on_change = changed.append
        self.subscriptions.save_settings({'requireSubscription': True})
        self.assertEqual(changed, [None])
        self.subscriptions.save_settings({'requireSubscription': True})
        self.assertEqual(changed, [None])  # unchanged: nothing to queue
        self.subscribe('old', self.clock - 1)
        self.subscribe('refunded', self.clock + 86400, revoked=1)
        self.subscribe('paid', self.clock + 86400)
        for device, allowed in (('old', False), ('refunded', False), ('paid', True), ('none', False)):
            self.assertEqual(self.subscriptions.allows(self.db, device, '2026-09-22'), allowed, device)
        self.assertEqual(self.subscriptions.entitlement(self.db, 'paid')['source'], 'subscription')
        self.assertEqual(self.subscriptions.entitlement(self.db, 'none')['source'], None)
        self.assertEqual(self.subscriptions.admin_summary(), {'subscribedDevices': 1, 'settings': {'requireSubscription': True}})

    def test_settings_validation(self):
        for bad in ({'requireSubscription': 'yes'}, {'requireSubscription': 1}, {'trialDays': 30}, []):
            with self.assertRaises(SubscriptionError):
                self.subscriptions.save_settings(bad)

    def test_the_account_tables_are_retired_and_the_switch_kept(self):
        db = sqlite3.connect(':memory:')
        self.addCleanup(db.close)
        db.executescript("CREATE TABLE accounts(id TEXT); CREATE TABLE account_sessions(x); CREATE TABLE subscriptions(x);"
                         "CREATE TABLE account_settings(key TEXT PRIMARY KEY, value TEXT);"
                         "INSERT INTO account_settings VALUES('requireSubscription','true'), ('teamID','\"T\"');")
        Subscriptions(db, threading.RLock())
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertEqual(tables, {'device_subscriptions', 'subscription_settings'})
        self.assertTrue(Subscriptions(db, threading.RLock()).required())


class GatingTests(unittest.TestCase):
    """The Live Activity service with subscriptions wired in, as `create_app` does."""
    def setUp(self):
        V2Tests.setUp(self)  # its fixture, without re-running its tests
        self.subscriptions = Subscriptions(self.db, self.lock, now=lambda: self.clock)
        self.service.entitlement, self.subscriptions.on_change = self.subscriptions, self.service.requeue
        self.subscriptions.save_settings({'requireSubscription': True})

    def subscribe(self):
        self.db.execute("INSERT INTO device_subscriptions VALUES(?,'t1','monthly','production',?,0,?)",
                        (self.id, self.clock + 30 * 86400, self.clock))
        self.db.commit()
        self.subscriptions.on_change([self.id])  # as the purchase will, once it arrives in phase 2

    def test_an_unsubscribed_device_gets_no_start_until_it_subscribes(self):
        self.service.dispatch_starts()
        self.assertEqual(self.client.starts, [])
        status = self.service.status(self.id)
        self.assertEqual((status['entitled'], status['subscription']['required']), (False, True))
        self.assertFalse(self.service.put_timetable(self.id, dict(self.timetable, revision=2))['entitled'])
        self.subscribe()
        self.service.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1)
        self.assertEqual(self.service.status(self.id)['subscription']['source'], 'subscription')

    def test_claims_need_the_entitlement(self):
        self.clock -= 3600
        self.assertEqual(self.service.claim(self.id, {'slots': 2})['claims'], [])
        self.subscribe()
        self.assertEqual(len(self.service.claim(self.id, {'slots': 2})['claims']), 1)

    def test_foreground_activity_needs_the_entitlement(self):
        token = {'token': 'ab' * 16, 'end': self.clock + 1800}
        with self.assertRaises(ProtocolError) as caught:
            self.service.register_token(self.id, 'foreground:now', token)
        self.assertEqual(caught.exception.status, 402)
        self.subscribe()
        self.service.register_token(self.id, 'foreground:now', token)

    def test_switching_off_brings_back_skipped_reminders(self):
        self.service.dispatch_starts()
        self.assertEqual(self.client.starts, [])
        self.subscriptions.save_settings({'requireSubscription': False})
        self.service.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1)


class AdminTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.file = tempfile.NamedTemporaryFile(suffix='.sqlite3')
        self.addCleanup(self.file.close)
        self.store = Store(self.file.name)
        self.addCleanup(self.store.close)
        self.http = LiveServer(self.store)
        self.addCleanup(self.http.shutdown)
        os.environ['NAPTABLE_ADMIN_TOKEN'] = 'admin-test'
        self.addCleanup(os.environ.pop, 'NAPTABLE_ADMIN_TOKEN', None)
        self.admin = {'X-Admin-Token': 'admin-test'}

    def test_switch_and_summary(self):
        self.req('GET', '/v1/admin/subscriptions', expect=403)
        self.assertEqual(self.req('GET', '/v1/admin/subscriptions', headers=self.admin)['subscribedDevices'], 0)
        self.req('POST', '/v1/admin/subscriptions/settings', {'requireSubscription': 'soon'}, headers=self.admin, expect=400)
        self.assertTrue(self.req('POST', '/v1/admin/subscriptions/settings', {'requireSubscription': True}, headers=self.admin)['requireSubscription'])
        self.assertEqual(self.store.audit_log('subscription.settings')['entries'][0]['detail'], {'requireSubscription': True})

    def test_accounts_are_gone(self):
        for method, path in (('POST', '/v1/account/nonce'), ('GET', '/v1/account'), ('GET', '/v1/admin/accounts/summary')):
            self.req(method, path, headers=self.admin, expect=404)

    def test_shares_are_labelled_by_publisher(self):
        share = self.req('POST', '/v1/shares', {'owner': '张三', 'schoolID': 'nju', 'termID': '2026-fall-template',
                                                 'courses': [{'name': '高数', 'week_time': 1, 'start_time': 1, 'time_count': 2}]}, expect=201)
        listed = self.req('GET', '/v1/admin/shares', headers=self.admin)['shares'][0]
        # No App Attest here (as on a simulator): known by its address.
        self.assertEqual((listed['code'], listed['publisher']['kind'], len(listed['publisher']['id'])), (share['id'], 'ip', 8))
        found = self.req('GET', '/v1/admin/shares?q=' + listed['publisher']['id'][:5], headers=self.admin)
        self.assertEqual(found['total'], 1)


if __name__ == '__main__':
    unittest.main()

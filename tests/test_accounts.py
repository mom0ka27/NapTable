"""Sign in with Apple accounts, the credit ledger and Live Activity gating."""
import base64
import hashlib
import json
import os
import unittest

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from server.accounts import AccountError, Accounts, AppleIdentity
from tests.server_support import JSONClientMixin, LiveServer
from tests.test_live_activity_v2 import V2Tests

BUNDLE = 'me.mom0ka27.naptable'


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


class FakeApple:
    """Apple's key endpoint and a signer for identity tokens and events."""
    def __init__(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        numbers = self.key.public_key().public_numbers()
        self.jwks = {'keys': [{'kty': 'RSA', 'kid': 'k1', 'alg': 'RS256',
                               'n': b64(numbers.n.to_bytes(256, 'big')), 'e': b64(numbers.e.to_bytes(3, 'big'))}]}
        self.calls = []

    def fetch(self, url, data=None, headers=None, timeout=10):
        self.calls.append(url)
        if url.endswith('/auth/keys'):
            return 200, json.dumps(self.jwks).encode()
        return 200, b'{}'

    def token(self, claims, kid='k1', key=None):
        head = b64(json.dumps({'alg': 'RS256', 'kid': kid}).encode())
        body = b64(json.dumps(claims).encode())
        signature = (key or self.key).sign(f'{head}.{body}'.encode(), padding.PKCS1v15(), hashes.SHA256())
        return f'{head}.{body}.{b64(signature)}'


class AccountTestMixin:
    def make_accounts(self, db, lock, now):
        self.apple = FakeApple()
        return Accounts(db, lock, now=now, apple=AppleIdentity(self.apple.fetch, now))

    def sign_in(self, sub='apple-user-1'):
        nonce = self.accounts.nonce()['nonce']
        token = self.apple.token({'iss': 'https://appleid.apple.com', 'aud': BUNDLE, 'sub': sub,
                                  'exp': self.clock + 600, 'nonce': hashlib.sha256(nonce.encode()).hexdigest()})
        return self.accounts.sign_in({'identityToken': token, 'nonce': nonce})

    def account_id(self, result):
        return self.db.execute('SELECT id FROM accounts WHERE code=?', (result['account']['code'],)).fetchone()[0]


class AccountTests(AccountTestMixin, unittest.TestCase):
    def setUp(self):
        import sqlite3, threading
        self.db = sqlite3.connect(':memory:', check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.addCleanup(self.db.close)
        self.lock = threading.RLock()
        self.clock = 1790033400  # 2026-09-22 07:30 UTC+8
        self.accounts = self.make_accounts(self.db, self.lock, lambda: self.clock)

    def test_sign_in_creates_one_account_with_the_trial(self):
        first = self.sign_in()
        self.assertEqual(len(first['account']['code']), 8)
        self.assertEqual(first['account']['entitlement']['creditDays'], 30)
        again = self.sign_in()
        self.assertEqual(again['account']['code'], first['account']['code'])
        self.assertEqual(again['account']['entitlement']['creditDays'], 30)
        self.assertNotEqual(again['session'], first['session'])
        self.assertEqual(self.accounts.authenticate('Bearer ' + first['session']), self.account_id(first))
        # Only a hash of the Apple subject is kept.
        self.assertNotIn('apple-user-1', json.dumps([list(row) for row in self.db.execute('SELECT * FROM accounts')]))

    def test_identity_token_checks(self):
        nonce = self.accounts.nonce()['nonce']
        hashed = hashlib.sha256(nonce.encode()).hexdigest()
        good = {'iss': 'https://appleid.apple.com', 'aud': BUNDLE, 'sub': 's', 'exp': self.clock + 600, 'nonce': hashed}
        other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        for token in (self.apple.token(dict(good, aud='someone.else')), self.apple.token(dict(good, exp=self.clock - 3600)),
                      self.apple.token(dict(good, nonce='x')), self.apple.token(good, key=other),
                      self.apple.token(good, kid='unknown'), 'not-a-jwt'):
            with self.assertRaises(AccountError) as caught:
                self.accounts.sign_in({'identityToken': token, 'nonce': nonce})
            self.assertEqual(caught.exception.status, 401)
        token = self.apple.token(good)
        self.accounts.sign_in({'identityToken': token, 'nonce': nonce})
        with self.assertRaisesRegex(AccountError, 'nonce expired or used'):
            self.accounts.sign_in({'identityToken': token, 'nonce': nonce})
        # An unknown kid refetches the keys at most once a minute.
        self.assertLessEqual(self.apple.calls.count('https://appleid.apple.com/auth/keys'), 2)

    def test_deleted_account_gets_no_second_trial(self):
        first = self.sign_in()
        self.accounts.delete(self.account_id(first))
        with self.assertRaises(AccountError):
            self.accounts.authenticate('Bearer ' + first['session'])
        second = self.sign_in()
        self.assertNotEqual(second['account']['code'], first['account']['code'])
        self.assertEqual(second['account']['entitlement']['creditDays'], 0)

    def test_usage_days_charge_once_per_day_and_only_when_enforced(self):
        account = self.account_id(self.sign_in())
        self.accounts.bind(account, 'device-1')
        self.accounts.bind(account, 'device-2')
        with self.accounts.transaction() as db:
            self.accounts.charge(db, 'device-1', '2026-09-22')
        self.assertEqual(self.accounts.summary(account)['entitlement']['creditDays'], 30)  # not enforced yet
        self.accounts.save_settings({'enforceAfter': '2026-09-22'})
        with self.accounts.transaction() as db:
            self.assertTrue(self.accounts.allows(db, 'device-1', '2026-09-22'))
            self.assertFalse(self.accounts.allows(db, 'unbound', '2026-09-22'))
            self.assertTrue(self.accounts.allows(db, 'unbound', '2026-09-21'))  # before enforcement
            for device in ('device-1', 'device-2', 'device-1'):
                self.accounts.charge(db, device, '2026-09-22')
        self.assertEqual(self.accounts.summary(account)['entitlement']['creditDays'], 29)
        self.assertTrue(self.accounts.summary(account)['entitlement']['chargedToday'])

    def test_empty_balance_keeps_the_paid_day_and_subscription_freezes_credit(self):
        account = self.account_id(self.sign_in())
        self.accounts.bind(account, 'device')
        self.accounts.save_settings({'enforceAfter': '2026-09-01'})
        self.accounts.grant({'target': 'account', 'code': self.accounts.summary(account)['code'], 'days': -29})
        with self.accounts.transaction() as db:
            self.accounts.charge(db, 'device', '2026-09-22')
            self.assertTrue(self.accounts.allows(db, 'device', '2026-09-22'))
            self.assertFalse(self.accounts.allows(db, 'device', '2026-09-23'))
            db.execute("INSERT INTO subscriptions VALUES('t1',?,'monthly','production',?,0,?)", (account, self.clock + 86400 * 30, self.clock))
            self.assertTrue(self.accounts.allows(db, 'device', '2026-09-23'))
            self.accounts.charge(db, 'device', '2026-09-23')
        self.assertEqual(self.accounts.summary(account)['entitlement']['source'], 'subscription')
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM usage_charges').fetchone()[0], 1)

    def test_grants_to_groups_and_audit(self):
        trial = self.account_id(self.sign_in('a'))
        spent = self.account_id(self.sign_in('b'))
        self.accounts.grant({'target': 'account', 'code': self.accounts.summary(spent)['code'], 'days': -30})
        self.assertEqual(self.accounts.grant({'target': 'expired', 'days': 7, 'dryRun': True}), {'accounts': 1, 'days': 7})
        changed = []
        self.accounts.on_change = changed.extend
        self.accounts.bind(spent, 'device-b')
        changed.clear()
        self.assertEqual(self.accounts.grant({'target': 'expired', 'days': 7, 'note': '补偿'})['accounts'], 1)
        self.assertEqual(changed, ['device-b'])
        self.assertEqual(self.accounts.summary(spent)['entitlement']['creditDays'], 7)
        self.assertEqual(self.accounts.grant({'target': 'all', 'days': 1})['accounts'], 2)
        self.assertEqual(self.accounts.summary(trial)['entitlement']['creditDays'], 31)
        for bad in ({'target': 'everyone', 'days': 1}, {'target': 'all', 'days': 0}, {'target': 'all', 'days': 1.5},
                    {'target': 'account', 'code': 'NOPE', 'days': 1}):
            with self.assertRaises(AccountError):
                self.accounts.grant(bad)
        detail = self.accounts.admin_detail(self.accounts.summary(spent)['code'].lower())
        self.assertEqual([item['reason'] for item in detail['ledger']], ['grant', 'grant', 'grant', 'trial'])
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM account_audit WHERE action='grant'").fetchone()[0], 3)
        summary = self.accounts.admin_summary()
        self.assertEqual((summary['accounts'], summary['trial'], summary['expired']), (2, 2, 0))

    def test_apple_events(self):
        account = self.account_id(self.sign_in())
        self.accounts.bind(account, 'device')
        event = lambda kind: {'payload': self.apple.token({'iss': 'https://appleid.apple.com', 'aud': BUNDLE, 'iat': self.clock,
                                                           'events': json.dumps({'type': kind, 'sub': 'apple-user-1'})})}
        self.accounts.apple_event(event('consent-revoked'))
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM account_sessions').fetchone()[0], 0)
        self.assertEqual(self.accounts.summary(account)['devices'], 0)
        self.accounts.apple_event(event('account-delete'))
        self.assertIsNone(self.db.execute('SELECT 1 FROM accounts').fetchone())

    def test_settings_validation(self):
        for bad in ({'enforceAfter': '22/09/2026'}, {'trialDays': -1}, {'unknown': 1}, {'keyPath': '/nonexistent.p8'}):
            with self.assertRaises(AccountError):
                self.accounts.save_settings(bad)
        self.assertFalse(self.accounts.save_settings({'trialDays': 14})['signInConfigured'])
        self.assertEqual(self.sign_in()['account']['entitlement']['creditDays'], 14)


class GatingTests(AccountTestMixin, unittest.TestCase):
    """The Live Activity service with accounts wired in, as `create_app` does."""
    def setUp(self):
        V2Tests.setUp(self)  # its fixture, without re-running its tests
        self.accounts = self.make_accounts(self.db, self.lock, lambda: self.clock)
        self.service.entitlement, self.accounts.on_change = self.accounts, self.service.requeue
        self.accounts.save_settings({'enforceAfter': '2026-09-01'})

    def test_unentitled_device_gets_no_start_until_it_signs_in(self):
        self.service.dispatch_starts()
        self.assertEqual(self.client.starts, [])
        self.assertFalse(self.service.status(self.id)['entitled'])
        self.assertFalse(self.service.put_timetable(self.id, dict(self.timetable, revision=2))['entitled'])
        account = self.account_id(self.sign_in())
        self.accounts.bind(account, self.id)
        self.service.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1)
        self.assertEqual(self.accounts.summary(account)['entitlement']['creditDays'], 29)
        self.assertTrue(self.service.status(self.id)['entitled'])

    def test_claims_need_the_entitlement_and_charge_when_due(self):
        self.clock -= 3600
        self.assertEqual(self.service.claim(self.id, {'slots': 2})['claims'], [])
        account = self.account_id(self.sign_in())
        self.accounts.bind(account, self.id)
        self.assertEqual(len(self.service.claim(self.id, {'slots': 2})['claims']), 1)
        self.service.charge_reservations()
        self.assertEqual(self.accounts.summary(account)['entitlement']['creditDays'], 30)  # not started yet
        self.clock += 3600
        self.service.charge_reservations()
        self.assertEqual(self.accounts.summary(account)['entitlement']['creditDays'], 29)
        self.assertEqual(self.client.starts, [])

    def test_foreground_activity_needs_the_entitlement(self):
        from server.live_activity_timeline import ProtocolError
        token = {'token': 'ab' * 16, 'end': self.clock + 1800}
        with self.assertRaises(ProtocolError) as caught:
            self.service.register_token(self.id, 'foreground:now', token)
        self.assertEqual(caught.exception.status, 402)
        self.accounts.bind(self.account_id(self.sign_in()), self.id)
        self.service.register_token(self.id, 'foreground:now', token)

    def test_ending_enforcement_brings_back_skipped_reminders(self):
        self.service.dispatch_starts()
        self.assertEqual(self.client.starts, [])
        self.accounts.save_settings({'enforceAfter': ''})
        self.service.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1)

    def test_no_enforcement_lets_everyone_through(self):
        self.accounts.save_settings({'enforceAfter': ''})
        self.service.dispatch_starts()
        self.assertEqual(len(self.client.starts), 1)


class AccountHTTPTests(AccountTestMixin, JSONClientMixin, unittest.TestCase):
    def setUp(self):
        V2Tests.setUp(self)  # its fixture, without re-running its tests
        self.accounts = self.make_accounts(self.db, self.lock, lambda: self.clock)
        self.service.entitlement, self.accounts.on_change = self.accounts, self.service.requeue
        self.legacy.v2 = self.service
        from server.naptable_server import Store
        self.store = Store(':memory:')
        self.addCleanup(self.store.close)
        self.http = LiveServer(self.store, self.legacy, self.accounts)
        self.addCleanup(self.http.shutdown)
        old = os.environ.get('NAPTABLE_ADMIN_TOKEN')
        os.environ['NAPTABLE_ADMIN_TOKEN'] = 'admin-test'
        self.addCleanup(lambda: os.environ.pop('NAPTABLE_ADMIN_TOKEN') if old is None else os.environ.__setitem__('NAPTABLE_ADMIN_TOKEN', old))

    def test_account_flow(self):
        nonce = self.req('POST', '/v1/account/nonce')['nonce']
        token = self.apple.token({'iss': 'https://appleid.apple.com', 'aud': BUNDLE, 'sub': 'u', 'exp': self.clock + 600,
                                  'nonce': hashlib.sha256(nonce.encode()).hexdigest()})
        self.req('POST', '/v1/account/apple', {'identityToken': token}, expect=400)
        signed = self.req('POST', '/v1/account/apple', {'identityToken': token, 'nonce': nonce})
        bearer = {'Authorization': 'Bearer ' + signed['session']}
        self.req('GET', '/v1/account', expect=401)
        self.assertEqual(self.req('GET', '/v1/account', headers=bearer)['entitlement']['creditDays'], 30)
        device = '/v1/account/devices/' + self.id
        self.req('PUT', device, headers=dict(bearer, **{'X-Device-Secret': 'wrong'}), expect=403)
        self.assertEqual(self.req('PUT', device, headers=dict(bearer, **{'X-Device-Secret': 'persisted-secret'}))['devices'], 1)
        self.assertEqual(self.req('DELETE', device, headers=bearer)['devices'], 0)
        code = signed['account']['code']
        admin = {'X-Admin-Token': 'admin-test'}
        self.req('GET', '/v1/admin/accounts', expect=403)
        self.assertEqual(self.req('GET', '/v1/admin/accounts?q=' + code[:3], headers=admin)['total'], 1)
        self.assertEqual(self.req('GET', '/v1/admin/accounts/summary', headers=admin)['trial'], 1)
        self.req('POST', '/v1/admin/accounts/grants', {'target': 'account', 'code': code, 'days': 5}, headers=admin)
        self.assertEqual(self.req('GET', '/v1/admin/accounts/' + code, headers=admin)['creditDays'], 35)
        self.req('GET', '/v1/admin/accounts/ZZZZZZZZ', headers=admin, expect=404)
        self.req('POST', '/v1/admin/accounts/settings', {'enforceAfter': 'soon'}, headers=admin, expect=400)
        self.req('DELETE', '/v1/account/session', headers=bearer)
        self.req('GET', '/v1/account', headers=bearer, expect=401)



class AvatarTests(AccountTestMixin, JSONClientMixin, unittest.TestCase):
    """Avatars, and the publisher's avatar on the shares readers download."""
    def setUp(self):
        import tempfile
        from server.naptable_server import Store
        self.clock = 1790033400
        self.file = tempfile.NamedTemporaryFile(suffix='.sqlite3')
        self.addCleanup(self.file.close)
        self.store = Store(self.file.name)
        self.addCleanup(self.store.close)
        self.db = self.store.db
        self.accounts = self.make_accounts(self.store.db, self.store.lock, lambda: self.clock)
        self.http = LiveServer(self.store, None, self.accounts)
        self.addCleanup(self.http.shutdown)
        self.bearer = {'Authorization': 'Bearer ' + self.sign_in()['session']}

    def raw(self, path):
        import http.client
        connection = http.client.HTTPConnection('127.0.0.1', self.http.server_port, timeout=5)
        try:
            connection.request('GET', path)
            response = connection.getresponse()
            return response.status, response.getheader('Content-Type'), response.getheader('Cache-Control'), response.read()
        finally:
            connection.close()

    def share(self, headers=None, expect=201):
        return self.req('POST', '/v1/shares', {'owner': '张三', 'schoolID': 'nju', 'termID': '2026-fall-template',
                                               'courses': [{'name': '高数', 'week_time': 1, 'start_time': 1, 'time_count': 2}]},
                        headers, expect=expect)

    def test_upload_replace_and_clear(self):
        jpeg = b'\xff\xd8\xff\xe0' + b'x' * 100
        for bad in ({'image': 'not base64!'}, {'image': base64.b64encode(b'GIF89a').decode()},
                    {'image': base64.b64encode(b'\xff\xd8\xff' + b'x' * 300 * 1024).decode()}, {}):
            self.req('PUT', '/v1/account/avatar', bad, self.bearer, expect=400)
        self.req('PUT', '/v1/account/avatar', {'image': base64.b64encode(jpeg).decode()}, expect=401)
        first = self.req('PUT', '/v1/account/avatar', {'image': base64.b64encode(jpeg).decode()}, self.bearer)['avatar']
        self.assertEqual(self.raw(first), (200, 'image/jpeg', 'public, max-age=31536000, immutable', jpeg))
        second = self.req('PUT', '/v1/account/avatar', {'image': base64.b64encode(jpeg).decode()}, self.bearer)['avatar']
        self.assertNotEqual(first, second)
        self.assertEqual(self.raw(first)[0], 404)
        self.assertIsNone(self.req('DELETE', '/v1/account/avatar', headers=self.bearer)['avatar'])
        self.assertEqual(self.raw(second)[0], 404)

    def test_profile_name(self):
        self.assertEqual(self.req('PUT', '/v1/account/profile', {'name': '  小  明 '}, self.bearer)['name'], '小 明')
        self.req('PUT', '/v1/account/profile', {'name': 'x' * 21}, self.bearer, expect=400)
        self.req('PUT', '/v1/account/profile', {'name': 1}, self.bearer, expect=400)

    def test_share_carries_the_publishers_avatar(self):
        anonymous = self.share()
        self.assertIsNone(anonymous['ownerAvatar'])
        self.share({'Authorization': 'Bearer expired'}, expect=401)
        signed = self.share(self.bearer)
        self.assertIsNone(signed['ownerAvatar'])  # no avatar yet
        path = self.req('PUT', '/v1/account/avatar', {'image': base64.b64encode(b'\x89PNG\r\n\x1a\n' + b'p' * 10).decode()}, self.bearer)['avatar']
        self.assertEqual(self.req('GET', '/v1/shares/' + signed['id'])['ownerAvatar'], path)
        self.assertEqual(self.req('GET', f"/v1/shares/{signed['id']}/meta")['ownerAvatar'], path)
        # Replaced without signing in, it keeps its publisher.
        replaced = self.req('POST', f"/v1/shares/{signed['id']}/replace", {'owner': '张三', 'schoolID': 'nju', 'termID': '2026-fall-template',
                            'courses': [{'name': '线代', 'week_time': 2, 'start_time': 1, 'time_count': 2}]},
                            {'X-Write-Token': signed['writeToken']}, expect=201)
        self.assertEqual(replaced['ownerAvatar'], path)
        # An admin clears it; the share then shows none.
        os.environ['NAPTABLE_ADMIN_TOKEN'] = 'admin-test'
        self.addCleanup(os.environ.pop, 'NAPTABLE_ADMIN_TOKEN', None)
        code = self.req('GET', '/v1/account', headers=self.bearer)['code']
        self.req('DELETE', f'/v1/admin/accounts/{code}/avatar', expect=403)
        self.assertIsNone(self.req('DELETE', f'/v1/admin/accounts/{code}/avatar', headers={'X-Admin-Token': 'admin-test'})['avatar'])
        self.assertIsNone(self.req('GET', '/v1/shares/' + replaced['id'])['ownerAvatar'])


if __name__ == '__main__':
    unittest.main()

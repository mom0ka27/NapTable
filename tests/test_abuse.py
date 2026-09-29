"""Anti-abuse: App Attest, share quotas and expiry, follower caps and dormant devices."""
import base64
import copy
import hashlib
import os
import sqlite3
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from server import naptable_server
from server.app_attest import AppAttest, AttestError, client_data
from server.live_activity_timeline import ProtocolError
from server.naptable_server import Store
from tests.server_support import JSONClientMixin, LiveServer
from tests import test_live_activity_scheduled as scheduled

APP_ID = 'TEAM123456.com.niyiwei.naptable'


def cbor(value):
    """Just enough CBOR to build what a phone sends."""
    def head(major, length):
        if length < 24: return bytes([major << 5 | length])
        for info, size in ((24, 1), (25, 2), (26, 4), (27, 8)):
            if length < 1 << (8 * size): return bytes([major << 5 | info]) + length.to_bytes(size, 'big')
    if isinstance(value, int): return head(0, value)
    if isinstance(value, bytes): return head(2, len(value)) + value
    if isinstance(value, str): return head(3, len(value.encode())) + value.encode()
    if isinstance(value, list): return head(4, len(value)) + b''.join(cbor(item) for item in value)
    return head(5, len(value)) + b''.join(cbor(key) + cbor(item) for key, item in value.items())


def cert(subject, issuer_name, key, signer, extensions=(), ca=False):
    now = datetime.now(timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, subject)]))
               .issuer_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, issuer_name)]))
               .public_key(key.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=30))
               .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
    for extension in extensions:
        builder = builder.add_extension(extension, critical=False)
    return builder.sign(signer, hashes.SHA256())


class FakeDevice:
    """A Secure Enclave key and the Apple CA that attests it, as a phone would present them."""
    def __init__(self, app_id=APP_ID):
        self.root_key, self.ca_key = ec.generate_private_key(ec.SECP384R1()), ec.generate_private_key(ec.SECP256R1())
        self.root = cert('Root', 'Root', self.root_key, self.root_key, ca=True)
        self.ca = cert('CA', 'Root', self.ca_key, self.root_key, ca=True)
        self.key = ec.generate_private_key(ec.SECP256R1())
        point = self.key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        self.key_hash = hashlib.sha256(point).digest()
        self.key_id = base64.b64encode(self.key_hash).decode()
        self.app_id, self.counter = app_id, 0

    def root_pem(self):
        return self.root.public_bytes(serialization.Encoding.PEM)

    def attestation(self, challenge, counter=0, environment=b'appattestdevelop'):
        auth = (hashlib.sha256(self.app_id.encode()).digest() + b'\x40' + counter.to_bytes(4, 'big') + environment
                + len(self.key_hash).to_bytes(2, 'big') + self.key_hash + b'cose-key')
        nonce = hashlib.sha256(auth + hashlib.sha256(challenge.encode()).digest()).digest()
        # SEQUENCE { [1] { OCTET STRING nonce } }
        extension = x509.UnrecognizedExtension(x509.ObjectIdentifier('1.2.840.113635.100.8.2'), bytes([0x30, 36, 0xA1, 34, 0x04, 32]) + nonce)
        leaf = cert('leaf', 'CA', self.key, self.ca_key, [extension])
        der = [item.public_bytes(serialization.Encoding.DER) for item in (leaf, self.ca)]
        statement = {'fmt': 'apple-appattest', 'attStmt': {'x5c': der, 'receipt': b''}, 'authData': auth}
        return {'keyId': self.key_id, 'attestation': base64.b64encode(cbor(statement)).decode(), 'challenge': challenge}

    def headers(self, method, path, body, stamp, counter=None, key=None):
        self.counter = self.counter + 1 if counter is None else counter
        auth = hashlib.sha256(self.app_id.encode()).digest() + b'\x00' + self.counter.to_bytes(4, 'big')
        nonce = hashlib.sha256(auth + hashlib.sha256(client_data(method, path, str(stamp), body)).digest()).digest()
        signature = (key or self.key).sign(nonce, ec.ECDSA(hashes.SHA256()))
        assertion = base64.b64encode(cbor({'signature': signature, 'authenticatorData': auth})).decode()
        return {'X-App-Attest-Key': self.key_id, 'X-App-Attest-Time': str(stamp), 'X-App-Attest-Assertion': assertion}


class AppAttestTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:', check_same_thread=False)
        self.addCleanup(self.db.close)
        self.clock = datetime.now(timezone.utc).timestamp()
        self.device = FakeDevice()
        self.attest = AppAttest(self.db, threading.RLock(), app_id=lambda: APP_ID, now=lambda: self.clock,
                                root=self.device.root_pem(), mode='log')

    def register(self, **changes):
        value = self.device.attestation(self.attest.challenge()['challenge'])
        value.update(changes)
        return self.attest.register(value)

    def test_attestation_registers_the_key(self):
        self.assertEqual(self.register(), {'registered': True, 'environment': 'development'})
        self.assertEqual(self.attest.summary()['keys'], {'development': 1})

    def test_attestation_checks(self):
        challenge = self.attest.challenge()['challenge']
        good = self.device.attestation(challenge)
        cases = [
            (dict(good, challenge='1.2.3'), 'challenge'),
            (dict(good, keyId=base64.b64encode(b'x' * 32).decode()), 'key id mismatch'),
            (self.device.attestation(challenge, counter=1), 'counter must start at 0'),
            (self.device.attestation(challenge, environment=b'x' * 16), 'unknown App Attest environment'),
            (dict(self.device.attestation(challenge), challenge=self.attest.challenge()['challenge']), 'nonce mismatch'),
        ]
        for value, message in cases:
            with self.assertRaisesRegex(AttestError, message):
                self.attest.register(value)
        other = FakeDevice()  # attested by a CA that is not the configured root
        with self.assertRaisesRegex(AttestError, "not Apple's"):
            self.attest.register(other.attestation(challenge))
        wrong = AppAttest(self.db, threading.RLock(), app_id=lambda: 'TEAM.other.app', now=lambda: self.clock, root=self.device.root_pem())
        with self.assertRaisesRegex(AttestError, 'another app'):
            wrong.register(self.device.attestation(wrong.challenge()['challenge']))
        self.clock += 301
        with self.assertRaisesRegex(AttestError, 'challenge expired'):
            self.attest.register(good)

    def test_assertions_are_bound_to_the_request_and_never_replay(self):
        self.register()
        body, stamp = b'{"a":1}', int(self.clock)
        headers = self.device.headers('POST', '/v1/shares', body, stamp)
        self.assertEqual(self.attest.verify(headers, 'POST', '/v1/shares', body), self.device.key_id)
        for expected, args in [
            ('replayed', (headers, 'POST', '/v1/shares', body)),
            ('badSignature', (self.device.headers('POST', '/v1/shares', body, stamp), 'POST', '/v1/shares', b'{"a":2}')),
            ('badSignature', (self.device.headers('POST', '/v1/shares', body, stamp), 'PUT', '/v1/shares', body)),
            ('badSignature', (self.device.headers('POST', '/v1/shares', body, stamp, key=ec.generate_private_key(ec.SECP256R1())), 'POST', '/v1/shares', body)),
            ('stale', (self.device.headers('POST', '/v1/shares', body, stamp - 3600), 'POST', '/v1/shares', body)),
            ('missing', ({}, 'POST', '/v1/shares', body)),
            ('unknownKey', (FakeDevice().headers('POST', '/v1/shares', body, stamp), 'POST', '/v1/shares', body)),
            ('malformed', (dict(headers, **{'X-App-Attest-Assertion': 'bm9wZQ=='}), 'POST', '/v1/shares', body)),
        ]:
            with self.assertRaisesRegex(AttestError, expected):
                self.attest.verify(*args)
        # A later counter is accepted again.
        self.assertEqual(self.attest.verify(self.device.headers('POST', '/v1/shares', body, stamp, counter=50), 'POST', '/v1/shares', body), self.device.key_id)

    def test_enforce_refuses_only_forgeries(self):
        self.register()
        body, stamp = b'{}', int(self.clock)
        self.assertEqual(AppAttest(self.db, threading.RLock()).mode, 'enforce')  # the default
        forged = self.device.headers('POST', '/p', body, stamp, key=ec.generate_private_key(ec.SECP256R1()))
        self.attest.mode = 'log'
        self.assertEqual(self.attest.check(forged, 'POST', '/p', body, 'share.publish'), (None, False, 'badSignature'))
        self.attest.mode = 'enforce'
        self.assertEqual(self.attest.check(forged, 'POST', '/p', body, 'share.publish'), (None, True, 'badSignature'))
        # No assertion (a simulator), a key we lost, a skewed clock: unattested, not refused.
        self.assertEqual(self.attest.check({}, 'POST', '/p', body, 'share.publish'), (None, False, 'missing'))
        self.assertEqual(self.attest.check(FakeDevice().headers('POST', '/p', body, stamp), 'POST', '/p', body, 'share.publish'),
                         (None, False, 'unknownKey'))
        self.assertEqual(self.attest.check(self.device.headers('POST', '/p', body, stamp - 3600), 'POST', '/p', body, 'share.publish'),
                         (None, False, 'stale'))
        valid = self.device.headers('POST', '/p', body, stamp)
        self.assertEqual(self.attest.check(valid, 'POST', '/p', body, 'share.publish'), (self.device.key_id, False, 'valid'))
        self.assertEqual(self.attest.check(valid, 'POST', '/p', body, 'share.publish'), (None, True, 'replayed'))
        self.attest.mode = 'off'
        self.assertEqual(self.attest.check(forged, 'POST', '/p', body, 'share.publish'), (None, False, 'off'))
        outcomes = {row['outcome']: row['count'] for row in self.attest.summary()['outcomes']}
        self.assertEqual(outcomes, {'badSignature': 2, 'missing': 1, 'unknownKey': 1, 'stale': 1, 'valid': 1, 'replayed': 1})


class ShareQuotaTests(JSONClientMixin, unittest.TestCase):
    SHARE = {'owner': '张三', 'schoolID': 'nju', 'termID': '2026-fall-template',
             'courses': [{'name': '高数', 'week_time': 1, 'start_time': 1, 'time_count': 2}]}

    def setUp(self):
        self.file = tempfile.NamedTemporaryFile(suffix='.sqlite3')
        self.addCleanup(self.file.close)
        self.store = Store(self.file.name)
        self.addCleanup(self.store.close)
        self.http = LiveServer(self.store)
        self.addCleanup(self.http.shutdown)
        self.app = self.http.server.config.app
        os.environ['NAPTABLE_ADMIN_TOKEN'] = 'admin-test'
        self.addCleanup(os.environ.pop, 'NAPTABLE_ADMIN_TOKEN', None)

    def share(self, expect=201, **changes):
        return self.req('POST', '/v1/shares', dict(self.SHARE, **changes), expect=expect)

    def test_codes_use_the_readable_alphabet(self):
        code = self.share()['id']
        self.assertEqual(len(code), 8)
        self.assertTrue(set(code) <= set(naptable_server.SHARE_CODE_ALPHABET))

    def test_identified_publishers_hold_a_limited_number_of_shares(self):
        # Known by an App Attest key: `attested` hands one back.
        with mock.patch.object(naptable_server.Exchange, 'attested', lambda x, endpoint: ('key-1', False)):
            first = [self.share(courses=[dict(self.SHARE['courses'][0], start_time=n)]) for n in range(1, naptable_server.MAX_ACTIVE_SHARES + 1)]
            self.assertIn('最多同时保留', self.share(expect=429)['error'])
            # Replacing one keeps the count, so it still works.
            self.req('POST', f"/v1/shares/{first[0]['id']}/replace", dict(self.SHARE, courses=[dict(self.SHARE['courses'][0], start_time=12)]),
                     {'X-Write-Token': first[0]['writeToken']}, expect=201)
        # Known only by address: no count (a campus shares one), but a looser hourly rate.
        self.share()

    def test_publishing_is_rate_limited(self):
        with mock.patch.object(naptable_server, 'PUBLISH_PER_HOUR_BY_ADDRESS', 3):
            for n in range(3):
                self.share(courses=[dict(self.SHARE['courses'][0], start_time=n + 1)])
            refused = self.share(expect=429)
        self.assertIn('太频繁', refused['error'])

    def test_unidentified_shares_have_a_daily_ceiling(self):
        with mock.patch.object(naptable_server, 'UNIDENTIFIED_SHARES_PER_DAY', 2):
            self.share(); self.share()
            self.assertIn('已达上限', self.share(expect=429)['error'])
        stats = self.req('GET', '/v1/admin/abuse', headers={'X-Admin-Token': 'admin-test'})
        self.assertEqual((stats['shares']['total'], stats['shares']['createdToday'], stats['shares']['unidentifiedToday']), (2, 2, 2))
        self.assertEqual(stats['appAttest']['mode'], 'enforce')

    def test_idle_shares_expire_unless_read_or_followed(self):
        idle, read, followed = (self.share(courses=[dict(self.SHARE['courses'][0], start_time=n)])['id'] for n in (1, 2, 3))
        old = (datetime.now(timezone.utc) - timedelta(days=naptable_server.SHARE_IDLE_DAYS + 1)).isoformat()
        with self.store.lock:
            self.store.db.execute("UPDATE shares SET updated_at=?, last_read_at=?", (old, old))
            self.store.db.execute("CREATE TABLE la_timetables(device TEXT, follow_scope TEXT)")
            self.store.db.execute("INSERT INTO la_timetables SELECT 'd', schedule_scope FROM shares WHERE code=?", (followed,))
            self.store.db.commit()
        self.req('GET', f'/v1/shares/{read}/meta')  # a reader keeps it alive
        self.assertEqual(self.store.expire_shares(), 1)
        self.req('GET', f'/v1/shares/{idle}', expect=404)
        self.req('GET', f'/v1/shares/{read}')
        self.req('GET', f'/v1/shares/{followed}')

    def test_an_unknown_key_is_told_to_attest_again(self):
        import http.client, json
        connection = http.client.HTTPConnection('127.0.0.1', self.http.server_port, timeout=5)
        self.addCleanup(connection.close)
        connection.request('POST', '/v1/shares', body=json.dumps(self.SHARE), headers={
            'Content-Type': 'application/json', 'X-App-Attest-Key': 'forgotten', 'X-App-Attest-Assertion': 'x', 'X-App-Attest-Time': '0'})
        response = connection.getresponse()
        response.read()
        self.assertEqual((response.status, response.getheader('X-App-Attest-Status')), (201, 'unknownKey'))

    def test_attest_endpoints(self):
        self.assertIn('challenge', self.req('POST', '/v1/app-attest/challenge'))
        # No Team ID configured yet: nothing can be attested.
        self.assertIn('not configured', self.req('POST', '/v1/app-attest/keys', {'keyId': 'a', 'attestation': 'b',
                      'challenge': self.req('POST', '/v1/app-attest/challenge')['challenge']}, expect=400)['error'])


class EnforcedTests(JSONClientMixin, unittest.TestCase):
    """The default `enforce` mode over HTTP, as a simulator sees it."""
    def setUp(self):
        file = tempfile.NamedTemporaryFile(suffix='.sqlite3')
        self.addCleanup(file.close)
        self.store = Store(file.name)
        self.addCleanup(self.store.close)
        self.http = LiveServer(self.store)
        self.addCleanup(self.http.shutdown)

    def test_a_forged_assertion_is_refused(self):
        attest = self.http.server.config.app.state.attest
        with attest.lock:
            attest.db.execute("INSERT INTO attest_keys VALUES('k', ?, 0, 'production', 0, 0)", (FakeDevice().key.public_key().public_bytes(
                serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo),))
            attest.db.commit()
        attest.app_id = lambda: APP_ID
        forged = {'X-App-Attest-Key': 'k', 'X-App-Attest-Time': str(int(datetime.now(timezone.utc).timestamp())),
                  'X-App-Attest-Assertion': base64.b64encode(cbor({'signature': b'x', 'authenticatorData': b'y' * 37})).decode()}
        self.assertEqual(self.req('POST', '/v1/shares', ShareQuotaTests.SHARE, forged, expect=401)['error'], 'invalid app attest assertion')

    def test_unattested_writes_pass_within_their_address_limit(self):
        # No assertion, as from a simulator: published, and counted by address.
        self.req('POST', '/v1/shares', ShareQuotaTests.SHARE, expect=201)
        self.req('GET', '/v1/schools')  # reads are never checked
        installation = '0' * 8 + '-0000-0000-0000-' + '0' * 12
        report = {'consentVersion': 1, 'systemName': 'iOS', 'systemVersion': '26.0', 'deviceModel': 'arm64', 'appVersion': '1.0'}
        with mock.patch.dict(naptable_server.UNATTESTED_PER_HOUR, {'usage.report': 2}):
            for _ in range(2):
                self.req('POST', f'/v1/usage/devices/{installation}', report, {'X-Device-Secret': 's' * 32})
            self.assertIn('太频繁', self.req('POST', f'/v1/usage/devices/{installation}', report, {'X-Device-Secret': 's' * 32}, expect=429)['error'])


class LiveActivityAbuseTests(unittest.TestCase):
    """Follower caps and dormant devices, on the scheduling fixture (without re-running its tests)."""
    Fixture = scheduled.ScheduledTests
    setUp, upload, share, restart = Fixture.setUp, Fixture.upload, Fixture.share, Fixture.restart
    def test_a_share_has_a_follower_ceiling(self):
        self.share()
        with mock.patch('server.live_activity_v2.MAX_FOLLOWERS', 1):
            self.upload(follow={"share": "share1"})
            # Uploading again as a follower is not a new follower.
            self.upload(revision=2, follow={"share": "share1"})
            other = self.service.register({'installationId': 'installation-2', 'bundleID': self.client.bundle_id,
                                           'environment': 'sandbox'}, 'other-secret')['deviceID']
            body = dict(copy.deepcopy(self.body), follow={"share": "share1"})
            with self.assertRaises(ProtocolError) as caught:
                self.service.put_timetable(other, body)
            self.assertEqual(caught.exception.status, 429)

    def test_dormant_devices_without_a_token_are_not_planned(self):
        self.upload()
        with self.service.transaction() as db:
            db.execute("UPDATE la_v2_devices SET token='', last_seen=?", (self.clock - 31 * 86400,))
        self.assertNotIn(self.id, self.restart().plans)
        # Its next request plans it again.
        restarted = self.restart()
        restarted.authenticate(self.id, 'persisted-secret')
        self.assertIn(self.id, restarted.plans)

if __name__ == '__main__':
    unittest.main()

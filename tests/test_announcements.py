import copy
import os
import tempfile
import time
import unittest
from unittest.mock import patch

from server import announcements
from server.naptable_server import Store
from tests.server_support import JSONClientMixin, LiveServer


def message(**changes):
    return dict(id='release-1', kind='update', platform='ios', enabled=True,
                title='新版本', subtitle='更好的课表', body='## 新变化\n- **更快**的体验',
                version='1.10.0', minVersion='', maxVersion='', actionTitle='前往更新',
                actionURL='https://apps.apple.com/app/id123456', startsAt=None, endsAt=None, **{}) | changes


class AnnouncementValidationTests(unittest.TestCase):
    def test_version_order_and_equivalence(self):
        self.assertGreater(announcements.version('1.10'), announcements.version('1.9'))
        self.assertEqual(announcements.version('1.0.0'), announcements.version('1'))
        for value in ('v1.2', '1..2', '1.2b', '1.2.3.4.5', '-1', '１２', '9999999'):
            with self.subTest(value=value), self.assertRaises(ValueError): announcements.version(value)

    def test_invalid_publications(self):
        changes = [dict(title=''), dict(body=''), dict(body='a' * 12001), dict(enabled=1),
                   dict(kind='html'), dict(platform='android'), dict(id='../x'), dict(version=''),
                   dict(minVersion='2', maxVersion='1.9'), dict(actionURL=''),
                   dict(actionURL='javascript:alert(1)'), dict(actionURL='http://example.com'),
                   dict(actionURL='https://user:pass@example.com'), dict(actionURL='https://example.com/\nx'),
                   dict(startsAt=float('nan')), dict(endsAt=True), dict(startsAt=10, endsAt=10)]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                announcements.validate(dict(revision=0, messages=[message(**change)]))
        for value in ({}, dict(revision=True, messages=[]), dict(revision=0, messages=[message()] * 2),
                      dict(revision=0, messages=[message(id=str(i)) for i in range(31)])):
            with self.assertRaises(ValueError): announcements.validate(value)

    def test_window_boundaries_and_notice_without_link(self):
        row = message(kind='notice', version='', actionURL='', startsAt=100, endsAt=200)
        self.assertFalse(announcements.active(row, 99))
        self.assertTrue(announcements.active(row, 100))
        self.assertFalse(announcements.active(row, 200))
        self.assertFalse(announcements.active(row | dict(enabled=False), 150))
        self.assertEqual(announcements.validate(dict(revision=0, messages=[row]))[0], row)


class AnnouncementHTTPTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = self.temp.name + '/data.sqlite3'
        self.store = Store(self.path)
        self.env = patch.dict(os.environ, NAPTABLE_ADMIN_TOKEN='publication-test')
        self.env.start()
        self.http = LiveServer(self.store)
        self.headers = {'X-Admin-Token': 'publication-test'}

    def tearDown(self):
        self.http.shutdown()
        self.store.close()
        self.env.stop()
        self.temp.cleanup()

    def test_auth_round_trip_persistence_and_stale_write(self):
        self.req('GET', '/v1/admin/announcements', expect=403)
        value = dict(revision=0, messages=[message()])
        self.req('POST', '/v1/admin/announcements', value, expect=403)
        self.assertEqual(self.req('GET', '/v1/announcements'), {'messages': []})
        saved = self.req('POST', '/v1/admin/announcements', value, self.headers)
        self.assertEqual(saved['revision'], 1)
        self.assertEqual(saved, self.req('GET', '/v1/admin/announcements', headers=self.headers))
        self.req('POST', '/v1/admin/announcements', value, self.headers, expect=400)
        bad = copy.deepcopy(saved); bad['messages'][0]['actionURL'] = 'javascript:alert(1)'
        self.req('POST', '/v1/admin/announcements', bad, self.headers, expect=400)
        reopened = Store(self.path)
        try: self.assertEqual(reopened.announcement_config(), saved)
        finally: reopened.close()
        self.assertEqual(self.req('GET', '/v1/announcements')['messages'], saved['messages'])
        audit = self.store.audit_log('announcement')['entries']
        self.assertEqual(len(audit), 1)
        self.assertEqual(audit[0]['action'], 'announcement.save')

    def test_drafts_scheduled_expired_and_withdrawn_are_not_public(self):
        stamp = time.time()
        items = [message(id='live'), message(id='draft', enabled=False),
                 message(id='future', startsAt=stamp + 1000), message(id='expired', endsAt=stamp - 1)]
        saved = self.req('POST', '/v1/admin/announcements', dict(revision=0, messages=items), self.headers)
        self.assertEqual([row['id'] for row in self.req('GET', '/v1/announcements')['messages']], ['live'])
        self.assertEqual(len(saved['messages']), 4)
        self.req('POST', '/v1/admin/announcements', dict(revision=1, messages=[]), self.headers)
        self.assertEqual(self.req('GET', '/v1/announcements')['messages'], [])

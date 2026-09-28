import http.client
import json
import os
import tempfile
import threading
import unittest
from unittest.mock import patch

from server.naptable_server import Store
from tests.server_support import JSONClientMixin, LiveServer


class SchoolManagementTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = self.directory.name + '/schools.sqlite3'
        self.store = Store(self.path)
        self.http = LiveServer(self.store)
        self.environment = patch.dict(os.environ, {'NAPTABLE_ADMIN_TOKEN': 'school-test'})
        self.environment.start()
        self.headers = {'X-Admin-Token': 'school-test'}

    def tearDown(self):
        self.http.shutdown()
        self.store.close()
        self.environment.stop()
        self.directory.cleanup()

    def test_create_delete_authentication_and_restart(self):
        self.assertEqual([s['id'] for s in self.store.schools()], ['nju'])
        value = {'name': '测试大学', 'periods': [{'start': '08:00', 'end': '08:50'}]}
        self.req('POST', '/v1/schools/test', value, expect=403)
        created = self.req('POST', '/v1/schools/test', value, self.headers)
        self.assertEqual(created['name'], value['name'])
        self.req('DELETE', '/v1/schools/test', expect=403)
        self.assertEqual(len(self.store.schools()), 2)
        self.req('DELETE', '/v1/schools/test', headers=self.headers)
        self.req('DELETE', '/v1/schools/test', headers=self.headers, expect=404)
        share = self.req('POST', '/v1/shares', {'owner': 'A', 'schoolID': 'nju',
                         'termID': '2026-fall-template', 'courses': [{'name': '数学'}]}, expect=201)
        self.req('DELETE', '/v1/schools/nju', headers=self.headers)
        self.assertIsNone(self.store.find_term('nju', '2026-fall-template'))
        fetched = self.req('GET', '/v1/shares/' + share['id'])
        self.assertEqual(fetched['courses'][0]['name'], '数学')
        reopened = Store(self.path)
        try:
            self.assertEqual(reopened.schools(), [])
        finally:
            reopened.close()

    def test_upgrade_removes_legacy_cpu_only_once(self):
        self.store.save_school({'id': 'cpu', 'name': '中国药科大学',
            'note': 'CPU 客户端共享服务配置；校历以 CPU 教务数据为准',
            'periods': [{'start': '08:00', 'end': '08:45'}]})
        self.store.db.execute('DELETE FROM configuration_migrations')
        self.store.db.commit()
        reopened = Store(self.path)
        try:
            self.assertEqual([s['id'] for s in reopened.schools()], ['nju'])
            reopened.save_school({'id': 'cpu', 'name': '管理员学校',
                'periods': [{'start': '08:00', 'end': '08:45'}]})
            reopened.seed()
            self.assertEqual(len(reopened.schools()), 2)
        finally:
            reopened.close()

    def test_rename_school_keeps_terms_shares_usage_and_channels(self):
        share = self.req('POST', '/v1/shares', {'owner': 'A', 'schoolID': 'nju',
                         'termID': '2026-fall-template', 'courses': [{'name': '数学'}]}, expect=201)
        self.store.db.execute("INSERT INTO usage_devices VALUES ('device','secret','nju','iOS','26','phone','1',1,'2026','2026')")
        self.store.db.execute("CREATE TABLE la_devices (device_id TEXT, school_id TEXT)")
        self.store.db.execute("INSERT INTO la_devices VALUES ('push','nju')")
        self.store.db.commit()
        self.store.save_apns_config({'channels': {'production:nju': 'channel-a', 'sandbox:nju': 'channel-b'}})
        endpoint = '/v1/admin/schools/nju/rename'
        self.req('POST', endpoint, {'id': 'new-nju'}, expect=403)
        self.req('POST', endpoint, {'id': 'x'}, self.headers, expect=400)
        self.req('POST', endpoint, {'id': 'bad/id'}, self.headers, expect=400)
        self.req('POST', endpoint, {'id': 'new-nju'}, self.headers, expect=200)
        schools = self.req('GET', '/v1/schools')['schools']
        self.assertEqual([school['id'] for school in schools], ['new-nju'])
        self.assertEqual(schools[0]['currentTermID'], '2026-fall-template')
        self.assertIsNotNone(self.store.find_term('new-nju', '2026-fall-template'))
        self.assertIsNone(self.store.find_term('nju', '2026-fall-template'))
        self.assertEqual(self.store.db.execute('SELECT school_id FROM usage_devices').fetchone()[0], 'new-nju')
        self.assertEqual(self.store.db.execute('SELECT school_id FROM la_devices').fetchone()[0], 'new-nju')
        self.assertEqual(self.store.apns_config()['channels'], {'production:new-nju': 'channel-a', 'sandbox:new-nju': 'channel-b'})
        self.assertEqual(self.req('GET', '/v1/shares/' + share['id'])['schoolID'], 'new-nju')
        self.assertEqual(self.req('GET', '/v1/shares/' + share['id'])['courses'][0]['name'], '数学')
        self.assertEqual(self.req('POST', '/v1/shares/' + share['id'] + '/resync',
                         headers={'X-Write-Token': share['writeToken']})['schoolID'], 'new-nju')
        self.assertEqual(self.req('POST', '/v1/admin/schools/nju/rename', {'id': 'third'}, self.headers, expect=404)['error'], 'school not found')
        reopened = Store(self.path)
        try:
            self.assertEqual([school['id'] for school in reopened.schools()], ['new-nju'])
        finally:
            reopened.close()

    def test_rename_rejects_collision_without_changing_any_associations(self):
        self.req('POST', '/v1/schools/test', {'name': '测试大学', 'periods': [{'start': '08:00', 'end': '08:50'}]}, self.headers)
        self.req('POST', '/v1/admin/schools/nju/rename', {'id': 'test'}, self.headers, expect=400)
        self.assertEqual([school['id'] for school in self.store.schools()], ['nju', 'test'])
        self.assertIsNotNone(self.store.find_term('nju', '2026-fall-template'))

    def test_rename_rolls_back_when_a_related_table_rejects_the_change(self):
        self.store.db.execute("CREATE TRIGGER fail_school_rename BEFORE UPDATE OF school_id ON school_terms "
                              "BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        self.store.db.commit()
        with self.assertRaises(Exception):
            self.store.rename_school('nju', 'new-nju')
        self.assertEqual([school['id'] for school in self.store.schools()], ['nju'])
        self.assertIsNotNone(self.store.find_term('nju', '2026-fall-template'))


class AdminWriteTests(JSONClientMixin, unittest.TestCase):
    """Term and school writes: validation, one transaction each, and the
    `create` contract of admin.js; request bodies and HEAD."""
    setUp, tearDown = SchoolManagementTests.setUp, SchoolManagementTests.tearDown
    term = {'id': '2027-spring', 'semesterStartMonday': '2027-02-22', 'weekCount': 17, 'timezone': 'Asia/Shanghai', 'note': ''}

    def raw(self, method, path, body=b'', headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.http.server_port, timeout=5)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def current(self):
        return self.req('GET', '/v1/schools')['schools'][0]['currentTermID']

    def test_terms_keep_one_current_and_count_versions(self):
        endpoint = '/v1/admin/schools/nju/terms'
        added = self.req('POST', endpoint, self.term, self.headers)
        self.assertEqual((added['version'], added['current'], self.current()), (1, False, '2026-fall-template'))
        again = self.req('POST', endpoint, dict(self.term, current=True), self.headers)
        self.assertEqual((again['version'], again['current'], self.current()), (2, True, '2027-spring'))
        # Clearing the only current term keeps it current.
        self.assertTrue(self.req('POST', endpoint, dict(self.term, current=False), self.headers)['current'])
        for broken in (dict(self.term, note=3), dict(self.term, note=['x']), dict(self.term, current='yes'),
                       dict(self.term, id=7), dict(self.term, semesterStartMonday=20270222), dict(self.term, weekCount=41)):
            with self.subTest(broken=broken):
                self.req('POST', endpoint, broken, self.headers, expect=400)
        self.req('POST', '/v1/admin/schools/nope/terms', self.term, self.headers, expect=400)
        self.assertFalse(self.store.db.in_transaction)

    def test_a_failed_term_write_rolls_back_and_leaves_no_transaction_open(self):
        self.store.db.execute("CREATE TRIGGER fail_term BEFORE INSERT ON school_terms BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        self.store.db.commit()
        failed = self.req('POST', '/v1/admin/schools/nju/terms', dict(self.term, current=True), self.headers, expect=500)
        self.assertEqual(failed, {'error': 'internal error'})
        self.assertFalse(self.store.db.in_transaction)
        # `is_current=0` ran before the insert failed: it was undone too.
        self.assertEqual(self.current(), '2026-fall-template')
        with self.assertRaises(Exception):
            self.store.save_term('nju', dict(self.term, current=True))
        self.assertFalse(self.store.db.in_transaction)
        self.assertEqual(self.current(), '2026-fall-template')

    def test_school_fields_must_be_strings(self):
        periods = [{'start': '08:00', 'end': '08:50'}]
        for broken in ({'name': 3}, {'name': '学校', 'note': {'a': 1}}, {'name': '学校', 'semesterStart': 20260901}, {'name': ['学校']}):
            with self.subTest(broken=broken):
                self.req('POST', '/v1/schools/test', dict(broken, periods=periods), self.headers, expect=400)
        self.assertEqual([s['id'] for s in self.store.schools()], ['nju'])
        self.assertFalse(self.store.db.in_transaction)

    def test_create_never_overwrites_a_school(self):
        periods = [{'start': '07:00', 'end': '07:50'}]
        conflict = self.req('POST', '/v1/schools/nju', {'name': '覆盖', 'periods': periods, 'create': True}, self.headers, expect=409)
        self.assertEqual(conflict, {'error': 'school exists'})
        self.assertEqual(self.store.schools()[0]['name'], '南京大学')
        created = self.req('POST', '/v1/schools/test', {'name': '测试大学', 'periods': periods, 'create': True}, self.headers)
        self.assertEqual((created['id'], created['name']), ('test', '测试大学'))
        # Without `create` (or with anything but true) a save updates, as before.
        self.assertEqual(self.req('POST', '/v1/schools/nju', {'name': '新名字', 'periods': periods}, self.headers)['name'], '新名字')
        self.assertEqual(self.req('POST', '/v1/schools/nju', {'name': '再改', 'periods': periods, 'create': 'true'}, self.headers)['name'], '再改')

    def test_a_body_must_be_a_json_object(self):
        for body in (b'[1,2]', b'"text"', b'3', b'null', b'{bad', b'\xff\xfe'):
            with self.subTest(body=body):
                status, _, raw = self.raw('POST', '/v1/admin/calendar', body, {**self.headers, 'Content-Length': str(len(body))})
                self.assertEqual(status, 400)
                self.assertIn('error', json.loads(raw))
        status, _, raw = self.raw('POST', '/v1/shares', b'[]', {'Content-Length': '2'})
        self.assertEqual((status, json.loads(raw)['error']), (400, 'request body must be a JSON object'))
        status, _, _ = self.raw('POST', '/v1/admin/calendar', b'{}', {**self.headers, 'Content-Length': 'many'})
        self.assertEqual(status, 400)

    def test_a_non_ascii_credential_is_refused_not_crashed(self):
        for token in ('clé', '管理员'):
            status, _, raw = self.raw('GET', '/v1/admin/session', headers={'X-Admin-Token': token.encode().decode('latin-1')})
            self.assertEqual((status, json.loads(raw)), (403, {'error': 'admin token required'}))
            body = json.dumps({'token': token}).encode()
            status, _, raw = self.raw('POST', '/v1/admin/session', body, {'Content-Length': str(len(body))})
            self.assertEqual(status, 403)

    def test_head_answers_like_get_without_a_body(self):
        for path, cache in (('/', 'no-store'), ('/privacy', 'no-store'), ('/admin', 'no-store'),
                            ('/site/site.css', 'public, max-age=86400'), ('/health', None), ('/v1/schools', None)):
            with self.subTest(path=path):
                got, got_headers, body = self.raw('GET', path)
                status, headers, empty = self.raw('HEAD', path)
                self.assertEqual((status, empty), (got, b''))
                self.assertEqual(headers['Content-Length'], str(len(body)))
                self.assertEqual(headers['Content-Type'], got_headers['Content-Type'])
                if cache: self.assertEqual((headers['Cache-Control'], got_headers['Cache-Control']), (cache, cache))
        status, _, empty = self.raw('HEAD', '/nope')
        self.assertEqual((status, empty), (404, b''))


class HTTPContractTests(JSONClientMixin, unittest.TestCase):
    """What the stdlib handler answered at the edges, which the FastAPI app
    must keep: released apps and the console depend on these exact shapes."""
    setUp, tearDown = SchoolManagementTests.setUp, SchoolManagementTests.tearDown
    raw = AdminWriteTests.raw

    def test_anything_unrouted_is_a_json_not_found(self):
        for method, path in (('GET', '/nope'), ('POST', '/nope'), ('PUT', '/nope'), ('DELETE', '/nope'),
                             ('PUT', '/health'), ('DELETE', '/v1/schools'), ('POST', '/v1/calendar'),
                             ('GET', '/docs'), ('GET', '/openapi.json'), ('GET', '/redoc'), ('GET', '/health/'),
                             ('GET', '/v1/%73chools'), ('GET', '/static/admin.html'), ('GET', '*'),
                             ('POST', '/v1/shares/X/other'), ('POST', '/v1/admin/schools/nju/other'),
                             ('DELETE', '/v1/schools/a/b'), ('GET', '/v2/live-activity/devices/x')):
            with self.subTest(method=method, path=path):
                status, headers, raw = self.raw(method, path, headers=self.headers)
                self.assertEqual((status, raw), (404, b'{"error": "not found"}'))
                self.assertEqual(headers['Content-Type'], 'application/json; charset=utf-8')
                self.assertEqual(headers['Content-Length'], str(len(raw)))

    def test_methods_without_a_handler_are_not_implemented(self):
        for method in ('PATCH', 'OPTIONS', 'get'):
            with self.subTest(method=method):
                status, headers, raw = self.raw(method, '/health')
                self.assertEqual(status, 501)
                self.assertEqual((headers['Content-Type'], headers['Connection']), ('text/html;charset=utf-8', 'close'))
                self.assertIn(f"Unsupported method ('{method}')", raw.decode())

    def test_the_path_is_matched_as_sent(self):
        # `%2F` is part of the code, not a separator; a leading `//` collapses.
        status, _, raw = self.raw('GET', '/v1/shares/AB%2FCD')
        self.assertEqual((status, json.loads(raw)), (404, {'error': 'share not found'}))
        self.assertEqual(self.raw('GET', '//health')[:3:2], (200, b'{"ok": true}'))
        self.assertEqual(self.raw('GET', '/health?probe=1')[0], 200)
        self.assertEqual(self.raw('GET', '/admin/')[0], 200)
        status, _, raw = self.raw('POST', '/v1/shares/replace', b'{}', {'Content-Length': '2'})
        self.assertEqual((status, json.loads(raw)), (400, {'error': 'unknown schoolID/termID'}))

    def test_console_assets_are_cached_only_by_version(self):
        for query, cache in (('?v=3', 'public, max-age=86400'), ('?v=', 'no-store'), ('', 'no-store')):
            with self.subTest(query=query):
                status, headers, _ = self.raw('GET', '/static/admin.js' + query)
                self.assertEqual((status, headers['Cache-Control']), (200, cache))

    def test_a_route_refuses_before_it_reads_the_body(self):
        oversized = {'Content-Length': str(1024 * 1024 + 1)}
        status, _, raw = self.raw('POST', '/v1/admin/calendar', headers=oversized)
        self.assertEqual((status, json.loads(raw)), (403, {'error': 'admin token required'}))
        status, _, raw = self.raw('POST', '/v1/admin/calendar', headers={**self.headers, **oversized})
        self.assertEqual((status, json.loads(raw)), (400, {'error': 'request body exceeds 1048576 bytes'}))

    def test_a_body_without_a_length_is_empty(self):
        # Only Content-Length was ever read: a chunked upload counts as `{}`.
        body = json.dumps({'token': 'school-test'}).encode()
        status, _, raw = self.raw('POST', '/v1/admin/session', b'%x\r\n%s\r\n0\r\n\r\n' % (len(body), body),
                                  {'Transfer-Encoding': 'chunked'})
        self.assertEqual((status, json.loads(raw)), (403, {'error': 'admin token required'}))
        status, _, raw = self.raw('POST', '/v1/shares', b'3\r\n[1]\r\n0\r\n\r\n', {'Transfer-Encoding': 'chunked'})
        self.assertEqual((status, json.loads(raw)), (400, {'error': 'unknown schoolID/termID'}))

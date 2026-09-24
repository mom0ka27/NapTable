import os
import tempfile
import threading
import unittest
from unittest.mock import patch

from server.naptable_server import Handler, Store
from tests.server_support import FastServer, JSONClientMixin


class SchoolManagementTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = self.directory.name + '/schools.sqlite3'
        self.store = Store(self.path)
        self.handler = type('SchoolHandler', (Handler,), {'store': self.store, 'live_activity': None})
        self.http = FastServer(('127.0.0.1', 0), self.handler)
        self.thread = threading.Thread(target=self.http.serve_forever)
        self.thread.start()
        self.environment = patch.dict(os.environ, {'NAPTABLE_ADMIN_TOKEN': 'school-test'})
        self.environment.start()
        self.headers = {'X-Admin-Token': 'school-test'}

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()
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

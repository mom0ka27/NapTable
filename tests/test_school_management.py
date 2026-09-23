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

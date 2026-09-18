"""HTTP regressions for server-owned timetable configuration."""
import json
import os
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from server.naptable_server import Handler, Store


class TermAuthorityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.directory.name, 'schedule.sqlite3')
        self.store = Store(self.path)
        handler = type('TestHandler', (Handler,), {'store': self.store})
        self.http = ThreadingHTTPServer(('127.0.0.1', 0), handler)
        self.thread = threading.Thread(target=self.http.serve_forever)
        self.thread.start()
        self.env = patch.dict(os.environ, {'NAPTABLE_ADMIN_TOKEN': 'term-test-admin'})
        self.env.start()

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()
        self.store.close()
        self.env.stop()
        self.directory.cleanup()

    def request(self, method, path, payload=None, admin=False):
        data = None if payload is None else json.dumps(payload).encode()
        headers = {'Content-Type': 'application/json'}
        if admin:
            headers['X-Admin-Token'] = 'term-test-admin'
        request = Request(f'http://127.0.0.1:{self.http.server_port}{path}', data=data,
                          headers=headers, method=method)
        try:
            with urlopen(request) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            with error:
                return error.code, json.load(error)

    def term(self):
        return {'id': 'verified-test', 'semesterStartMonday': '2026-09-14',
                'weekCount': 20, 'timezone': 'Asia/Shanghai', 'note': 'Test only',
                'periods': [{'id': 1, 'name': '第1节', 'start': '07:30', 'end': '08:15'},
                            {'id': 2, 'name': '第2节', 'start': '08:25', 'end': '09:10'}]}

    def test_authority_version_snapshot_and_restart(self):
        term = self.term()
        path = '/v1/admin/schools/nju/terms'
        status, saved = self.request('POST', path, term, admin=True)
        self.assertEqual(status, 200)
        self.assertEqual(saved['version'], 1)
        status, shared = self.request('POST', '/v1/shares', {
            'schoolID': 'nju', 'termID': term['id'], 'courses': [],
            'semesterStartMonday': '1999-01-04',
            'classTimeList': [{'start': '00:00', 'end': '00:01'}]})
        self.assertEqual(status, 201)
        self.assertEqual(shared['semester_start_monday'], term['semesterStartMonday'])
        self.assertEqual(shared['class_time_list'][0]['start'], '07:30')
        self.assertEqual(shared['term_week_count'], 20)
        term['semesterStartMonday'] = '2026-09-21'
        term['periods'][0]['start'] = '07:45'
        status, updated = self.request('POST', path, term, admin=True)
        self.assertEqual(status, 200)
        self.assertEqual(updated['version'], 2)
        status, old = self.request('GET', '/v1/shares/' + shared['id'])
        self.assertEqual(status, 200)
        self.assertEqual(old['termVersion'], 1)
        self.assertEqual(old['semester_start_monday'], '2026-09-14')
        self.assertEqual(old['class_time_list'][0]['start'], '07:30')
        reopened = Store(self.path)
        try:
            self.assertEqual(reopened.find_term('nju', term['id'])['version'], 2)
            self.assertEqual(reopened.get(shared['id'])['termVersion'], 1)
        finally:
            reopened.close()

    def test_adjustments_ride_along_with_the_term(self):
        """调休跟着学期配置走：保存、下发、分享快照都要带上。"""
        path = '/v1/admin/schools/nju/terms'
        term = self.term()
        term['adjustments'] = [
            {'date': '2026-10-01', 'kind': 'off', 'note': '国庆节'},
            {'date': '2026-10-11', 'kind': 'swap', 'source': '2026-10-09', 'note': '补周五的课'},
        ]
        status, saved = self.request('POST', path, term, admin=True)
        self.assertEqual(status, 200)
        self.assertEqual(len(saved['adjustments']), 2)
        # 放假条目不该把空的 source 一起存下来，客户端按 kind 分支。
        self.assertNotIn('source', saved['adjustments'][0])
        self.assertEqual(saved['adjustments'][1]['source'], '2026-10-09')

        status, catalogue = self.request('GET', '/v1/schools')
        self.assertEqual(status, 200)
        listed = [item for school in catalogue['schools'] for item in school['terms']
                  if item['id'] == term['id']][0]
        self.assertEqual(len(listed['adjustments']), 2)

        status, shared = self.request('POST', '/v1/shares', {
            'schoolID': 'nju', 'termID': term['id'], 'courses': []})
        self.assertEqual(status, 201)
        status, fetched = self.request('GET', '/v1/shares/' + shared['id'])
        self.assertEqual(status, 200)
        self.assertEqual(fetched['calendar_adjustments'], saved['adjustments'])

        # 分享是学期当时的快照：学期后来清空调休，老分享码还是老安排。
        term['adjustments'] = []
        self.assertEqual(self.request('POST', path, term, admin=True)[0], 200)
        status, old_share = self.request('GET', '/v1/shares/' + shared['id'])
        self.assertEqual(len(old_share['calendar_adjustments']), 2)

    def test_invalid_adjustments_are_rejected(self):
        path = '/v1/admin/schools/nju/terms'
        broken = [
            [{'date': '2026-13-01', 'kind': 'off'}],
            [{'date': '2026-02-30', 'kind': 'off'}],
            [{'date': '2026-10-11', 'kind': 'swap'}],
            [{'date': '2026-10-11', 'kind': 'swap', 'source': '不是日期'}],
            [{'date': '2026-10-11', 'kind': '放假'}],
            ['2026-10-11'],
            'off',
        ]
        for adjustments in broken:
            term = self.term()
            term['adjustments'] = adjustments
            self.assertEqual(self.request('POST', path, term, admin=True)[0], 400, adjustments)
        # 老客户端不发这个字段，仍然要能保存。
        term = self.term()
        term.pop('adjustments', None)
        status, saved = self.request('POST', path, term, admin=True)
        self.assertEqual(status, 200)
        self.assertEqual(saved['adjustments'], [])

    def test_invalid_configuration_and_missing_admin(self):
        path = '/v1/admin/schools/nju/terms'
        self.assertEqual(self.request('POST', path, self.term())[0], 403)
        for date in ['2026-09-15', '2026-02-30']:
            term = self.term()
            term['semesterStartMonday'] = date
            self.assertEqual(self.request('POST', path, term, admin=True)[0], 400)
        for weeks in [-1, 0, 41, 2.5]:
            term = self.term()
            term['weekCount'] = weeks
            self.assertEqual(self.request('POST', path, term, admin=True)[0], 400)
        term = self.term()
        term['periods'][1]['start'] = '08:00'
        self.assertEqual(self.request('POST', path, term, admin=True)[0], 400)
        self.assertEqual(self.request('POST', '/v1/shares', {
            'schoolID': 'nju', 'termID': 'missing', 'courses': []})[0], 400)

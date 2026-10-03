import hashlib, http.client, json, os, re, sqlite3, tempfile, threading, unittest
from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from server.naptable_server import MAX_REQUEST_BYTES, STATIC_ROOT, Store
from tests.server_support import LiveServer

class ServerTests(unittest.TestCase):
    def setUp(self):
        self.db=tempfile.NamedTemporaryFile(suffix='.sqlite3'); self.store=Store(self.db.name)
        self.http=LiveServer(self.store); self.base=f'http://127.0.0.1:{self.http.server_port}'
    def tearDown(self): self.http.shutdown(); self.store.close(); self.db.close()
    def req(self, method, path, value=None, headers=None):
        data=None if value is None else json.dumps(value).encode(); h={'Content-Type':'application/json'}; h.update(headers or {})
        try:
            r=urlopen(Request(self.base+path,data=data,method=method,headers=h));
            with r: return json.loads(r.read())
        except HTTPError as error:
            error.close(); raise
    def test_share_read_update_revoke(self):
        payload={'owner':'A','schoolID':'nju','termID':'2026-fall-template','courses':[{'name':'数学'}]}
        created=self.req('POST','/v1/shares',payload); code=created['id']; token=created['writeToken']
        fetched=self.req('GET','/v1/shares/'+code)
        self.assertEqual(fetched['courses'][0]['name'],'数学'); self.assertEqual(fetched['semester_start_monday'],'2026-09-14'); self.assertEqual(fetched['term_week_count'],18)
        self.req('PUT','/v1/shares/'+code,{'schoolID':'nju','termID':'2026-fall-template','courses':[{'name':'物理'}]}, {'X-Write-Token':token})
        fetched=self.req('GET','/v1/shares/'+code)
        self.assertEqual(fetched['courses'][0]['name'],'物理'); self.assertEqual(fetched['semester_start_monday'],'2026-09-14'); self.assertEqual(fetched['class_time_list'][0]['start'],'08:00')
        with self.assertRaises(HTTPError) as caught: self.req('DELETE','/v1/shares/'+code,headers={'X-Write-Token':'wrong'})
        self.assertEqual(caught.exception.code, 403)
        self.req('DELETE','/v1/shares/'+code,headers={'X-Write-Token':token})
        with self.assertRaises(Exception): self.req('GET','/v1/shares/'+code)
        self.assertIsNone(self.store.db.execute('SELECT 1 FROM shares WHERE code=?',(code,)).fetchone())
        with self.assertRaises(HTTPError) as caught: self.req('DELETE','/v1/shares/'+code,headers={'X-Write-Token':token})
        self.assertEqual(caught.exception.code, 404)
    def test_replacing_a_share_deletes_the_old_code(self):
        payload={'owner':'A','schoolID':'nju','termID':'2026-fall-template','courses':[{'name':'数学'}]}
        old=self.req('POST','/v1/shares',payload); extra=self.req('POST','/v1/shares',payload)
        new=self.req('POST','/v1/shares/'+old['id']+'/replace',{**payload,'courses':[{'name':'物理'}],
            'previousShares':[{'code':extra['id'],'token':extra['writeToken']}]},{'X-Write-Token':old['writeToken']})
        codes={row[0] for row in self.store.db.execute('SELECT code FROM shares')}
        self.assertEqual(codes, {new['id']})
    def test_startup_purges_shares_flagged_by_older_servers(self):
        created=self.req('POST','/v1/shares',{'owner':'A','schoolID':'nju','termID':'2026-fall-template','courses':[]})
        self.store.db.execute('UPDATE shares SET revoked=1'); self.store.db.commit()
        reopened=Store(self.db.name)
        try: self.assertIsNone(reopened.db.execute('SELECT 1 FROM shares WHERE code=?',(created['id'],)).fetchone())
        finally: reopened.close()
    def test_school_persists(self):
        school=self.req('GET','/v1/schools')['schools'][0]
        self.assertEqual(school['id'],'nju'); self.assertTrue(school['periods'])
        self.assertEqual(school['terms'][0]['periods'], school['periods'])
        self.assertEqual(school['currentTermID'], school['terms'][0]['id'])
    def test_school_write_requires_admin_and_round_trips_personal_values(self):
        periods=[{'id':1,'name':'第1节','start':'07:30','end':'08:15'}]
        value={'id':'2027-spring','semesterStartMonday':'2027-02-22','weekCount':17,'timezone':'Asia/Shanghai','note':'校准','current':True}
        with self.assertRaises(Exception): self.req('POST','/v1/admin/schools/nju/terms',value)
        old=os.environ.get('NAPTABLE_ADMIN_TOKEN'); os.environ['NAPTABLE_ADMIN_TOKEN']='admin-test'
        try:
            self.req('POST','/v1/admin/schools/nju',{'name':'南京大学','periods':periods,'unifiedHolidaysEnabled':False,'unifiedMakeupEnabled':True},{'X-Admin-Token':'admin-test'})
            self.req('POST','/v1/admin/schools/nju/terms',value,{'X-Admin-Token':'admin-test'})
            self.req('POST','/v1/admin/calendar',{'adjustments':[
                {'date':'2027-01-01','kind':'off','note':'放假'},
                {'date':'2027-01-02','kind':'swap','source':'2026-12-31','note':'补班'}
            ]},{'X-Admin-Token':'admin-test'})
            school=self.req('GET','/v1/schools')['schools'][0]
            self.assertFalse(school['unifiedHolidaysEnabled']); self.assertTrue(school['unifiedMakeupEnabled'])
            term=next(item for item in school['terms'] if item['id']=='2027-spring')
            self.assertEqual(term['semesterStartMonday'],'2027-02-22'); self.assertEqual(term['periods'][0]['start'],'07:30'); self.assertEqual(term['version'],2)
            self.assertTrue(term['current']); self.assertEqual(school['currentTermID'],'2027-spring')
            self.assertEqual([item['kind'] for item in term['adjustments']], ['swap'])
        finally:
            if old is None: os.environ.pop('NAPTABLE_ADMIN_TOKEN',None)
            else: os.environ['NAPTABLE_ADMIN_TOKEN']=old
    def test_global_calendar_and_usage_stats_require_admin(self):
        with self.assertRaises(Exception): self.req('GET','/v1/admin/calendar')
        with self.assertRaises(Exception): self.req('GET','/v1/admin/stats')
        old=os.environ.get('NAPTABLE_ADMIN_TOKEN'); os.environ['NAPTABLE_ADMIN_TOKEN']='admin-test'
        try:
            headers={'X-Admin-Token':'admin-test'}
            saved=self.req('POST','/v1/admin/calendar',{'adjustments':[{'date':'2026-10-01','kind':'off','note':'国庆节'}]},headers)
            self.assertEqual(saved['version'],2); self.assertEqual(saved['adjustments'][0]['note'],'国庆节')
            with self.store.lock:
                self.store.db.execute('CREATE TABLE la_devices (device_id TEXT PRIMARY KEY, school_id TEXT, enabled INTEGER)')
                self.store.db.executemany('INSERT INTO la_devices VALUES (?,?,?)', [
                    ('a','nju',1), ('b','nju',1), ('c','cpu',1), ('off','nju',0)])
                self.store.db.commit()
            stats=self.req('GET','/v1/admin/stats',headers=headers)
            self.assertEqual(stats['totalUsers'],0)  # Legacy notification devices are not usage reports.
            self.assertEqual(next(item['users'] for item in stats['schools'] if item['id']=='nju'),0)
        finally:
            if old is None: os.environ.pop('NAPTABLE_ADMIN_TOKEN',None)
            else: os.environ['NAPTABLE_ADMIN_TOKEN']=old
    def test_apns_bundle_change_discards_channels_from_the_old_app(self):
        self.store.save_apns_config({
            'keyPath':'/key.p8','keyID':'K','teamID':'T','bundleID':'old.app',
            'channels':{'production:nju':'old-channel'}})
        saved=self.store.save_apns_config({
            'keyPath':'/key.p8','keyID':'K','teamID':'T','bundleID':'new.app'})
        self.assertEqual(saved['channels'],{})
    def test_legacy_terms_are_promoted_to_the_new_owners(self):
        legacy=tempfile.NamedTemporaryFile(suffix='.sqlite3')
        db=sqlite3.connect(legacy.name)
        db.executescript('''
        CREATE TABLE school_configs (id TEXT PRIMARY KEY,name TEXT,semester_start TEXT,periods_json TEXT,note TEXT,updated_at TEXT);
        CREATE TABLE school_terms (school_id TEXT,term_id TEXT,version INTEGER,semester_start_monday TEXT,week_count INTEGER,periods_json TEXT,timezone TEXT,note TEXT,updated_at TEXT,adjustments_json TEXT,PRIMARY KEY(school_id,term_id));
        CREATE TABLE shares (code TEXT PRIMARY KEY,write_token_hash TEXT,owner TEXT,school_id TEXT,school_name TEXT,payload_json TEXT,created_at TEXT,updated_at TEXT,revoked INTEGER);
        INSERT INTO school_configs VALUES ('legacy','旧学校','','[]','','2026-01-01');
        INSERT INTO school_terms VALUES ('legacy','fall',3,'2026-09-14',18,'[{"id":1,"name":"第1节","start":"08:10","end":"09:00"}]','Asia/Shanghai','','2026-01-01','[{"date":"2026-10-01","kind":"off"}]');
        ''')
        db.commit(); db.close()
        store=Store(legacy.name)
        try:
            school=next(item for item in store.schools() if item['id']=='legacy')
            self.assertEqual(school['periods'][0]['start'],'08:10')
            self.assertEqual(school['currentTermID'],'fall')
            self.assertEqual(store.global_calendar()['adjustments'][0]['date'],'2026-10-01')
        finally:
            store.close(); legacy.close()
    def test_invalid_write_token_is_rejected(self):
        created=self.req('POST','/v1/shares',{'schoolID':'nju','termID':'2026-fall-template','courses':[]})
        with self.assertRaises(Exception): self.req('PUT','/v1/shares/'+created['id'],{'courses':[{'name':'x'}]},{'X-Write-Token':'wrong'})
    def test_admin_web_routes_are_served(self):
        html=self.req_text('GET','/admin')
        self.assertIn('NapTable 管理台', html); self.assertIn('/static/admin.js', html)
        for name in ('admin.css', 'admin.js'):
            digest = hashlib.sha256((STATIC_ROOT / name).read_bytes()).hexdigest()[:16]
            self.assertIn(f'/static/{name}?v={digest}', html)
        self.assertNotIn('__ADMIN_', html)
        self.assertIn('NapTable 管理台', self.req_text('GET','/admin/'))
        self.assertIn('text/css', self.req_headers('GET','/static/admin.css')['Content-Type'])
        self.assertIn('application/javascript', self.req_headers('GET','/static/admin.js')['Content-Type'])
    def test_public_website_is_served(self):
        self.assertIn('/privacy', self.req_text('GET','/'))
        self.assertIn('隐私政策', self.req_text('GET','/privacy'))
        self.assertIn('text/css', self.req_headers('GET','/site/site.css')['Content-Type'])
        self.assertEqual(self.req_headers('GET','/site/img/week-view.jpg')['Content-Type'], 'image/jpeg')
        # Every asset the pages link to is on the fixed list and present on disk.
        for page in ('/', '/privacy'):
            for path in set(re.findall(r'"(/site/[^"]+)"', self.req_text('GET', page))):
                self.assertTrue(self.req_headers('GET', path)['Content-Type'], path)
        for path in ('/site/../naptable_server.py', '/site/index.html', '/site/img/missing.jpg'):
            with self.assertRaises(HTTPError) as caught: self.req_text('GET', path)
            self.assertEqual(caught.exception.code, 404)
    def test_oversized_request_is_rejected_before_reading_the_body(self):
        connection = http.client.HTTPConnection('127.0.0.1', self.http.server_port, timeout=5)
        connection.request('POST', '/v1/shares', headers={
            'Content-Type': 'application/json',
            'Content-Length': str(MAX_REQUEST_BYTES + 1),
        })
        response = connection.getresponse()
        try:
            self.assertEqual(response.status, 400)
            self.assertIn('request body exceeds', json.loads(response.read())['error'])
        finally:
            connection.close()
    def req_text(self, method, path):
        r=urlopen(Request(self.base+path,method=method));
        with r: return r.read().decode()
    def req_headers(self, method, path):
        r=urlopen(Request(self.base+path,method=method));
        with r: return dict(r.headers)
if __name__=='__main__': unittest.main()


class AdminSessionTests(unittest.TestCase):
    """The console exchanges the admin token for a cookie so a page reload does
    not ask for it again."""

    def setUp(self):
        self.db = tempfile.NamedTemporaryFile(suffix='.sqlite3')
        self.store = Store(self.db.name)
        self.http = LiveServer(self.store)
        self.previous = os.environ.get('NAPTABLE_ADMIN_TOKEN')
        os.environ['NAPTABLE_ADMIN_TOKEN'] = 'admin-test'

    def tearDown(self):
        if self.previous is None: os.environ.pop('NAPTABLE_ADMIN_TOKEN', None)
        else: os.environ['NAPTABLE_ADMIN_TOKEN'] = self.previous
        self.http.shutdown()
        self.store.close(); self.db.close()

    def raw(self, method, path, value=None, headers=None):
        body = None if value is None else json.dumps(value).encode()
        head = {'Content-Type': 'application/json'}; head.update(headers or {})
        connection = http.client.HTTPConnection('127.0.0.1', self.http.server_port, timeout=5)
        try:
            connection.request(method, path, body=body, headers=head)
            response = connection.getresponse()
            payload = response.read()
            return response.status, dict(response.getheaders()), json.loads(payload) if payload else {}
        finally:
            connection.close()

    def sign_in(self, token='admin-test'):
        status, headers, _ = self.raw('POST', '/v1/admin/session', {'token': token})
        return status, headers.get('Set-Cookie', '')

    def test_sign_in_issues_a_scoped_cookie_that_authenticates_later_requests(self):
        status, cookie = self.sign_in()
        self.assertEqual(status, 200)
        self.assertIn('HttpOnly', cookie)
        self.assertIn('SameSite=Strict', cookie)
        self.assertIn('Path=/', cookie)
        session = cookie.split(';')[0]
        self.assertEqual(self.raw('GET', '/v1/admin/session', headers={'Cookie': session})[0], 200)
        self.assertEqual(self.raw('GET', '/v1/admin/calendar', headers={'Cookie': session})[0], 200)
        self.assertEqual(self.raw('POST', '/v1/admin/calendar', {'adjustments': []}, {'Cookie': session})[0], 200)

    def test_a_wrong_token_is_refused_and_sets_no_cookie(self):
        status, cookie = self.sign_in('nope')
        self.assertEqual(status, 403)
        self.assertEqual(cookie, '')
        self.assertEqual(self.raw('GET', '/v1/admin/session')[0], 403)

    def test_the_cookie_is_ignored_on_a_cross_site_request(self):
        session = self.sign_in()[1].split(';')[0]
        for headers in ({'Cookie': session, 'Sec-Fetch-Site': 'cross-site'},
                        {'Cookie': session, 'Origin': 'https://evil.example'}):
            self.assertEqual(self.raw('POST', '/v1/admin/calendar', {'adjustments': []}, headers)[0], 403)

    def test_sign_out_revokes_the_session(self):
        session = self.sign_in()[1].split(';')[0]
        status, headers, _ = self.raw('DELETE', '/v1/admin/session', headers={'Cookie': session})
        self.assertEqual(status, 200)
        self.assertIn('Max-Age=0', headers.get('Set-Cookie', ''))
        self.assertEqual(self.raw('GET', '/v1/admin/session', headers={'Cookie': session})[0], 403)

    def test_rotating_the_admin_token_invalidates_existing_sessions(self):
        session = self.sign_in()[1].split(';')[0]
        os.environ['NAPTABLE_ADMIN_TOKEN'] = 'admin-rotated'
        self.assertEqual(self.raw('GET', '/v1/admin/session', headers={'Cookie': session})[0], 403)

    def test_an_expired_session_is_refused(self):
        session = self.sign_in()[1].split(';')[0]
        expired = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
        with self.store.lock:
            self.store.db.execute('UPDATE admin_sessions SET expires_at=?', (expired,))
            self.store.db.commit()
        self.assertEqual(self.raw('GET', '/v1/admin/session', headers={'Cookie': session})[0], 403)

    def test_the_header_still_works_for_non_browser_clients(self):
        self.assertEqual(self.raw('GET', '/v1/admin/calendar', headers={'X-Admin-Token': 'admin-test'})[0], 200)
        self.assertEqual(self.raw('GET', '/v1/admin/calendar')[0], 403)

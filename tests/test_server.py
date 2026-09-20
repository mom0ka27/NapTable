import http.client, json, os, sqlite3, tempfile, threading, unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from server.naptable_server import Handler, MAX_REQUEST_BYTES, Store

class ServerTests(unittest.TestCase):
    def setUp(self):
        self.db=tempfile.NamedTemporaryFile(suffix='.sqlite3'); Handler.store=Store(self.db.name); Handler.live_activity=None
        self.http=ThreadingHTTPServer(('127.0.0.1',0),Handler); self.thread=threading.Thread(target=self.http.serve_forever); self.thread.start(); self.base=f'http://127.0.0.1:{self.http.server_port}'
    def tearDown(self): self.http.shutdown(); self.http.server_close(); self.thread.join(timeout=2); Handler.store.close(); self.db.close()
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
        self.req('DELETE','/v1/shares/'+code,headers={'X-Write-Token':token})
        with self.assertRaises(Exception): self.req('GET','/v1/shares/'+code)
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
            self.req('POST','/v1/schools/nju',{'name':'南京大学','periods':periods},{'X-Admin-Token':'admin-test'})
            self.req('POST','/v1/admin/schools/nju/terms',value,{'X-Admin-Token':'admin-test'})
            school=self.req('GET','/v1/schools')['schools'][0]
            term=next(item for item in school['terms'] if item['id']=='2027-spring')
            self.assertEqual(term['semesterStartMonday'],'2027-02-22'); self.assertEqual(term['periods'][0]['start'],'07:30'); self.assertEqual(term['version'],1)
            self.assertTrue(term['current']); self.assertEqual(school['currentTermID'],'2027-spring')
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
            with Handler.store.lock:
                Handler.store.db.execute('CREATE TABLE la_devices (device_id TEXT PRIMARY KEY, school_id TEXT, enabled INTEGER)')
                Handler.store.db.executemany('INSERT INTO la_devices VALUES (?,?,?)', [
                    ('a','nju',1), ('b','nju',1), ('c','cpu',1), ('off','nju',0)])
                Handler.store.db.commit()
            stats=self.req('GET','/v1/admin/stats',headers=headers)
            self.assertEqual(stats['totalUsers'],3)
            self.assertEqual(next(item['users'] for item in stats['schools'] if item['id']=='nju'),2)
        finally:
            if old is None: os.environ.pop('NAPTABLE_ADMIN_TOKEN',None)
            else: os.environ['NAPTABLE_ADMIN_TOKEN']=old
    def test_apns_reconcile_creates_both_environments_once_per_school(self):
        class Client:
            def __init__(self): self.environments=[]; self.channels={'production':set(),'sandbox':set()}
            def list_channels(self, environment='production'):
                return sorted(self.channels[environment])
            def create_channel(self, environment='production'):
                self.environments.append(environment)
                channel=f'{environment}-{len(self.environments)}'
                self.channels[environment].add(channel)
                return channel
        Handler.store.save_apns_config({'tickSeconds':5})
        client=Client()
        first=Handler.store.reconcile_apns_channels(client)
        self.assertEqual(len(first['created']),4)
        self.assertEqual(set(first['config']['channels']), {
            'production:nju','sandbox:nju','production:cpu','sandbox:cpu'})
        second=Handler.store.reconcile_apns_channels(client)
        self.assertEqual(second['created'],[]); self.assertEqual(len(client.environments),4)
    def test_apns_bundle_change_discards_channels_from_the_old_app(self):
        Handler.store.save_apns_config({
            'keyPath':'/key.p8','keyID':'K','teamID':'T','bundleID':'old.app',
            'channels':{'production:nju':'old-channel'}})
        saved=Handler.store.save_apns_config({
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
        self.assertEqual(self.req('GET','/'), {'name':'NapTable Server','admin':'/admin'})
        html=self.req_text('GET','/admin')
        self.assertIn('NapTable 管理台', html); self.assertIn('/static/admin.js', html)
        self.assertIn('NapTable 管理台', self.req_text('GET','/admin/'))
        self.assertIn('text/css', self.req_headers('GET','/static/admin.css')['Content-Type'])
        self.assertIn('application/javascript', self.req_headers('GET','/static/admin.js')['Content-Type'])
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

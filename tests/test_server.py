import json, os, tempfile, threading, unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from server.naptable_server import Handler, Store

class ServerTests(unittest.TestCase):
    def setUp(self):
        self.db=tempfile.NamedTemporaryFile(suffix='.sqlite3'); Handler.store=Store(self.db.name)
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
        self.assertEqual(school['id'],'nju'); self.assertTrue(school['terms'][0]['periods'])
    def test_school_write_requires_admin_and_round_trips_personal_values(self):
        value={'id':'2027-spring','semesterStartMonday':'2027-02-22','weekCount':17,'periods':[{'id':1,'name':'第1节','start':'07:30','end':'08:15'}],'timezone':'Asia/Shanghai','note':'校准'}
        with self.assertRaises(Exception): self.req('POST','/v1/admin/schools/nju/terms',value)
        old=os.environ.get('NAPTABLE_ADMIN_TOKEN'); os.environ['NAPTABLE_ADMIN_TOKEN']='admin-test'
        try:
            self.req('POST','/v1/admin/schools/nju/terms',value,{'X-Admin-Token':'admin-test'})
            school=self.req('GET','/v1/schools')['schools'][0]
            term=next(item for item in school['terms'] if item['id']=='2027-spring')
            self.assertEqual(term['semesterStartMonday'],'2027-02-22'); self.assertEqual(term['periods'][0]['start'],'07:30'); self.assertEqual(term['version'],1)
        finally:
            if old is None: os.environ.pop('NAPTABLE_ADMIN_TOKEN',None)
            else: os.environ['NAPTABLE_ADMIN_TOKEN']=old
    def test_invalid_write_token_is_rejected(self):
        created=self.req('POST','/v1/shares',{'schoolID':'nju','termID':'2026-fall-template','courses':[]})
        with self.assertRaises(Exception): self.req('PUT','/v1/shares/'+created['id'],{'courses':[{'name':'x'}]},{'X-Write-Token':'wrong'})
    def test_admin_web_routes_are_served(self):
        html=self.req_text('GET','/')
        self.assertIn('NapTable 管理台', html); self.assertIn('/static/admin.js', html)
        self.assertIn('text/css', self.req_headers('GET','/static/admin.css')['Content-Type'])
        self.assertIn('application/javascript', self.req_headers('GET','/static/admin.js')['Content-Type'])
    def req_text(self, method, path):
        r=urlopen(Request(self.base+path,method=method));
        with r: return r.read().decode()
    def req_headers(self, method, path):
        r=urlopen(Request(self.base+path,method=method));
        with r: return dict(r.headers)
if __name__=='__main__': unittest.main()

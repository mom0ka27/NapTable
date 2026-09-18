#!/usr/bin/env python3
"""Small persistent NapTable sharing/configuration server.

Standard library only. Intended for a LAN or private deployment; put it behind
TLS/authentication at the edge for a public deployment.
"""
from __future__ import annotations
import argparse, hashlib, json, os, secrets, sqlite3, threading, re
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from pathlib import Path

try:  # `python3 server/naptable_server.py` and `import server.naptable_server`
    from . import live_activity
except ImportError:  # pragma: no cover - depends on how the server was started
    import live_activity

STATIC_ROOT = Path(__file__).resolve().parent / "static"

SCHEMA = """
CREATE TABLE IF NOT EXISTS school_configs (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, semester_start TEXT NOT NULL,
 periods_json TEXT NOT NULL, note TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS school_terms (
 school_id TEXT NOT NULL, term_id TEXT NOT NULL, version INTEGER NOT NULL,
 semester_start_monday TEXT NOT NULL, week_count INTEGER NOT NULL,
 periods_json TEXT NOT NULL, timezone TEXT NOT NULL, note TEXT NOT NULL,
 updated_at TEXT NOT NULL, adjustments_json TEXT NOT NULL DEFAULT '[]',
 PRIMARY KEY (school_id, term_id)
);
CREATE TABLE IF NOT EXISTS shares (
 code TEXT PRIMARY KEY, write_token_hash TEXT NOT NULL, owner TEXT NOT NULL,
 school_id TEXT NOT NULL, school_name TEXT NOT NULL, payload_json TEXT NOT NULL,
 semester_start_monday TEXT NOT NULL DEFAULT '', class_time_list_json TEXT NOT NULL DEFAULT '[]',
 term_id TEXT NOT NULL DEFAULT '', term_version INTEGER NOT NULL DEFAULT 0, term_snapshot_json TEXT NOT NULL DEFAULT '{}',
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0
);
"""

def now(): return datetime.now(timezone.utc).isoformat()

# A share is handed back in one response and installed as one table, so the
# payload is bounded here rather than left to whatever a client uploads.
MAX_COURSES = 600
MAX_COURSE_BYTES = 256 * 1024
MAX_OWNER_LENGTH = 40

MAX_ADJUSTMENTS = 200
ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")

def normalize_adjustments(value):
    """Validate a term's 调休 table.

    The client covers the timetable by date: `off` removes a day's classes and
    `swap` makes a day run another day's. A `swap` without a usable source
    would silently delete a day of classes on the client, so it is rejected
    here instead of being stored.
    """
    if value is None: return []
    if not isinstance(value, list): raise ValueError("adjustments must be a list")
    if len(value) > MAX_ADJUSTMENTS: raise ValueError(f"一个学期最多 {MAX_ADJUSTMENTS} 条调休")
    rows = []
    for item in value:
        if not isinstance(item, dict): raise ValueError("each adjustment must be an object")
        date = str(item.get("date", "")).strip()
        kind = str(item.get("kind", "")).strip()
        if not ISO_DATE.fullmatch(date) or not _is_date(date): raise ValueError(f"调休日期无效：{date or '(空)'}")
        if kind not in ("off", "swap"): raise ValueError("调休类型只能是 off 或 swap")
        source = str(item.get("source") or "").strip()
        if kind == "swap":
            if not ISO_DATE.fullmatch(source) or not _is_date(source): raise ValueError(f"{date} 是调课，必须写明上哪一天的课")
        else:
            source = ""
        row = {"date": date, "kind": kind, "note": str(item.get("note") or "")[:80]}
        if source: row["source"] = source
        rows.append(row)
    return rows

def _is_date(value):
    from datetime import date as _date
    try:
        _date.fromisoformat(value); return True
    except ValueError:
        return False

def normalize_courses(value):
    """Validate uploaded rows and return them with their encoded form.

    `CoursePayloadCodec` on the client is deliberately tolerant about field
    shapes, so the server only enforces what makes a share storable and
    readable: a list of objects, each carrying a name, small enough to return
    whole.
    """
    if value is None: value = []
    if not isinstance(value, list): raise ValueError("courses must be a list")
    if len(value) > MAX_COURSES: raise ValueError(f"一张课表最多 {MAX_COURSES} 门课程")
    for course in value:
        if not isinstance(course, dict): raise ValueError("each course must be an object")
        name = course.get("name")
        if not isinstance(name, str) or not name.strip(): raise ValueError("每门课程都需要名称")
    encoded = json.dumps(value, ensure_ascii=False)
    if len(encoded.encode()) > MAX_COURSE_BYTES: raise ValueError("课表内容过大，无法分享")
    return value, encoded

class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        with self.lock:
            self.db.executescript(SCHEMA)
            terms = {row[1] for row in self.db.execute("PRAGMA table_info(school_terms)")}
            if "adjustments_json" not in terms: self.db.execute("ALTER TABLE school_terms ADD COLUMN adjustments_json TEXT NOT NULL DEFAULT '[]'")
            shares = {row[1] for row in self.db.execute("PRAGMA table_info(shares)")}
            if "adjustments_json" not in shares: self.db.execute("ALTER TABLE shares ADD COLUMN adjustments_json TEXT NOT NULL DEFAULT '[]'")
            columns = {row[1] for row in self.db.execute("PRAGMA table_info(shares)")}
            if "semester_start_monday" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN semester_start_monday TEXT NOT NULL DEFAULT ''")
            if "class_time_list_json" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN class_time_list_json TEXT NOT NULL DEFAULT '[]'")
            if "term_id" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN term_id TEXT NOT NULL DEFAULT ''")
            if "term_version" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN term_version INTEGER NOT NULL DEFAULT 0")
            if "term_snapshot_json" not in columns: self.db.execute("ALTER TABLE shares ADD COLUMN term_snapshot_json TEXT NOT NULL DEFAULT '{}'")
            self.db.commit(); self.seed()
    def close(self):
        with self.lock: self.db.close()
    def seed(self):
        # These are editable teaching templates, not a claim about current NJU data.
        periods = [{"id": i, "name": f"第{i}节", "start": s, "end": e} for i,(s,e) in enumerate([
            ("08:00","08:50"),("09:00","09:50"),("10:10","11:00"),("11:10","12:00"),
            ("14:00","14:50"),("15:00","15:50"),("16:10","17:00"),("17:10","18:00"),
            ("18:30","19:20"),("19:30","20:20"),("20:30","21:20"),("21:30","22:20"),("22:30","23:59")], 1)]
        row = self.db.execute("SELECT 1 FROM school_configs WHERE id='nju'").fetchone()
        if not row:
            self.db.execute("INSERT INTO school_configs VALUES (?,?,?,?,?,?)", ("nju","南京大学","",json.dumps(periods,ensure_ascii=False),"模板时间，需按校历校准",now()))
            self.db.commit()
        term = self.db.execute("SELECT 1 FROM school_terms WHERE school_id='nju' AND term_id='2026-fall-template'").fetchone()
        if not term:
            row = self.db.execute("SELECT periods_json FROM school_configs WHERE id='nju'").fetchone()
            self.db.execute("INSERT INTO school_terms (school_id,term_id,version,semester_start_monday,week_count,periods_json,timezone,note,updated_at,adjustments_json) VALUES (?,?,?,?,?,?,?,?,?,'[]')", ("nju", "2026-fall-template", 1, "2026-09-14", 18, row[0], "Asia/Shanghai", "模板，未按官方校历校准", now()))
            self.db.commit()
    def schools(self):
        with self.lock:
            rows=self.db.execute("SELECT * FROM school_configs ORDER BY id").fetchall()
            return [self.school(r) for r in rows]
    def school(self, r):
        terms = self.db.execute("SELECT * FROM school_terms WHERE school_id=? ORDER BY term_id", (r["id"],)).fetchall()
        return {"id":r["id"],"name":r["name"],"timezone":"Asia/Shanghai","terms":[self.term(t) for t in terms],"note":r["note"],"updatedAt":r["updated_at"]}
    def term(self, r):
        return {"id":r["term_id"],"version":r["version"],"semesterStartMonday":r["semester_start_monday"],"weekCount":r["week_count"],"periods":json.loads(r["periods_json"]),"adjustments":json.loads(r["adjustments_json"] or "[]"),"timezone":r["timezone"],"note":r["note"],"updatedAt":r["updated_at"]}
    def find_term(self, school_id, term_id):
        with self.lock:
            r=self.db.execute("SELECT * FROM school_terms WHERE school_id=? AND term_id=?",(school_id,term_id)).fetchone()
        return self.term(r) if r else None
    def save_school(self, value):
        required = value.get("id"), value.get("name")
        if not all(required): raise ValueError("id/name/periods are required")
        stamp=now()
        with self.lock:
            self.db.execute("INSERT INTO school_configs VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,semester_start=excluded.semester_start,periods_json=excluded.periods_json,note=excluded.note,updated_at=excluded.updated_at", (value["id"],value["name"],value.get("semesterStart", ""),json.dumps(value["periods"],ensure_ascii=False),value.get("note", ""),stamp)); self.db.commit()
        value["updatedAt"] = stamp; return value
    def school_name(self, school_id):
        """The catalogue name, never the client's copy of it: a reader should
        see 南京大学 even when the sharer's app had not loaded the catalogue."""
        with self.lock:
            r=self.db.execute("SELECT name FROM school_configs WHERE id=?",(school_id,)).fetchone()
        return r["name"] if r else school_id
    def create(self, value):
        term = self.find_term(value.get("schoolID", ""), value.get("termID", ""))
        if not term: raise ValueError("unknown schoolID/termID")
        _, payload = normalize_courses(value.get("courses"))
        owner = str(value.get("owner") or "匿名").strip()[:MAX_OWNER_LENGTH] or "匿名"
        code=secrets.token_urlsafe(6).replace("-", "").replace("_", "").upper()[:8]
        token=secrets.token_urlsafe(24); stamp=now()
        with self.lock:
            self.db.execute("INSERT INTO shares (code,write_token_hash,owner,school_id,school_name,payload_json,semester_start_monday,class_time_list_json,adjustments_json,term_id,term_version,term_snapshot_json,created_at,updated_at,revoked) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)", (code,hashlib.sha256(token.encode()).hexdigest(),owner,value["schoolID"],self.school_name(value["schoolID"]),payload,term["semesterStartMonday"],json.dumps(term["periods"],ensure_ascii=False),json.dumps(term.get("adjustments",[]),ensure_ascii=False),term["id"],term["version"],json.dumps(term,ensure_ascii=False),stamp,stamp)); self.db.commit()
        return self.get(code, include_token=True, token=token)
    def get(self, code, include_token=False, token=None):
        with self.lock: r=self.db.execute("SELECT * FROM shares WHERE code=? AND revoked=0",(code.upper(),)).fetchone()
        if not r: return None
        snapshot=json.loads(r["term_snapshot_json"] or "{}")
        courses=json.loads(r["payload_json"])
        # `name` becomes the reader's table name, so it says whose timetable
        # this is rather than repeating the school for every share.
        out={"id":r["code"],"owner":r["owner"],"schoolID":r["school_id"],"schoolName":r["school_name"],"name":f"{r['owner']} · {r['school_name']}","termID":r["term_id"],"termVersion":r["term_version"],"term_version":r["term_version"],"term_week_count":snapshot.get("weekCount",0),"term_timezone":snapshot.get("timezone","Asia/Shanghai"),"courses":courses,"courseCount":len(courses),"semester_start_monday":r["semester_start_monday"],"class_time_list":json.loads(r["class_time_list_json"]),"calendar_adjustments":json.loads(r["adjustments_json"] or "[]"),"createdAt":r["created_at"],"updatedAt":r["updated_at"]}
        if include_token: out["writeToken"]=token
        return out
    def meta(self, code):
        """Everything a follower needs to decide whether to download again."""
        with self.lock: r=self.db.execute("SELECT * FROM shares WHERE code=? AND revoked=0",(code.upper(),)).fetchone()
        if not r: return None
        snapshot=json.loads(r["term_snapshot_json"] or "{}")
        return {"id":r["code"],"owner":r["owner"],"schoolID":r["school_id"],"schoolName":r["school_name"],"name":f"{r['owner']} · {r['school_name']}","termID":r["term_id"],"termVersion":r["term_version"],"courseCount":len(json.loads(r["payload_json"])),"semester_start_monday":r["semester_start_monday"],"term_week_count":snapshot.get("weekCount",0),"adjustmentCount":len(json.loads(r["adjustments_json"] or "[]")),"updatedAt":r["updated_at"]}
    def authorize(self, code, token):
        """The share row when `token` is its write token, otherwise None.

        Kept apart from the callers so a bad request body can no longer be
        reported as a bad token.
        """
        with self.lock: r=self.db.execute("SELECT * FROM shares WHERE code=? AND revoked=0",(code.upper(),)).fetchone()
        if not r or not token: return None
        return r if secrets.compare_digest(r["write_token_hash"], hashlib.sha256(token.encode()).hexdigest()) else None
    def _freeze(self, code, term, payload=None):
        """Point a share at one term's configuration and copy that term's
        periods into the share. A reader installs those times as-is, which is
        what lets a timetable from another school keep its own bell schedule."""
        stamp=now()
        fields=[term["semesterStartMonday"],json.dumps(term["periods"],ensure_ascii=False),json.dumps(term.get("adjustments",[]),ensure_ascii=False),term["id"],term["version"],json.dumps(term,ensure_ascii=False),stamp]
        with self.lock:
            if payload is None:
                self.db.execute("UPDATE shares SET semester_start_monday=?,class_time_list_json=?,adjustments_json=?,term_id=?,term_version=?,term_snapshot_json=?,updated_at=? WHERE code=?",(*fields,code.upper()))
            else:
                self.db.execute("UPDATE shares SET payload_json=?,school_id=?,school_name=?,semester_start_monday=?,class_time_list_json=?,adjustments_json=?,term_id=?,term_version=?,term_snapshot_json=?,updated_at=? WHERE code=?",(payload["courses"],payload["schoolID"],self.school_name(payload["schoolID"]),*fields,code.upper()))
            self.db.commit()
        return self.get(code)
    def update(self, code, token, value):
        row = self.authorize(code, token)
        if not row: return None
        # Omitting the school or the term means "keep this share where it is",
        # so a plain course edit does not have to restate them.
        school_id = str(value.get("schoolID") or row["school_id"])
        term_id = str(value.get("termID") or row["term_id"])
        term = self.find_term(school_id, term_id)
        if not term: raise ValueError("unknown schoolID/termID")
        _, payload = normalize_courses(value.get("courses"))
        return self._freeze(code, term, {"courses": payload, "schoolID": school_id})
    def resync(self, code, token):
        """Re-freeze the share against its school's current term configuration.

        A share keeps the times it was published with, so an admin correcting
        a bell schedule cannot silently move everybody's classes. This is the
        owner's way to opt into the correction.
        """
        row = self.authorize(code, token)
        if not row: return None
        term = self.find_term(row["school_id"], row["term_id"])
        if not term: raise ValueError("该分享的学校或学期已不在服务端配置中")
        return self._freeze(code, term)
    def revoke(self, code, token):
        if not self.authorize(code, token): return False
        with self.lock: self.db.execute("UPDATE shares SET revoked=1 WHERE code=?",(code.upper(),)); self.db.commit()
        return True

class Handler(BaseHTTPRequestHandler):
    store=None
    live_activity=None
    def log_message(self, fmt, *args): return
    def send_json(self, status, value):
        data=json.dumps(value,ensure_ascii=False).encode(); self.send_response(status); self.send_header("Content-Type","application/json; charset=utf-8"); self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)
    def send_file(self, path, content_type):
        try: data = path.read_bytes()
        except OSError: return self.send_json(404, {"error": "not found"})
        self.send_response(200); self.send_header("Content-Type", content_type); self.send_header("Content-Length", str(len(data))); self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(data)
    def body(self):
        n=int(self.headers.get("Content-Length",0)); return json.loads(self.rfile.read(n) or b"{}")
    def do_GET(self):
        path=urlparse(self.path).path
        if live_activity.handle(self, self.live_activity, "GET", path): return
        if path == "/": return self.send_file(STATIC_ROOT / "admin.html", "text/html; charset=utf-8")
        if path == "/static/admin.css": return self.send_file(STATIC_ROOT / "admin.css", "text/css; charset=utf-8")
        if path == "/static/admin.js": return self.send_file(STATIC_ROOT / "admin.js", "application/javascript; charset=utf-8")
        if path == "/health": return self.send_json(200,{"ok":True})
        if path == "/v1/schools": return self.send_json(200,{"schools":self.store.schools()})
        if path.startswith("/v1/shares/"):
            parts=[p for p in path[len("/v1/shares/"):].split("/") if p]
            if len(parts)==1: value=self.store.get(parts[0])
            elif parts[1:]==["meta"]: value=self.store.meta(parts[0])
            else: return self.send_json(404,{"error":"not found"})
            return self.send_json(200,value) if value else self.send_json(404,{"error":"share not found"})
        self.send_json(404,{"error":"not found"})
    def do_POST(self):
        path=urlparse(self.path).path
        if live_activity.handle(self, self.live_activity, "POST", path): return
        try:
            if path == "/v1/shares": return self.send_json(201,self.store.create(self.body()))
            if path.startswith("/v1/shares/") and path.endswith("/resync"):
                code=path[len("/v1/shares/"):-len("/resync")]
                value=self.store.resync(code,self.headers.get("X-Write-Token",""))
                return self.send_json(200,value) if value else self.send_json(403,{"error":"invalid write token"})
            if path.startswith("/v1/schools/"):
                admin = os.environ.get("NAPTABLE_ADMIN_TOKEN", "").strip()
                if not admin or not secrets.compare_digest(self.headers.get("X-Admin-Token", ""), admin):
                    return self.send_json(403,{"error":"school template is read-only without admin token"})
                value=self.body(); value["id"]=path.rsplit("/",1)[-1]; return self.send_json(200,self.store.save_school(value))
            if path.startswith("/v1/admin/schools/") and path.endswith("/terms"):
                admin = os.environ.get("NAPTABLE_ADMIN_TOKEN", "").strip()
                if not admin or not secrets.compare_digest(self.headers.get("X-Admin-Token", ""), admin): return self.send_json(403,{"error":"admin token required"})
                school_id = path.split("/")[4]; value=self.body(); required=[value.get("id"),value.get("semesterStartMonday"),value.get("weekCount"),value.get("periods"),value.get("timezone")]
                if not all(required): return self.send_json(400,{"error":"term id, semesterStartMonday, weekCount, periods and timezone are required"})
                if type(value["weekCount"]) is not int or not 1 <= value["weekCount"] <= 40:
                    return self.send_json(400, {"error": "weekCount must be an integer between 1 and 40"})
                if not self.store.db.execute("SELECT 1 FROM school_configs WHERE id=?", (school_id,)).fetchone():
                    return self.send_json(400, {"error": "unknown schoolID"})
                if not isinstance(value["periods"], list):
                    return self.send_json(400, {"error": "periods must be a list"})
                for index, period in enumerate(value["periods"], 1):
                    if not isinstance(period, dict) or period.get("id") != index or not isinstance(period.get("name"), str):
                        return self.send_json(400, {"error": "periods require sequential IDs starting at 1 and a name"})
                if value["timezone"] != "Asia/Shanghai" or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value["semesterStartMonday"]): return self.send_json(400,{"error":"only Asia/Shanghai and ISO date are supported"})
                from datetime import date
                try:
                    parsed=date.fromisoformat(value["semesterStartMonday"])
                    if parsed.isoweekday() != 1: return self.send_json(400,{"error":"semesterStartMonday must be Monday"})
                except ValueError: return self.send_json(400,{"error":"invalid semesterStartMonday"})
                last=self.store.db.execute("SELECT version FROM school_terms WHERE school_id=? AND term_id=?",(school_id,value["id"])).fetchone()
                stamp=now(); value["version"]=(int(last[0])+1) if last else 1; value["updatedAt"]=stamp
                previous=-1
                for period in value["periods"]:
                    if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", period.get("start", "")) or not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", period.get("end", "")): return self.send_json(400,{"error":"invalid period time"})
                    start=int(period["start"][:2])*60+int(period["start"][3:]); end=int(period["end"][:2])*60+int(period["end"][3:])
                    if start >= end or start < previous: return self.send_json(400,{"error":"periods must be ordered and non-overlapping"})
                    previous=end
                value["adjustments"] = normalize_adjustments(value.get("adjustments"))
                with self.store.lock:
                    self.store.db.execute("INSERT INTO school_terms (school_id,term_id,version,semester_start_monday,week_count,periods_json,timezone,note,updated_at,adjustments_json) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(school_id,term_id) DO UPDATE SET version=excluded.version,semester_start_monday=excluded.semester_start_monday,week_count=excluded.week_count,periods_json=excluded.periods_json,timezone=excluded.timezone,note=excluded.note,updated_at=excluded.updated_at,adjustments_json=excluded.adjustments_json",(school_id,value["id"],value["version"],value["semesterStartMonday"],int(value["weekCount"]),json.dumps(value["periods"],ensure_ascii=False),value["timezone"],value.get("note",""),stamp,json.dumps(value["adjustments"],ensure_ascii=False))); self.store.db.commit()
                return self.send_json(200,value)
            self.send_json(404,{"error":"not found"})
        except (ValueError, KeyError, json.JSONDecodeError) as e: self.send_json(400,{"error":str(e)})
    def do_PUT(self):
        path=urlparse(self.path).path
        if live_activity.handle(self, self.live_activity, "PUT", path): return
        token=self.headers.get("X-Write-Token","")
        if path.startswith("/v1/shares/"):
            try: value=self.store.update(path.rsplit("/",1)[-1],token,self.body())
            except (ValueError, KeyError, json.JSONDecodeError) as e: return self.send_json(400,{"error":str(e)})
            return self.send_json(200,value) if value else self.send_json(403,{"error":"invalid write token"})
        self.send_json(404,{"error":"not found"})
    def do_DELETE(self):
        path=urlparse(self.path).path
        if live_activity.handle(self, self.live_activity, "DELETE", path): return
        token=self.headers.get("X-Write-Token","")
        if path.startswith("/v1/shares/"): return self.send_json(200,{"revoked":True}) if self.store.revoke(path.rsplit("/",1)[-1],token) else self.send_json(403,{"error":"invalid write token"})
        self.send_json(404,{"error":"not found"})

def main():
    p=argparse.ArgumentParser(); p.add_argument("--host",default="127.0.0.1"); p.add_argument("--port",type=int,default=8787); p.add_argument("--db",default="naptable.sqlite3"); a=p.parse_args()
    Handler.store=Store(a.db)
    Handler.live_activity=live_activity.build_service(Handler.store.db, Handler.store.lock)
    Handler.live_activity.start()
    server=ThreadingHTTPServer((a.host,a.port),Handler)
    configured = "已配置" if Handler.live_activity.client else "未配置（只接受注册与计划，不发推送）"
    print(f"NapTable server listening on http://{a.host}:{a.port}")
    print(f"实况通知推送：APNs {configured}")
    try: server.serve_forever()
    finally: Handler.live_activity.stop()
if __name__ == "__main__": main()

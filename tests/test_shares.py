"""Checks for the shared-timetable API.

The point of a share is that a reader installs the *sharer's* school schedule:
their first Monday, their week count and their bell times, not whatever the
reader's own table happens to use. These tests pin that end of it as much as
the CRUD.
"""
import json, os, tempfile, threading, unittest

from server.naptable_server import (Handler, MAX_ADJUSTMENTS, MAX_COURSES, Store,
                                    normalize_adjustments, normalize_courses)
from tests.server_support import FastServer, JSONClientMixin

ADMIN = "admin-shares-test"
# A second school whose day starts earlier and runs shorter periods, so a
# reader cannot accidentally pass by reusing NJU's times.
SEU_TERM = {
    "id": "2026-fall",
    "semesterStartMonday": "2026-09-07",
    "weekCount": 20,
    "timezone": "Asia/Shanghai",
    "note": "测试用",
    "periods": [
        {"id": 1, "name": "第1节", "start": "07:50", "end": "08:35"},
        {"id": 2, "name": "第2节", "start": "08:45", "end": "09:30"},
        {"id": 3, "name": "第3节", "start": "09:50", "end": "10:35"},
    ],
}


class CourseValidationTests(unittest.TestCase):
    def test_accepts_an_empty_timetable(self):
        rows, encoded = normalize_courses(None)
        self.assertEqual((rows, encoded), ([], "[]"))

    def test_rejects_what_cannot_be_installed(self):
        for value in ("not a list", [["nested"]], [{"name": "  "}], [{"name": 3}], [{}],
                      [{"name": "课"}] * (MAX_COURSES + 1)):
            with self.subTest(value=str(value)[:40]), self.assertRaises(ValueError):
                normalize_courses(value)

    def test_rejects_an_oversized_timetable(self):
        with self.assertRaises(ValueError):
            normalize_courses([{"name": "课", "info": "x" * 1000} for _ in range(400)])

    def test_keeps_unknown_fields_verbatim(self):
        rows, _ = normalize_courses([{"name": "数学", "week_time": 3, "custom": {"a": 1}}])
        self.assertEqual(rows[0]["custom"], {"a": 1})


class AdjustmentValidationTests(unittest.TestCase):
    def test_keeps_a_holiday_and_a_swap(self):
        rows = normalize_adjustments([
            {"date": "2026-10-01", "kind": "off", "note": "国庆节"},
            {"date": "2026-10-11", "kind": "swap", "source": "2026-10-09", "note": ""},
        ])
        self.assertEqual(rows[0], {"date": "2026-10-01", "kind": "off", "note": "国庆节"})
        self.assertEqual(rows[1]["source"], "2026-10-09")

    def test_drops_the_source_a_holiday_cannot_use(self):
        rows = normalize_adjustments([{"date": "2026-10-01", "kind": "off", "source": "2026-10-09"}])
        self.assertNotIn("source", rows[0])

    def test_rejects_what_would_silently_delete_a_day(self):
        for value in ([{"date": "2026-10-11", "kind": "swap"}],
                      [{"date": "2026-10-11", "kind": "swap", "source": "nope"}],
                      [{"date": "2026-13-01", "kind": "off"}],
                      [{"date": "2026-02-30", "kind": "off"}],
                      [{"date": "", "kind": "off"}],
                      [{"date": "2026-10-01", "kind": "holiday"}],
                      "not a list",
                      [{"date": "2026-10-01", "kind": "off"}] * (MAX_ADJUSTMENTS + 1)):
            with self.subTest(value=str(value)[:40]), self.assertRaises(ValueError):
                normalize_adjustments(value)

    def test_no_adjustments_is_an_empty_table(self):
        self.assertEqual(normalize_adjustments(None), [])


class ShareTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.file = tempfile.NamedTemporaryFile(suffix=".sqlite3")
        Handler.store = Store(self.file.name)
        Handler.live_activity = None
        self.http = FastServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.http.serve_forever)
        self.thread.start()
        self.previous = os.environ.get("NAPTABLE_ADMIN_TOKEN")
        os.environ["NAPTABLE_ADMIN_TOKEN"] = ADMIN
        self.req("POST", "/v1/schools/seu", {"name": "东南大学", "periods": SEU_TERM["periods"]},
                 {"X-Admin-Token": ADMIN})
        self.req("POST", "/v1/admin/schools/seu/terms", SEU_TERM, {"X-Admin-Token": ADMIN})

    def tearDown(self):
        if self.previous is None:
            os.environ.pop("NAPTABLE_ADMIN_TOKEN", None)
        else:
            os.environ["NAPTABLE_ADMIN_TOKEN"] = self.previous
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=2)
        Handler.store.close()
        self.file.close()

    def create(self, school="nju", term="2026-fall-template", courses=None, owner="张三"):
        return self.req("POST", "/v1/shares", {
            "owner": owner, "schoolID": school, "termID": term,
            "courses": courses if courses is not None else [{"name": "高等数学", "week_time": 1, "start_time": 1, "time_count": 2}],
        }, expect=201)

    def replace(self, previous, courses, expect=201, **extra):
        return self.req("POST", f"/v1/shares/{previous['id']}/replace", {
            "owner": "张三", "schoolID": "nju", "termID": "2026-fall-template",
            "courses": courses, **extra,
        }, {"X-Write-Token": previous["writeToken"]}, expect=expect)

    def test_replacement_revokes_old_code_and_meta(self):
        old = self.create()
        unrelated = self.create(owner="另一个人")
        new = self.replace(old, [{"name": "物理"}])
        self.assertNotEqual(new["id"], old["id"])
        self.req("GET", f"/v1/shares/{old['id']}", expect=404)
        self.req("GET", f"/v1/shares/{old['id']}/meta", expect=404)
        self.req("GET", f"/v1/shares/{new['id']}")
        self.req("GET", f"/v1/shares/{unrelated['id']}")
        self.replace(old, [{"name": "化学"}], expect=403)

    def test_unchanged_content_cannot_rotate_even_with_new_ids_and_order(self):
        rows = [{"name": "数学", "id": 1, "tableId": 2, "courseKey": 8, "weeks": [1, 2]},
                {"name": "物理", "id": 2}]
        old = self.create(courses=rows)
        changed_ids = [{"name": "物理", "id": 100},
                       {"name": "数学", "id": 90, "tableId": 5, "courseKey": 12, "weeks": [2, 1]}]
        result = self.replace(old, changed_ids, expect=400)
        self.assertIn("没有变更", result["error"])
        self.req("GET", f"/v1/shares/{old['id']}")
        self.assertEqual(Handler.store.db.execute("SELECT COUNT(*) FROM shares").fetchone()[0], 1)

    def test_failed_replacement_preserves_old_share(self):
        old = self.create()
        self.replace(old, [{"name": ""}], expect=400)
        self.req("POST", f"/v1/shares/{old['id']}/replace", {
            "schoolID": "nju", "termID": "2026-fall-template", "courses": [{"name": "物理"}],
        }, {"X-Write-Token": "wrong"}, expect=403)
        self.replace(old, [{"name": "物理"}], expect=403,
                     previousShares=[{"code": old["id"], "token": "wrong"}])
        self.req("GET", f"/v1/shares/{old['id']}")
        self.assertEqual(Handler.store.db.execute("SELECT COUNT(*) FROM shares").fetchone()[0], 1)

    def test_replacement_revokes_all_authenticated_legacy_codes(self):
        first, latest = self.create(), self.create()
        new = self.replace(latest, [{"name": "物理"}],
                           previousShares=[{"code": first["id"], "token": first["writeToken"]}])
        for old in (first, latest): self.req("GET", f"/v1/shares/{old['id']}", expect=404)
        self.req("GET", f"/v1/shares/{new['id']}")

    def test_calendar_change_alone_allows_replacement(self):
        old = self.create()
        with Handler.store.lock:
            Handler.store.db.execute("UPDATE school_terms SET week_count=week_count+1 WHERE school_id='nju'")
            Handler.store.db.commit()
        new = self.replace(old, old["courses"])
        self.assertEqual(new["scheduleScope"], old["scheduleScope"])
        self.assertNotEqual(new["id"], old["id"])
        self.req("GET", f"/v1/shares/{old['id']}", expect=404)

    # -- the point of the feature -----------------------------------------

    def test_a_share_carries_its_own_school_schedule(self):
        nju = self.req("GET", "/v1/shares/" + self.create()["id"])
        seu = self.req("GET", "/v1/shares/" + self.create(school="seu", term="2026-fall", owner="李四")["id"])
        self.assertEqual(nju["semester_start_monday"], "2026-09-14")
        self.assertEqual(seu["semester_start_monday"], "2026-09-07")
        self.assertEqual(nju["class_time_list"][0]["start"], "08:00")
        self.assertEqual(seu["class_time_list"][0]["start"], "07:50")
        self.assertEqual(nju["term_week_count"], 18)
        self.assertEqual(seu["term_week_count"], 20)
        self.assertEqual(len(seu["class_time_list"]), 3)
        self.assertEqual(seu["term_timezone"], "Asia/Shanghai")
        self.assertTrue(seu["configurationFrozen"])

    def test_the_reader_sees_the_catalogue_school_name(self):
        # The sharer's app may never have loaded the catalogue and can send the
        # bare id; the reader should still see the real name.
        created = self.req("POST", "/v1/shares", {
            "owner": "张三", "schoolID": "nju", "termID": "2026-fall-template",
            "schoolName": "nju", "courses": [{"name": "高数"}]}, expect=201)
        self.assertEqual(created["schoolName"], "南京大学")
        self.assertEqual(created["name"], "张三 · 南京大学")

    def test_an_anonymous_owner_still_gets_a_name(self):
        created = self.create(owner="   ")
        self.assertEqual(created["owner"], "匿名")

    def test_a_share_carries_the_global_holiday_table(self):
        adjustments = [
            {"date": "2026-10-01", "kind": "off", "note": "国庆节"},
            {"date": "2026-10-11", "kind": "swap", "source": "2026-10-09"},
        ]
        self.req("POST", "/v1/admin/calendar", {"adjustments": adjustments}, {"X-Admin-Token": ADMIN})
        term = next(t for s in self.req("GET", "/v1/schools")["schools"] if s["id"] == "seu"
                    for t in s["terms"] if t["id"] == "2026-fall")
        self.assertEqual(len(term["adjustments"]), 2)

        seu = self.req("GET", "/v1/shares/" + self.create(school="seu", term="2026-fall")["id"])
        nju = self.req("GET", "/v1/shares/" + self.create()["id"])
        self.assertEqual([a["date"] for a in seu["calendar_adjustments"]], ["2026-10-01", "2026-10-11"])
        self.assertEqual(seu["calendar_adjustments"][1]["source"], "2026-10-09")
        self.assertEqual(nju["calendar_adjustments"], seu["calendar_adjustments"],
                         "统一调休必须对所有学校生效")
        self.assertEqual(self.req("GET", f"/v1/shares/{seu['id']}/meta")["adjustmentCount"], 2)

    def test_an_invalid_adjustment_table_is_refused(self):
        broken = {"adjustments": [{"date": "2026-10-11", "kind": "swap"}]}
        body = self.req("POST", "/v1/admin/calendar", broken, {"X-Admin-Token": ADMIN}, expect=400)
        self.assertIn("调课", body["error"])

    def test_resync_picks_up_a_newly_published_holiday_table(self):
        created = self.create(school="seu", term="2026-fall")
        self.assertEqual(self.req("GET", "/v1/shares/" + created["id"])["calendar_adjustments"], [])
        self.req("POST", "/v1/admin/calendar",
                 {"adjustments": [{"date": "2026-10-01", "kind": "off", "note": "国庆节"}]},
                 {"X-Admin-Token": ADMIN})
        self.assertEqual(self.req("GET", "/v1/shares/" + created["id"])["calendar_adjustments"], [])
        resynced = self.req("POST", f"/v1/shares/{created['id']}/resync", None,
                            {"X-Write-Token": created["writeToken"]})
        self.assertEqual(resynced["calendar_adjustments"][0]["note"], "国庆节")

    # -- lifecycle ---------------------------------------------------------

    def test_create_read_update_revoke(self):
        created = self.create()
        code, token = created["id"], created["writeToken"]
        self.assertEqual(created["courseCount"], 1)
        self.req("PUT", "/v1/shares/" + code, {"courses": [{"name": "物理"}, {"name": "化学"}]},
                 {"X-Write-Token": token})
        fetched = self.req("GET", "/v1/shares/" + code)
        self.assertEqual([c["name"] for c in fetched["courses"]], ["物理", "化学"])
        self.assertEqual(fetched["courseCount"], 2)
        self.req("DELETE", "/v1/shares/" + code, headers={"X-Write-Token": token})
        self.req("GET", "/v1/shares/" + code, expect=404)
        self.req("GET", f"/v1/shares/{code}/meta", expect=404)

    def test_an_update_keeps_the_share_on_its_term_by_default(self):
        created = self.create(school="seu", term="2026-fall")
        self.req("PUT", "/v1/shares/" + created["id"], {"courses": [{"name": "物理"}]},
                 {"X-Write-Token": created["writeToken"]})
        fetched = self.req("GET", "/v1/shares/" + created["id"])
        self.assertEqual(fetched["termID"], "2026-fall")
        self.assertEqual(fetched["schoolID"], "seu")
        self.assertEqual(fetched["class_time_list"][0]["start"], "07:50")

    def test_an_update_can_move_the_share_to_another_school(self):
        created = self.create()
        self.req("PUT", "/v1/shares/" + created["id"],
                 {"schoolID": "seu", "termID": "2026-fall", "courses": [{"name": "物理"}]},
                 {"X-Write-Token": created["writeToken"]})
        fetched = self.req("GET", "/v1/shares/" + created["id"])
        self.assertEqual(fetched["schoolName"], "东南大学")
        self.assertEqual(fetched["semester_start_monday"], "2026-09-07")
        self.assertEqual(fetched["class_time_list"][0]["start"], "07:50")

    def test_a_rejected_body_is_not_reported_as_a_bad_token(self):
        created = self.create()
        auth = {"X-Write-Token": created["writeToken"]}
        self.req("PUT", "/v1/shares/" + created["id"], {"termID": "nope", "courses": []}, auth, expect=400)
        body = self.req("PUT", "/v1/shares/" + created["id"], {"courses": [{"name": ""}]}, auth, expect=400)
        self.assertIn("名称", body["error"])
        self.req("PUT", "/v1/shares/" + created["id"], {"courses": []}, {"X-Write-Token": "wrong"}, expect=403)

    def test_writes_need_the_write_token(self):
        code = self.create()["id"]
        self.req("PUT", "/v1/shares/" + code, {"courses": []}, {"X-Write-Token": ""}, expect=403)
        self.req("POST", f"/v1/shares/{code}/resync", None, {"X-Write-Token": "wrong"}, expect=403)
        self.req("DELETE", "/v1/shares/" + code, headers={"X-Write-Token": ""}, expect=403)
        self.req("GET", "/v1/shares/" + code)  # reading still needs nothing

    # -- meta --------------------------------------------------------------

    def test_meta_describes_the_share_without_the_courses(self):
        created = self.create(courses=[{"name": "高数"}, {"name": "线代"}])
        meta = self.req("GET", f"/v1/shares/{created['id']}/meta")
        self.assertNotIn("courses", meta)
        self.assertEqual(meta["courseCount"], 2)
        self.assertEqual(meta["updatedAt"], created["updatedAt"])
        self.assertEqual(meta["name"], "张三 · 南京大学")
        self.assertEqual(meta["term_week_count"], 18)

    def test_meta_changes_when_the_share_does(self):
        created = self.create()
        before = self.req("GET", f"/v1/shares/{created['id']}/meta")
        self.req("PUT", "/v1/shares/" + created["id"], {"courses": [{"name": "物理"}]},
                 {"X-Write-Token": created["writeToken"]})
        after = self.req("GET", f"/v1/shares/{created['id']}/meta")
        self.assertNotEqual(before["updatedAt"], after["updatedAt"])

    def test_unknown_share_paths(self):
        self.req("GET", "/v1/shares/NOPE", expect=404)
        self.req("GET", "/v1/shares/NOPE/meta", expect=404)
        self.req("GET", "/v1/shares/NOPE/whatever", expect=404)

    # -- resync ------------------------------------------------------------

    def test_a_corrected_bell_schedule_reaches_a_share_only_on_resync(self):
        created = self.create(school="seu", term="2026-fall")
        corrected = [dict(p, start="08:00", end="08:40") if p["id"] == 1 else p
                     for p in SEU_TERM["periods"]]
        self.req("POST", "/v1/schools/seu", {"name": "东南大学", "periods": corrected},
                 {"X-Admin-Token": ADMIN})

        frozen = self.req("GET", "/v1/shares/" + created["id"])
        self.assertEqual(frozen["class_time_list"][0]["start"], "07:50",
                         "An admin edit must not silently move a published share")
        self.assertEqual(frozen["termVersion"], 1)

        resynced = self.req("POST", f"/v1/shares/{created['id']}/resync", None,
                            {"X-Write-Token": created["writeToken"]})
        self.assertEqual(resynced["class_time_list"][0]["start"], "08:00")
        self.assertEqual(resynced["termVersion"], 2)
        self.assertEqual([c["name"] for c in resynced["courses"]], ["高等数学"],
                         "A resync changes the times, not the timetable")

    def test_resync_reports_a_term_that_no_longer_exists(self):
        created = self.create()
        with Handler.store.lock:
            Handler.store.db.execute("UPDATE shares SET term_id='gone' WHERE code=?", (created["id"],))
            Handler.store.db.commit()
        body = self.req("POST", f"/v1/shares/{created['id']}/resync", None,
                        {"X-Write-Token": created["writeToken"]}, expect=400)
        self.assertIn("学期", body["error"])

    # -- limits ------------------------------------------------------------

    def test_the_server_refuses_an_unbounded_timetable(self):
        self.req("POST", "/v1/shares", {"owner": "张三", "schoolID": "nju", "termID": "2026-fall-template",
                                        "courses": [{"name": "课"}] * (MAX_COURSES + 1)}, expect=400)
        self.req("POST", "/v1/shares", {"owner": "张三", "schoolID": "nju", "termID": "2026-fall-template",
                                        "courses": "not a list"}, expect=400)

    def test_a_long_owner_name_is_trimmed_not_rejected(self):
        created = self.create(owner="名" * 200)
        self.assertEqual(len(created["owner"]), 40)


if __name__ == "__main__":
    unittest.main()

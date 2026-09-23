"""Checks for the Live Activity device registry, plan store and dispatcher."""
import json, sqlite3, tempfile, threading, unittest

from server import live_activity
from server.naptable_server import Handler, Store
from tests.server_support import FastServer, JSONClientMixin

STATE = {"phase": "upcoming", "courseName": "数学", "startDate": 1_700_003_600.0, "endDate": 1_700_006_600.0}
ATTRIBUTES = {"semester": "2026-fall", "dateKey": "2026-09-18", "week": 3}


class FakeClient:
    """Records pushes instead of sending them, and can be told to fail."""

    def __init__(self, result=None):
        self.result = result or {"ok": True, "status": 200, "reason": ""}
        self.sent = []

    def push(self, token, payload, **kwargs):
        self.sent.append({"token": token, "payload": payload, **kwargs})
        return self.result

    def broadcast(self, channel_id, payload, **kwargs):
        self.sent.append({"channelID": channel_id, "payload": payload, **kwargs})
        return self.result


def item(item_id, fire_at, event="start", **extra):
    value = {"id": item_id, "fireAt": fire_at, "event": event, "contentState": dict(STATE)}
    if event == "start":
        value["attributes"] = dict(ATTRIBUTES)
    value.update(extra)
    return value


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.clock = [1_700_000_000.0]
        self.db = sqlite3.connect(":memory:", check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.client = FakeClient()
        self.service = live_activity.LiveActivityService(
            self.db, threading.RLock(), client=self.client, now=lambda: self.clock[0])
        self.device = self.service.register({"startToken": "ab12", "environment": "sandbox", "bundleID": "b"})

    def tearDown(self):
        self.db.close()

    def plan(self, items):
        return self.service.replace_plan(self.device["deviceID"], items)

    # -- registration ------------------------------------------------------

    def test_registration_returns_a_secret_only_once(self):
        self.assertIn("secret", self.device)
        again = self.service.register({"deviceID": self.device["deviceID"], "startToken": "cd34"}, self.device["secret"])
        self.assertNotIn("secret", again)
        self.assertEqual(self.service.status(self.device["deviceID"])["hasStartToken"], True)

    def test_authentication_rejects_a_wrong_or_missing_secret(self):
        device_id = self.device["deviceID"]
        self.assertIsNotNone(self.service.authenticate(device_id, self.device["secret"]))
        self.assertIsNone(self.service.authenticate(device_id, "nope"))
        self.assertIsNone(self.service.authenticate(device_id, ""))
        self.assertIsNone(self.service.authenticate("unknown", self.device["secret"]))

    def test_registration_refuses_a_non_hex_token(self):
        with self.assertRaises(live_activity.PlanError):
            self.service.register({"startToken": "not-a-token"})

    def test_refreshing_an_unknown_device_is_an_error(self):
        with self.assertRaises(live_activity.PlanError):
            self.service.register({"deviceID": "missing", "startToken": "ab"})

    def test_keeping_the_old_token_when_a_refresh_omits_it(self):
        self.service.register({"deviceID": self.device["deviceID"]}, self.device["secret"])
        self.assertTrue(self.service.status(self.device["deviceID"])["hasStartToken"])

    # -- plan validation ---------------------------------------------------

    def test_plan_round_trips_and_reports_the_next_fire(self):
        status = self.plan([item("a", 1_700_000_600), item("b", 1_700_000_300, "end")])
        self.assertEqual(status["pendingCount"], 2)
        self.assertEqual(status["nextFireAt"], 1_700_000_300)

    def test_a_new_plan_replaces_everything_still_pending(self):
        self.plan([item("a", 1_700_000_600), item("b", 1_700_000_900)])
        status = self.plan([item("c", 1_700_001_200)])
        self.assertEqual(status["pendingCount"], 1)
        self.assertEqual(status["nextFireAt"], 1_700_001_200)

    def test_sent_history_survives_a_replacement(self):
        self.plan([item("a", 1_700_000_000 - 10)])
        self.service.dispatch_due()
        status = self.plan([item("b", 1_700_000_600)])
        self.assertEqual([entry["item_id"] for entry in status["recent"]], ["a"])
        self.assertEqual(status["pendingCount"], 1)

    def test_rejects_bad_items(self):
        cases = [
            item("a", 1_700_000_600, event="explode"),
            item("", 1_700_000_600),
            {"id": "a", "event": "start", "contentState": {}, "attributes": {}},
            item("a", 1_700_000_000 + live_activity.MAX_HORIZON + 10),
            item("a", 1_700_000_000 - 7200),
            {"id": "a", "fireAt": 1_700_000_600, "event": "start", "attributes": {}},
            {"id": "a", "fireAt": 1_700_000_600, "event": "start", "contentState": {}},
            item("a", 1_700_000_600, contentState={"blob": "x" * 4000}),
        ]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(live_activity.PlanError):
                self.plan([value])

    def test_rejects_duplicate_ids_and_oversized_plans(self):
        with self.assertRaises(live_activity.PlanError):
            self.plan([item("a", 1_700_000_600), item("a", 1_700_000_900)])
        with self.assertRaises(live_activity.PlanError):
            self.plan([item(str(n), 1_700_000_600 + n) for n in range(live_activity.MAX_PLAN_ITEMS + 1)])

    def test_expiry_defaults_after_the_fire_time(self):
        normalized = live_activity.normalize_item(item("a", 1_700_000_600, expiresAt=1_700_000_100), 1_700_000_000)
        self.assertEqual(normalized["expires_at"], 1_700_000_660)

    # -- payload -----------------------------------------------------------

    def test_start_payload_carries_attributes_and_stale_date(self):
        payload = json.loads(live_activity.normalize_item(
            item("a", 1_700_000_600, staleDate=1_700_006_600, dismissalDate=1_700_006_700,
                 relevanceScore=90, alert={"title": "上课了", "body": "数学", "junk": "x"}),
            1_700_000_000)["payload"])
        aps = live_activity.aps_payload("start", payload, 1_700_000_600)["aps"]
        self.assertEqual(aps["event"], "start")
        self.assertEqual(aps["timestamp"], 1_700_000_600)
        self.assertEqual(aps["attributes-type"], "ScheduleLiveActivityAttributes")
        self.assertEqual(aps["attributes"], ATTRIBUTES)
        self.assertEqual(aps["content-state"], STATE)
        self.assertEqual(aps["stale-date"], 1_700_006_600)
        self.assertEqual(aps["relevance-score"], 90.0)
        self.assertEqual(aps["alert"], {"title": "上课了", "body": "数学"})
        # A dismissal date only means something when the activity is ending.
        self.assertNotIn("dismissal-date", aps)
        self.assertIn("dismissal-date", live_activity.aps_payload("end", payload, 1)["aps"])

    def test_update_payload_omits_attributes(self):
        payload = json.loads(live_activity.normalize_item(item("a", 1_700_000_600, event="update"), 1_700_000_000)["payload"])
        aps = live_activity.aps_payload("update", payload, 1_700_000_600)["aps"]
        self.assertNotIn("attributes", aps)
        self.assertEqual(aps["content-state"], STATE)

    # -- dispatch ----------------------------------------------------------

    def test_only_due_items_are_sent(self):
        self.plan([item("now", 1_700_000_000), item("later", 1_700_000_600)])
        results = self.service.dispatch_due()
        self.assertEqual([r["itemID"] for r in results], ["now"])
        self.assertEqual(self.client.sent[0]["token"], "ab12")
        self.assertEqual(self.client.sent[0]["environment"], "sandbox")
        self.assertEqual(self.client.sent[0]["push_type"], "liveactivity")
        self.assertEqual(self.service.status(self.device["deviceID"])["pendingCount"], 1)

    def test_an_item_is_sent_once(self):
        self.plan([item("a", 1_700_000_000)])
        self.service.dispatch_due()
        self.service.dispatch_due()
        self.assertEqual(len(self.client.sent), 1)

    # -- 调休 --------------------------------------------------------------

    def calendar(self, adjustments):
        """Give this service the global 调休 table the real server keeps."""
        self.db.execute("CREATE TABLE IF NOT EXISTS global_calendar (id INTEGER PRIMARY KEY CHECK(id=1),"
                        " version INTEGER NOT NULL DEFAULT 1, adjustments_json TEXT NOT NULL DEFAULT '[]',"
                        " updated_at TEXT NOT NULL DEFAULT '')")
        self.db.execute("INSERT INTO global_calendar (id,adjustments_json) VALUES (1,?)"
                        " ON CONFLICT(id) DO UPDATE SET adjustments_json=excluded.adjustments_json",
                        (json.dumps(adjustments),))
        self.db.commit()

    def test_a_holiday_added_after_the_upload_suppresses_the_start(self):
        self.plan([item("a", 1_700_000_000)])
        self.calendar([{"date": ATTRIBUTES["dateKey"], "kind": "off", "note": "国庆节"}])
        results = self.service.dispatch_due()
        self.assertEqual(results[0]["state"], "skipped")
        self.assertIn("调休", results[0]["detail"])
        self.assertEqual(self.client.sent, [])

    def test_a_holiday_suppresses_an_update_by_its_course_date(self):
        # An update carries no attributes, so the day comes from the course's
        # start instant read in the device's time zone.
        self.plan([item("a", 1_700_000_000, event="update")])
        self.service.remember_activity(self.device["deviceID"], {"activityID": "x", "updateToken": "ff01"})
        self.calendar([{"date": "2023-11-15", "kind": "off", "note": "校庆"}])
        results = self.service.dispatch_due()
        self.assertEqual(results[0]["state"], "skipped")
        self.assertEqual(self.client.sent, [])

    def test_a_holiday_still_dismisses_a_running_activity(self):
        self.plan([item("a", 1_700_000_000, event="end")])
        self.service.remember_activity(self.device["deviceID"], {"activityID": "x", "updateToken": "ff01"})
        self.calendar([{"date": "2023-11-15", "kind": "off", "note": "校庆"}])
        results = self.service.dispatch_due()
        self.assertEqual(results[0]["state"], "sent")
        self.assertEqual(len(self.client.sent), 1)

    def test_a_make_up_day_is_pushed_as_usual(self):
        self.plan([item("a", 1_700_000_000)])
        self.calendar([{"date": ATTRIBUTES["dateKey"], "kind": "swap", "source": "2026-09-14", "note": "上周一的课"}])
        results = self.service.dispatch_due()
        self.assertEqual(results[0]["state"], "sent")
        self.assertEqual(len(self.client.sent), 1)

    def test_an_expired_item_is_skipped_instead_of_pushed_late(self):
        self.plan([item("a", 1_700_000_000 - 600, expiresAt=1_700_000_000 - 60)])
        results = self.service.dispatch_due()
        self.assertEqual(results[0]["state"], "skipped")
        self.assertIn("expired", results[0]["detail"])
        self.assertEqual(self.client.sent, [])

    def test_start_without_a_token_waits_for_registration(self):
        service = live_activity.LiveActivityService(
            self.db, threading.RLock(), client=self.client, now=lambda: self.clock[0])
        device = service.register({})
        service.replace_plan(device["deviceID"], [item("a", 1_700_000_000)])
        self.assertEqual(service.dispatch_due()[0]["state"], "retrying")
        self.assertEqual(service.status(device["deviceID"])["pendingCount"], 1)

    def test_updates_use_the_registered_activity_token(self):
        device_id = self.device["deviceID"]
        self.service.remember_activity(device_id, {"activityID": "A1", "updateToken": "ff00", "expiresAt": 1_700_009_000})
        self.plan([item("u", 1_700_000_000, "update")])
        self.assertEqual(self.service.dispatch_due()[0]["state"], "sent")
        self.assertEqual(self.client.sent[0]["token"], "ff00")

    def test_update_without_an_activity_waits_for_registration(self):
        self.plan([item("u", 1_700_000_000, "update")])
        result = self.service.dispatch_due()[0]
        self.assertEqual(result["state"], "retrying")
        self.assertIn("update token", result["detail"])

    def test_an_expired_activity_token_is_not_used(self):
        self.service.remember_activity(self.device["deviceID"],
                                       {"activityID": "A1", "updateToken": "ff00", "expiresAt": 1_699_999_000})
        self.plan([item("u", 1_700_000_000, "update")])
        self.assertEqual(self.service.dispatch_due()[0]["state"], "retrying")

    def test_a_rejected_start_token_is_dropped(self):
        self.client.result = {"ok": False, "status": 410, "reason": "Unregistered"}
        self.plan([item("a", 1_700_000_000)])
        result = self.service.dispatch_due()[0]
        self.assertEqual(result["state"], "failed")
        self.assertEqual(result["detail"], "410 Unregistered")
        self.assertFalse(self.service.status(self.device["deviceID"])["hasStartToken"])

    def test_a_rejected_update_token_drops_only_that_activity(self):
        device_id = self.device["deviceID"]
        self.service.remember_activity(device_id, {"activityID": "A1", "updateToken": "ff00"})
        self.client.result = {"ok": False, "status": 400, "reason": "BadDeviceToken"}
        self.plan([item("u", 1_700_000_000, "update")])
        self.service.dispatch_due()
        self.assertEqual(self.service.status(device_id)["activityCount"], 0)
        self.assertTrue(self.service.status(device_id)["hasStartToken"])

    def test_other_failures_keep_the_token(self):
        self.client.result = {"ok": False, "status": 503, "reason": "ServiceUnavailable"}
        self.plan([item("a", 1_700_000_000)])
        self.assertEqual(self.service.dispatch_due()[0]["state"], "retrying")
        self.assertTrue(self.service.status(self.device["deviceID"])["hasStartToken"])

    def test_transient_failure_is_retried_after_backoff(self):
        self.client.result = {"ok": False, "status": 503, "reason": "ServiceUnavailable"}
        self.plan([item("a", 1_700_000_000)])
        self.assertEqual(self.service.dispatch_due()[0]["state"], "retrying")
        self.client.result = {"ok": True, "status": 200, "reason": ""}
        self.clock[0] += live_activity.RETRY_BASE_SECONDS + 1
        self.assertEqual(self.service.dispatch_due()[0]["state"], "sent")
        self.assertEqual(len(self.client.sent), 2)

    def test_update_waits_then_sends_when_activity_token_arrives(self):
        self.plan([item("u", 1_700_000_000, "update")])
        self.assertEqual(self.service.dispatch_due()[0]["state"], "retrying")
        self.service.remember_activity(self.device["deviceID"], {"activityID": "A1", "updateToken": "ff00"})
        self.clock[0] += live_activity.RETRY_BASE_SECONDS + 1
        self.assertEqual(self.service.dispatch_due()[0]["state"], "sent")

    def test_old_dispatch_completion_cannot_finish_a_replaced_plan(self):
        self.plan([item("same", 1_700_000_000)])
        old = self.db.execute(
            "SELECT revision FROM la_plan WHERE device_id=? AND item_id=?",
            (self.device["deviceID"], "same"),
        ).fetchone()[0]
        self.plan([item("same", 1_700_000_600)])
        result = self.service._finish(self.device["deviceID"], "same", "sent", "", old)
        self.assertEqual(result["state"], "sent")
        current = self.db.execute(
            "SELECT state,revision FROM la_plan WHERE device_id=? AND item_id=?",
            (self.device["deviceID"], "same"),
        ).fetchone()
        self.assertEqual(current["state"], "pending")
        self.assertNotEqual(current["revision"], old)

    def test_without_apns_the_plan_is_accepted_but_nothing_is_sent(self):
        service = live_activity.LiveActivityService(self.db, threading.RLock(), client=None, now=lambda: self.clock[0])
        device = service.register({"startToken": "ab"})
        service.replace_plan(device["deviceID"], [item("a", 1_700_000_000)])
        result = service.dispatch_due()[0]
        self.assertEqual(result["state"], "retrying")
        self.assertIn("APNs", result["detail"])
        self.assertFalse(service.status(device["deviceID"])["pushConfigured"])

    def test_forgetting_a_device_clears_its_plan(self):
        device_id = self.device["deviceID"]
        self.service.remember_activity(device_id, {"activityID": "A1", "updateToken": "ff00"})
        self.plan([item("a", 1_700_000_600)])
        self.service.forget(device_id)
        self.assertIsNone(self.service.status(device_id))
        self.assertEqual(self.service.dispatch_due(), [])

    def test_forgetting_one_activity_leaves_the_device(self):
        device_id = self.device["deviceID"]
        self.service.remember_activity(device_id, {"activityID": "A1", "updateToken": "ff00"})
        self.service.forget_activity(device_id, "A1")
        self.assertEqual(self.service.status(device_id)["activityCount"], 0)

    def test_school_broadcast_is_one_push_for_a_channel_and_contains_no_course(self):
        import datetime
        from zoneinfo import ZoneInfo
        # The dispatcher normally wakes a few seconds after the exact bell.
        clock = datetime.datetime(2026, 9, 18, 8, 0, 3, tzinfo=ZoneInfo("Asia/Shanghai")).timestamp()
        db = sqlite3.connect(":memory:", check_same_thread=False)
        db.row_factory = sqlite3.Row
        client = FakeClient()
        with db:
            db.executescript("""
            CREATE TABLE school_configs (id TEXT PRIMARY KEY, periods_json TEXT);
            CREATE TABLE school_terms (
              school_id TEXT, term_id TEXT, version INTEGER, semester_start_monday TEXT,
              week_count INTEGER, periods_json TEXT, timezone TEXT, note TEXT,
              updated_at TEXT, adjustments_json TEXT, is_current INTEGER
            );
            CREATE TABLE global_calendar (id INTEGER PRIMARY KEY, adjustments_json TEXT);
            INSERT INTO school_configs VALUES
              ('nju','[{"id":1,"start":"08:00","end":"08:50"}]');
            INSERT INTO school_terms VALUES
              ('nju','fall',1,'2026-09-14',18,
               '[]','Asia/Shanghai','', '', '[]', 1);
            INSERT INTO global_calendar VALUES (1, '[]');
            """)
            service = live_activity.LiveActivityService(
                db, threading.RLock(), client=client, now=lambda: clock,
                channels={("production", "nju"): "dHN0LXNyY2gtY2hubA=="})
            device = service.register({
                "environment": "production", "bundleID": "b", "schoolID": "nju",
                "termID": "fall", "supportsBroadcast": True,
            })
            self.assertEqual(device["channelID"], "dHN0LXNyY2gtY2hubA==")
            results = service.dispatch_due()
            self.assertEqual([result["state"] for result in results], ["sent"])
            self.assertEqual(len(client.sent), 1)
            self.assertEqual(client.sent[0]["channelID"], device["channelID"])
            state = client.sent[0]["payload"]["aps"]["content-state"]
            self.assertEqual(state["broadcastDateKey"], "2026-09-18")
            self.assertEqual(state["broadcastPeriod"], 1)
            self.assertEqual(state["broadcastPhase"], "started")
            self.assertEqual(state["courseName"], "")
        db.close()

    def test_school_broadcast_includes_a_weekend_swap_day(self):
        import datetime
        from zoneinfo import ZoneInfo
        clock = datetime.datetime(2026, 9, 20, 8, 0, 3, tzinfo=ZoneInfo("Asia/Shanghai")).timestamp()
        db = sqlite3.connect(":memory:", check_same_thread=False)
        db.row_factory = sqlite3.Row
        client = FakeClient()
        with db:
            db.executescript("""
            CREATE TABLE school_configs (id TEXT PRIMARY KEY, periods_json TEXT);
            CREATE TABLE school_terms (
              school_id TEXT, term_id TEXT, version INTEGER, semester_start_monday TEXT,
              week_count INTEGER, periods_json TEXT, timezone TEXT, note TEXT,
              updated_at TEXT, adjustments_json TEXT, is_current INTEGER
            );
            CREATE TABLE global_calendar (id INTEGER PRIMARY KEY, adjustments_json TEXT);
            INSERT INTO school_configs VALUES
              ('nju','[{"id":1,"start":"08:00","end":"08:50"}]');
            INSERT INTO school_terms VALUES
              ('nju','fall',1,'2026-09-14',18,
               '[]','Asia/Shanghai','', '', '[]', 1);
            INSERT INTO global_calendar VALUES
              (1, '[{"date":"2026-09-20","kind":"swap","source":"2026-09-18"}]');
            """)
            service = live_activity.LiveActivityService(
                db, threading.RLock(), client=client, now=lambda: clock,
                channels={("production", "nju"): "dHN0LXNyY2gtY2hubA=="})
            service.register({
                "environment": "production", "bundleID": "b", "schoolID": "nju",
                "termID": "fall", "supportsBroadcast": True,
            })
            results = service.dispatch_due()
            self.assertEqual([result["state"] for result in results], ["sent"])
            state = client.sent[0]["payload"]["aps"]["content-state"]
            self.assertEqual(state["broadcastDateKey"], "2026-09-20")
        db.close()

    def test_activity_registration_validates_its_token(self):
        with self.assertRaises(live_activity.PlanError):
            self.service.remember_activity(self.device["deviceID"], {"activityID": "A1", "updateToken": "zz"})


class EndpointTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.file = tempfile.NamedTemporaryFile(suffix=".sqlite3")
        Handler.store = Store(self.file.name)
        self.client = FakeClient()
        Handler.live_activity = live_activity.LiveActivityService(
            Handler.store.db, Handler.store.lock, client=self.client, now=lambda: 1_700_000_000.0)
        self.http = FastServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.http.serve_forever)
        self.thread.start()

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=2)
        Handler.store.close()
        Handler.live_activity = None
        self.file.close()

    def test_health_reports_whether_apns_is_configured(self):
        self.assertEqual(self.req("GET", "/v1/live-activity/health"), {"ok": True, "pushConfigured": True})

    def test_register_plan_and_read_status(self):
        device = self.req("POST", "/v1/live-activity/devices", {"startToken": "ab12", "environment": "sandbox"})
        auth = {"X-Device-Secret": device["secret"]}
        plan = self.req("PUT", f"/v1/live-activity/devices/{device['deviceID']}/plan",
                        {"items": [item("a", 1_700_000_600)]}, auth)
        self.assertEqual(plan["pendingCount"], 1)
        status = self.req("GET", f"/v1/live-activity/devices/{device['deviceID']}", headers=auth)
        self.assertEqual(status["nextFireAt"], 1_700_000_600)
        self.assertTrue(status["hasStartToken"])

    def test_activity_registration_and_removal(self):
        device = self.req("POST", "/v1/live-activity/devices", {"startToken": "ab12"})
        auth = {"X-Device-Secret": device["secret"]}
        path = f"/v1/live-activity/devices/{device['deviceID']}/activities"
        self.req("POST", path, {"activityID": "A1", "updateToken": "ff00"}, auth)
        self.assertEqual(self.req("GET", f"/v1/live-activity/devices/{device['deviceID']}", headers=auth)["activityCount"], 1)
        self.req("DELETE", path + "/A1", headers=auth)
        self.assertEqual(self.req("GET", f"/v1/live-activity/devices/{device['deviceID']}", headers=auth)["activityCount"], 0)

    def test_every_device_route_needs_the_secret(self):
        device = self.req("POST", "/v1/live-activity/devices", {"startToken": "ab12"})
        base = f"/v1/live-activity/devices/{device['deviceID']}"
        for method, path, value in [("GET", base, None), ("DELETE", base, None),
                                    ("PUT", base + "/plan", {"items": []}),
                                    ("POST", base + "/activities", {"activityID": "A", "updateToken": "ff"})]:
            with self.subTest(path=path):
                self.req(method, path, value, {"X-Device-Secret": "wrong"}, expect=403)

    def test_a_bad_plan_is_a_400_with_a_reason(self):
        device = self.req("POST", "/v1/live-activity/devices", {"startToken": "ab12"})
        auth = {"X-Device-Secret": device["secret"]}
        body = self.req("PUT", f"/v1/live-activity/devices/{device['deviceID']}/plan",
                        {"items": [item("a", 1_700_000_600, event="boom")]}, auth, expect=400)
        self.assertIn("event", body["error"])

    def test_forget_removes_the_device(self):
        device = self.req("POST", "/v1/live-activity/devices", {"startToken": "ab12"})
        auth = {"X-Device-Secret": device["secret"]}
        self.req("DELETE", f"/v1/live-activity/devices/{device['deviceID']}", headers=auth)
        self.req("GET", f"/v1/live-activity/devices/{device['deviceID']}", headers=auth, expect=403)

    def test_share_routes_still_work_alongside_the_new_prefix(self):
        created = self.req("POST", "/v1/shares", {"owner": "A", "schoolID": "nju",
                                                  "termID": "2026-fall-template", "courses": []}, expect=201)
        self.assertTrue(created["id"])
        self.assertEqual(self.req("GET", "/health"), {"ok": True})


if __name__ == "__main__":
    unittest.main()

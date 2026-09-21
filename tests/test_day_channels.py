import json
import threading
import unittest
from datetime import datetime, timezone, timedelta

from server.live_activity import LiveActivityService, PlanError
from server.naptable_server import Store


class Channels:
    bundle_id = "test.app"

    def __init__(self):
        self.created = []
        self.deleted = []
        self.sent = []

    def create_channel(self, environment):
        value = f"{environment}-{len(self.created)}"
        self.created.append(value)
        return value

    def delete_channel(self, channel, environment):
        self.deleted.append(channel)

    def broadcast(self, channel, payload, **kwargs):
        self.sent.append((channel, payload))
        return {"ok": True, "status": 200}

    def push(self, *args, **kwargs):
        raise AssertionError("date channel path must not send device pushes")


class DayChannelTests(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.clock = datetime(2026, 9, 18, 8, 0, 3, tzinfo=timezone(timedelta(hours=8))).timestamp()
        self.client = Channels()
        self.service = LiveActivityService(self.store.db, threading.RLock(), client=self.client, now=lambda: self.clock)

    def tearDown(self):
        self.store.close()

    def test_dates_are_isolated_bounded_and_require_no_devices(self):
        self.service.ensure_day_channels()
        config = self.service.day_config({"schoolID": "nju", "environment": "production", "bundleID": "test.app"})
        self.assertEqual(set(config["channels"]), {"2026-09-18", "2026-09-19"})
        self.assertEqual(len(set(config["channels"].values())), 2)
        count = len(self.client.created)
        for _ in range(5):
            self.service.day_config({"schoolID": "nju", "bundleID": "test.app"})
            self.service.ensure_day_channels()
        self.assertEqual(len(self.client.created), count)
        self.service.dispatch_due()
        self.assertTrue(self.client.sent)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM la_devices").fetchone()[0], 0)
        rows = self.store.db.execute("SELECT * FROM la_broadcast_plan WHERE channel_id=?", (config["channels"]["2026-09-18"],)).fetchall()
        self.assertEqual(sum(r["event"] == "end" for r in rows), 0)
        self.assertTrue(all("alert" not in json.loads(r["payload_json"])["aps"] for r in rows))
        self.assertTrue(all(payload["aps"]["event"] == "update" for _, payload in self.client.sent))
        self.clock += 3 * 86400
        self.service.ensure_day_channels()
        self.assertTrue(self.client.deleted)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM la_day_channels").fetchone()[0], count)
        with self.assertRaises(PlanError):
            self.service.day_config({"bundleID": "wrong"})

    def test_failed_cleanup_retains_id_for_retry(self):
        self.service.ensure_day_channels()
        original = self.client.delete_channel
        def fail(*args, **kwargs):
            raise RuntimeError("offline")
        self.client.delete_channel = fail
        self.clock += 3 * 86400
        self.service.ensure_day_channels()
        self.assertGreater(self.store.db.execute("SELECT COUNT(*) FROM la_day_channels WHERE date_key='2026-09-18'").fetchone()[0], 0)
        self.client.delete_channel = original
        self.clock += 61
        self.service.ensure_day_channels()
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM la_day_channels WHERE date_key='2026-09-18'").fetchone()[0], 0)

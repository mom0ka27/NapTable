"""Entitlement and 30-day trial behavior."""
import sqlite3
import threading
import tempfile
import unittest

from server.entitlements import Entitlements
from server.naptable_server import Store
from tests.server_support import JSONClientMixin, LiveServer


class EntitlementTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:", check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.clock = 1_790_033_400
        self.store = Entitlements(self.db, threading.RLock(), now=lambda: self.clock)

    def tearDown(self):
        self.db.close()

    def add(self, device, kind, expires=None, revoked=0):
        self.db.execute("""INSERT INTO device_entitlements
            VALUES(?,?,?,?,?,?,?,?,?,?)""",
            (device, f"tx-{device}-{kind}", f"original-{device}",
             "com.niyiwei.naptable.live_activity." + ("trial_30d" if kind == "trial" else "lifetime"),
             kind, "sandbox", self.clock - 1, expires, revoked, self.clock))
        self.db.commit()

    def test_trial_expires_after_thirty_days(self):
        self.add("trial", "trial", self.clock + 30 * 24 * 60 * 60)
        self.assertTrue(self.store.allows(self.db, "trial"))
        self.clock += 30 * 24 * 60 * 60
        self.assertFalse(self.store.allows(self.db, "trial"))

    def test_lifetime_never_expires(self):
        self.add("paid", "lifetime")
        self.assertTrue(self.store.allows(self.db, "paid"))
        self.assertEqual(self.store.entitlement(self.db, "paid")["source"], "lifetime")

    def test_revoked_entitlement_is_denied(self):
        self.add("refunded", "lifetime", revoked=1)
        self.assertFalse(self.store.allows(self.db, "refunded"))

    def test_entitlement_is_required_by_default(self):
        self.assertTrue(self.store.required())
        self.assertEqual(self.store.entitlement(self.db, "none"), {
            "required": True, "kind": None, "expiresAt": None, "source": None
        })

    def test_beta_switch_grants_free_access_without_consuming_trial(self):
        self.store.save_settings({"requireEntitlement": False})
        self.assertTrue(self.store.allows(self.db, "none"))
        self.assertEqual(self.db.execute("SELECT COUNT(*) FROM device_entitlements").fetchone()[0], 0)
        self.store.save_settings({"requireEntitlement": True})
        self.assertFalse(self.store.allows(self.db, "none"))


class PublicEntitlementSettingsTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.file = tempfile.NamedTemporaryFile(suffix=".sqlite3")
        self.store = Store(self.file.name)
        self.entitlements = Entitlements(self.store.db, self.store.lock)
        self.http = LiveServer(self.store, entitlements=self.entitlements)

    def tearDown(self):
        self.http.shutdown()
        self.store.close()
        self.file.close()

    def test_public_policy_tracks_beta_switch_and_exposes_no_device_data(self):
        path = "/v1/entitlements/settings"
        self.assertEqual(self.req("GET", path), {"requireEntitlement": True})
        self.entitlements.save_settings({"requireEntitlement": False})
        self.assertEqual(self.req("GET", path), {"requireEntitlement": False})
        self.entitlements.save_settings({"requireEntitlement": True})
        self.assertEqual(self.req("GET", path), {"requireEntitlement": True})
        self.req("POST", "/v1/admin/entitlements/settings", {"requireEntitlement": False}, expect=403)
        self.assertEqual(self.req("GET", path), {"requireEntitlement": True})


if __name__ == "__main__":
    unittest.main()

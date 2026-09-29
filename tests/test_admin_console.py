"""The console's own rules: who is signed in, what it logs, and what it guards."""
import os, tempfile, unittest
from unittest.mock import patch

from server.naptable_server import LOGIN_FAILURES, Store
from tests.server_support import JSONClientMixin, LiveServer

TERM = {"id": "2027-spring", "semesterStartMonday": "2027-02-22", "weekCount": 18, "timezone": "Asia/Shanghai"}


class AdminConsoleTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.file = tempfile.NamedTemporaryFile(suffix=".sqlite3")
        self.store = Store(self.file.name)
        self.http = LiveServer(self.store)
        self.environment = patch.dict(os.environ, {"NAPTABLE_ADMIN_TOKEN": "root-token",
                                                   "NAPTABLE_ADMIN_TOKENS": "alice=alice-token, bob=bob-token, broken"})
        self.environment.start()
        self.admin = {"X-Admin-Token": "alice-token"}

    def tearDown(self):
        self.environment.stop()
        self.http.shutdown()
        self.store.close()
        self.file.close()

    def sign_in(self, token, forwarded="203.0.113.1", expect=200):
        return self.req("POST", "/v1/admin/session", {"token": token}, {"X-Forwarded-For": forwarded}, expect=expect)

    def test_each_named_token_signs_in_as_its_admin(self):
        self.assertEqual(self.sign_in("root-token")["admin"], "admin")
        self.assertEqual(self.sign_in("bob-token")["admin"], "bob")
        self.assertEqual(self.req("GET", "/v1/admin/session", headers=self.admin)["admin"], "alice")
        self.sign_in("broken", expect=403)

    def test_rotating_one_token_signs_out_only_that_admin(self):
        cookies = {}
        for name in ("alice", "bob"):
            connection_headers = self.raw_sign_in(f"{name}-token")
            cookies[name] = connection_headers
        with patch.dict(os.environ, {"NAPTABLE_ADMIN_TOKENS": "alice=alice-new,bob=bob-token"}):
            self.req("GET", "/v1/admin/session", headers={"Cookie": cookies["alice"]}, expect=403)
            self.assertEqual(self.req("GET", "/v1/admin/session", headers={"Cookie": cookies["bob"]})["admin"], "bob")

    def raw_sign_in(self, token):
        import http.client, json
        connection = http.client.HTTPConnection("127.0.0.1", self.http.server_port, timeout=5)
        try:
            connection.request("POST", "/v1/admin/session", body=json.dumps({"token": token}),
                               headers={"Content-Type": "application/json"})
            response = connection.getresponse(); response.read()
            return response.getheader("Set-Cookie").split(";")[0]
        finally:
            connection.close()

    def test_wrong_tokens_lock_out_that_client_only(self):
        for _ in range(LOGIN_FAILURES):
            self.sign_in("guess", expect=403)
        # Even the right token waits now, and the header shares the count.
        self.sign_in("root-token", expect=429)
        self.req("GET", "/v1/admin/calendar", headers={"X-Admin-Token": "root-token", "X-Forwarded-For": "203.0.113.1"}, expect=429)
        self.sign_in("root-token", forwarded="203.0.113.2")

    def test_wrong_header_tokens_count_as_failures(self):
        for _ in range(LOGIN_FAILURES):
            self.req("GET", "/v1/admin/calendar", headers={"X-Admin-Token": "guess", "X-Forwarded-For": "198.51.100.7"}, expect=403)
        self.sign_in("root-token", forwarded="198.51.100.7", expect=429)

    def test_writes_are_audited_with_their_admin(self):
        self.sign_in("guess", forwarded="192.0.2.9", expect=403)
        self.sign_in("bob-token")
        self.req("POST", "/v1/admin/schools/test", {"name": "测试大学", "create": True,
                 "periods": [{"start": "08:00", "end": "08:50"}]}, self.admin)
        self.req("POST", "/v1/admin/schools/test/terms", TERM, self.admin)
        self.req("DELETE", "/v1/admin/schools/test", headers=self.admin)
        log = self.req("GET", "/v1/admin/audit", headers=self.admin)["entries"]
        self.assertEqual([(e["admin"], e["action"], e["target"]) for e in log], [
            ("alice", "school.delete", "test"), ("alice", "term.save", "test/2027-spring"),
            ("alice", "school.create", "test"), ("bob", "session.signIn", "203.0.113.1"),
            ("", "session.failed", "192.0.2.9")])
        self.assertEqual(log[2]["detail"], {"name": "测试大学", "periods": 1})
        only = self.req("GET", "/v1/admin/audit?action=school", headers=self.admin)["entries"]
        self.assertEqual([e["action"] for e in only], ["school.delete", "school.create"])
        self.req("GET", "/v1/admin/audit", expect=403)

    def test_a_term_that_is_not_current_can_be_deleted(self):
        self.req("POST", "/v1/admin/schools/nju/terms", TERM, self.admin)
        current = next(t["id"] for t in self.store.schools()[0]["terms"] if t["current"])
        refused = self.req("DELETE", f"/v1/admin/schools/nju/terms/{current}", headers=self.admin, expect=400)
        self.assertIn("当前学期", refused["error"])
        self.req("DELETE", "/v1/admin/schools/nju/terms/2027-spring", expect=403)
        self.req("DELETE", "/v1/admin/schools/nju/terms/2027-spring", headers=self.admin)
        self.req("DELETE", "/v1/admin/schools/nju/terms/2027-spring", headers=self.admin, expect=404)
        self.assertEqual([t["id"] for t in self.store.schools()[0]["terms"]], [current])

    def test_the_catalogue_is_written_only_under_the_admin_prefix(self):
        periods = [{"start": "08:00", "end": "08:50"}]
        self.req("POST", "/v1/schools/nju", {"name": "改名", "periods": periods}, self.admin, expect=404)
        self.req("DELETE", "/v1/schools/nju", headers=self.admin, expect=404)
        self.req("POST", "/v1/admin/apns/reconcile", {}, self.admin, expect=404)
        self.req("POST", "/v1/admin/schools/nju", {"name": "改名", "periods": periods}, expect=403)
        self.assertEqual(self.req("GET", "/v1/schools")["schools"][0]["name"], "南京大学")


if __name__ == "__main__":
    unittest.main()

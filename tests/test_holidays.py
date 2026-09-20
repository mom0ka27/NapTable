"""Checks for reading the published holiday arrangement into 调休 rows."""
import io, json, sqlite3, tempfile, threading, unittest
from datetime import date

from server import holidays
from server.naptable_server import Handler, Store
from tests.server_support import FastServer, JSONClientMixin

ARRANGEMENT = {
    "year": 2026,
    "papers": ["https://www.gov.cn/example"],
    "days": [
        {"name": "国庆节", "date": "2026-10-01", "isOffDay": True},
        {"name": "国庆节", "date": "2026-10-02", "isOffDay": True},
        {"name": "国庆节", "date": "2026-10-03", "isOffDay": True},
        {"name": "国庆节", "date": "2026-10-10", "isOffDay": False},
    ],
}


def opener(payload=ARRANGEMENT, fail_first=False):
    """Stand in for urlopen: records the URLs it was asked for."""
    calls = []

    class Response(io.BytesIO):
        def __enter__(self): return self
        def __exit__(self, *_): self.close(); return False

    def open_url(url, timeout=None):
        calls.append(url)
        if fail_first and len(calls) == 1:
            raise OSError("connection reset")
        return Response(json.dumps(payload).encode())

    open_url.calls = calls
    return open_url


class HolidayFetchTests(unittest.TestCase):
    def test_reads_days_and_records_source(self):
        result = holidays.fetch_year(2026, opener())
        self.assertEqual(result["year"], 2026)
        self.assertEqual(len(result["days"]), 4)
        self.assertTrue(result["source"].endswith("2026.json"))

    def test_falls_back_to_the_mirror(self):
        open_url = opener(fail_first=True)
        result = holidays.fetch_year(2026, open_url)
        self.assertEqual(len(open_url.calls), 2)
        self.assertIn("jsdelivr", result["source"])

    def test_every_mirror_failing_is_an_error(self):
        def broken(url, timeout=None): raise OSError("no route to host")
        with self.assertRaises(holidays.HolidayError):
            holidays.fetch_year(2026, broken)

    def test_rejects_a_response_without_days(self):
        with self.assertRaises(holidays.HolidayError):
            holidays.fetch_year(2026, opener({"year": 2026}))

    def test_skips_unparsable_days(self):
        payload = {"days": [{"date": "not-a-date"}, {"date": "2026-10-01", "isOffDay": True}]}
        self.assertEqual(len(holidays.fetch_year(2026, opener(payload))["days"]), 1)


class HolidayPlanTests(unittest.TestCase):
    def test_off_days_become_off_rows(self):
        plan = holidays.plan(holidays.fetch_year(2026, opener())["days"])
        off = [row for row in plan["proposed"] if row["kind"] == "off"]
        self.assertEqual([row["date"] for row in off], ["2026-10-01", "2026-10-02", "2026-10-03"])
        self.assertEqual(off[0]["note"], "国庆节")

    def test_a_worked_weekend_needs_a_source(self):
        plan = holidays.plan(holidays.fetch_year(2026, opener())["days"])
        swap = [row for row in plan["proposed"] if row["kind"] == "swap"][0]
        self.assertEqual(swap["date"], "2026-10-10")
        self.assertEqual(swap["source"], "")
        self.assertTrue(swap["needsSource"])
        self.assertEqual(plan["needsSource"], ["2026-10-10"])

    def test_candidates_are_weekdays_of_the_same_holiday(self):
        plan = holidays.plan(holidays.fetch_year(2026, opener())["days"])
        swap = [row for row in plan["proposed"] if row["kind"] == "swap"][0]
        # 2026-10-03 is a Saturday, so it never makes up a day of classes.
        self.assertEqual(swap["candidates"], ["2026-10-02", "2026-10-01"])

    def test_existing_dates_are_kept_untouched(self):
        existing = [{"date": "2026-10-01", "kind": "off", "note": "校庆"}]
        plan = holidays.plan(holidays.fetch_year(2026, opener())["days"], existing)
        self.assertEqual(plan["kept"], ["2026-10-01"])
        self.assertNotIn("2026-10-01", [row["date"] for row in plan["proposed"]])

    def test_next_year_is_added_once_it_is_published(self):
        self.assertEqual(holidays.years_to_fetch(date(2026, 3, 1)), [2026])
        self.assertEqual(holidays.years_to_fetch(date(2026, 9, 21)), [2026, 2027])


class ImportEndpointTests(JSONClientMixin, unittest.TestCase):
    def setUp(self):
        self.db = tempfile.NamedTemporaryFile(suffix=".sqlite3")
        Handler.store = Store(self.db.name)
        Handler.live_activity = None
        self.http = FastServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self._fetch = holidays.fetch_year
        holidays.fetch_year = lambda year, opener=None: {
            "year": year, "papers": [], "source": f"test://{year}",
            "days": holidays._clean(ARRANGEMENT["days"]),
        }
        import os
        os.environ["NAPTABLE_ADMIN_TOKEN"] = "secret"

    def tearDown(self):
        holidays.fetch_year = self._fetch
        self.http.shutdown(); self.http.server_close(); self.thread.join(timeout=2)
        Handler.store.close(); self.db.close()
        import os
        os.environ.pop("NAPTABLE_ADMIN_TOKEN", None)

    def head(self): return {"X-Admin-Token": "secret"}

    def test_import_requires_the_admin_token(self):
        self.req("POST", "/v1/admin/calendar/import", {}, expect=403)

    def test_import_previews_without_writing(self):
        before = self.req("GET", "/v1/admin/calendar", headers=self.head())
        result = self.req("POST", "/v1/admin/calendar/import", {"years": [2026]}, self.head())
        self.assertEqual(len(result["proposed"]), 4)
        self.assertEqual(result["years"][0]["needsSource"], ["2026-10-10"])
        after = self.req("GET", "/v1/admin/calendar", headers=self.head())
        self.assertEqual(after["version"], before["version"])
        self.assertEqual(after["adjustments"], [])

    def test_import_skips_what_is_already_configured(self):
        self.req("POST", "/v1/admin/calendar",
                 {"adjustments": [{"date": "2026-10-01", "kind": "off", "note": "校庆"}]}, self.head())
        result = self.req("POST", "/v1/admin/calendar/import", {"years": [2026]}, self.head())
        self.assertEqual(result["years"][0]["kept"], ["2026-10-01"])
        self.assertNotIn("2026-10-01", [row["date"] for row in result["proposed"]])

    def test_a_bad_year_list_is_rejected(self):
        self.req("POST", "/v1/admin/calendar/import", {"years": ["昨天"]}, self.head(), expect=400)
        self.req("POST", "/v1/admin/calendar/import", {"years": [1900]}, self.head(), expect=400)

    def test_every_source_failing_is_reported(self):
        def broken(year, opener=None): raise holidays.HolidayError("获取失败")
        holidays.fetch_year = broken
        self.req("POST", "/v1/admin/calendar/import", {"years": [2026]}, self.head(), expect=400)


if __name__ == "__main__":
    unittest.main()

"""XJTU actual-date clocks through school config, frozen shares and APNs delivery."""
import copy
from datetime import date
import json
from pathlib import Path
import tempfile
import unittest

from server import school_times
from server.live_activity import LiveActivityService
from server.live_activity_schedule import build_day, instant, own_table, own_timetable, share_table
from server.live_activity_timeline import ProtocolError, boundaries, normalize_schedule, canonical, digest
from server.live_activity_v2 import Service
from server.naptable_server import Store
from tests.test_live_activity_v2 import APNs, TestVault

FIXTURE = json.loads((Path(__file__).parent / "fixtures/xjtu-seasonal-times.json").read_text())
SEASONS = FIXTURE["seasons"]
WINTER = SEASONS[1]["periods"]


def timetable(monday="2026-09-07", **extra):
    return {"scope": "own-xjtu", "schoolID": "xjtu", "periods": WINTER,
            "seasonalPeriods": SEASONS, "semesterStartMonday": monday, "weekCount": 24,
            "courses": [{"id": f"afternoon-{day}", "day": day, "first": 5, "last": 6, "weeks": []} for day in range(1, 8)],
            **extra}


class SeasonalTimesTests(unittest.TestCase):
    def test_official_clocks_and_boundaries(self):
        self.assertEqual(school_times.default_seasons("xjtu"), SEASONS)
        self.assertEqual(school_times.default_seasons("nju"), [])
        for expected in FIXTURE["days"]:
            day = date.fromisoformat(expected["date"])
            periods = school_times.periods_on(WINTER, SEASONS, day)
            self.assertEqual((periods[4]["start"], periods[5]["end"]), (expected["start"], expected["end"]))
            self.assertEqual(periods[:4], WINTER[:4])
            monday = "2026-03-02" if day.month < 7 else "2026-09-07"
            if day.year == 2027: monday = "2026-09-07"
            table = own_table(timetable(monday))
            occurrence = build_day("device", day, table, settings={"leadMinutes": 30, "perPeriod": True})[0][0]
            self.assertEqual((occurrence["start"], occurrence["end"], occurrence["reminder"]),
                             (instant(day, expected["start"]), instant(day, expected["end"]), instant(day, expected["start"]) - 1800))
            self.assertEqual(len(occurrence["frames"]), 4)
            schedule = normalize_schedule(WINTER, "Asia/Shanghai", SEASONS)
            bells = dict(boundaries(schedule, day.isoformat(), 6))
            self.assertEqual(bells[int(occurrence["start"])]["aps"]["content-state"]["broadcastPeriod"], 5)
            self.assertEqual(bells[int(occurrence["end"])]["aps"]["event"], "end")

    def test_swapped_course_uses_actual_day_clocks(self):
        table = own_table(timetable(adjustments=[{"date": "2026-09-30", "kind": "swap", "source": "2026-10-01"}]))
        day = date(2026, 9, 30)
        occurrence = build_day("device", day, table, settings={"leadMinutes": 30})[0][0]
        self.assertEqual(occurrence["start"], instant(day, "14:30"))
        self.assertEqual(occurrence["frames"][0]["lead"]["course"], "afternoon-4")
        self.assertEqual(build_day("device", date(2026, 10, 1), table)[0], [])

    def test_upload_validation_and_explicit_disable(self):
        old_client = timetable()
        old_client.pop("seasonalPeriods")
        self.assertEqual(own_timetable(old_client)[1]["seasonalPeriods"], SEASONS)
        disabled = own_table(timetable(seasonalPeriods=[]))
        self.assertEqual(disabled.periods_on(date(2026, 9, 30))[4][0], "14:00")
        for bad in [None, "bad", [{"from": "02-29", "periods": WINTER}],
                    [SEASONS[0], SEASONS[0]], [{"from": "05-01", "periods": WINTER[:2]}],
                    [{"from": "05-01", "periods": [{"start": "25:00", "end": "25:50"}]}]]:
            with self.subTest(bad=bad), self.assertRaises(ProtocolError):
                own_timetable(timetable(seasonalPeriods=bad))
        changed = copy.deepcopy(SEASONS)
        changed[0]["periods"][4]["start"] = "10:00"
        with self.assertRaises(ProtocolError): own_timetable(timetable(seasonalPeriods=changed))

    def test_school_versions_rename_and_frozen_share(self):
        store = Store(":memory:")
        self.addCleanup(store.close)
        value = {"id": "xjtu", "name": "西安交通大学", "periods": WINTER}
        school = store.save_school(value)
        self.assertEqual(school["seasonalPeriods"], SEASONS)
        term = store.save_term("xjtu", {"id": "2026-fall", "semesterStartMonday": "2026-09-07",
                                       "weekCount": 24, "timezone": "Asia/Shanghai", "current": True})
        self.assertEqual(term["seasonalPeriods"], SEASONS)
        shared = store.create({"schoolID": "xjtu", "termID": term["id"], "courses": [
            {"id": 1, "name": "共享课", "week_time": 3, "start_time": 5, "time_count": 1, "weeks": []}]})
        self.assertEqual(shared["seasonalPeriods"], SEASONS)
        store.save_school(dict(value, seasonalPeriods=[]))
        self.assertEqual(store.find_term("xjtu", term["id"])["version"], 2)
        frozen = store.get(shared["id"])
        self.assertEqual(frozen["seasonalPeriods"], SEASONS)
        row = dict(store._read(shared["id"]))
        table, _ = share_table(row)
        self.assertEqual(build_day("device", date(2026, 9, 30), table)[0][0]["start"], instant(date(2026, 9, 30), "14:30"))
        store.rename_school("xjtu", "xjtu-renamed")
        self.assertEqual(next(school for school in store.schools() if school['id'] == 'xjtu-renamed')["seasonalPeriods"], [])
        self.assertEqual(store.get(shared["id"])["seasonalPeriods"], SEASONS)
        store.delete_school("xjtu-renamed")
        self.assertEqual(store.db.execute("SELECT COUNT(*) FROM school_seasonal_periods WHERE school_id='xjtu-renamed'").fetchone()[0], 0)

    def test_saved_custom_seasons_and_disable_survive_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "schools.sqlite3")
            custom = copy.deepcopy(SEASONS)
            custom[0]["periods"][4]["start"] = "14:40"
            for seasons in [custom, []]:
                store = Store(path)
                store.save_school({"id": "xjtu", "name": "西交大", "periods": WINTER, "seasonalPeriods": seasons})
                store.close()
                reopened = Store(path)
                try:
                    self.assertEqual(next(school for school in reopened.schools() if school['id'] == 'xjtu')["seasonalPeriods"], seasons)
                finally:
                    reopened.close()


class SeasonalAPNsTests(unittest.TestCase):
    def test_legacy_registration_migrates_once_and_same_revision_retransmits(self):
        store = Store(":memory:")
        self.addCleanup(store.close)
        store.save_school({"id": "xjtu", "name": "西交大", "periods": WINTER})
        store.save_term("xjtu", {"id": "fall", "semesterStartMonday": "2026-09-07", "weekCount": 24,
                                 "timezone": "Asia/Shanghai", "current": True})
        client = APNs()
        legacy = LiveActivityService(store.db, store.lock, client=client, now=lambda: instant(date(2026, 9, 30), "00:00"))
        service = Service(legacy, TestVault())
        device = service.register({"installationId": "legacy-device", "bundleID": client.bundle_id,
                                   "environment": "sandbox", "startToken": "ab12"}, "persisted-secret")["deviceID"]
        uploaded = {"revision": 1, "settings": {"leadMinutes": 30}, "own": timetable()}
        uploaded['own'].pop('seasonalPeriods')
        service.put_timetable(device, uploaded)
        old = json.loads(store.db.execute("SELECT body FROM la_timetables").fetchone()[0])
        old['own'].pop('seasonalPeriods')
        store.db.execute("UPDATE la_timetables SET body=?,digest=?", (canonical(old), digest(old)))
        store.db.commit()
        upgraded = Service(legacy, TestVault())
        row = store.db.execute("SELECT body,revision FROM la_timetables").fetchone()
        self.assertEqual(json.loads(row['body'])['own']['seasonalPeriods'], SEASONS)
        self.assertEqual(row['revision'], 1)
        upgraded.put_timetable(device, uploaded)
        upgraded.maintain_channels()
        starts = {day.isoformat(): items[0].fire_at for day, items in upgraded.plans[device].items()}
        self.assertEqual(starts['2026-09-30'], instant(date(2026, 9, 30), '14:00'))
        self.assertEqual(starts['2026-10-01'], instant(date(2026, 10, 1), '13:30'))

    def test_push_start_and_channel_end_switch_without_another_upload(self):
        for before, after, monday in [("2026-04-30", "2026-05-01", "2026-03-02"),
                                      ("2026-09-30", "2026-10-01", "2026-09-07")]:
            with self.subTest(before=before):
                store = Store(":memory:")
                self.addCleanup(store.close)
                store.save_school({"id": "xjtu", "name": "西安交通大学", "periods": WINTER})
                store.save_term("xjtu", {"id": "current", "semesterStartMonday": monday, "weekCount": 24,
                                         "timezone": "Asia/Shanghai", "current": True})
                clock = [instant(date.fromisoformat(before), "00:00")]
                client = APNs()
                legacy = LiveActivityService(store.db, store.lock, client=client, now=lambda: clock[0])
                service = Service(legacy, TestVault())
                device = service.register({"installationId": "seasonal-device", "bundleID": client.bundle_id,
                                           "environment": "sandbox", "startToken": "ab12cd34"}, "persisted-secret")["deviceID"]
                service.put_timetable(device, {"revision": 1, "settings": {"leadMinutes": 30, "perPeriod": True}, "own": timetable(monday)})
                service.maintain_channels()
                self.assertEqual(len(client.channels), 10)
                service.plan_broadcasts()
                for expected_day in [before, after]:
                    expected = next(day for day in FIXTURE["days"] if day["date"] == expected_day)
                    day = date.fromisoformat(expected_day)
                    clock[0] = instant(day, expected["start"]) - 1800
                    service.nightly()
                    service.dispatch_starts()
                    payload = client.starts[-1][1]["aps"]
                    self.assertEqual(payload["attributes"]["dateKey"], expected_day)
                    self.assertEqual(payload["attributes"]["reservationStart"] + 978307200, instant(day, expected["start"]))
                    self.assertEqual(payload["stale-date"], instant(day, expected["end"]))
                    self.assertIn("input-push-channel", payload)
                    clock[0] = instant(day, expected["end"])
                    service.plan_broadcasts()
                    service.dispatch_broadcasts()
                    ending = [item for _, item, _ in client.broadcasts if item["aps"]["event"] == "end"
                              and item["aps"]["content-state"]["broadcastDateKey"] == expected_day
                              and item["aps"]["content-state"]["broadcastPeriod"] == 6]
                    self.assertEqual(len(ending), 1)
                    self.assertEqual(ending[0]["aps"]["timestamp"], int(instant(day, expected["end"])))
                self.assertEqual(len(client.starts), 2)
                self.assertEqual(store.db.execute("SELECT revision FROM la_timetables WHERE device=?", (device,)).fetchone()[0], 1)

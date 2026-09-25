import json
import unittest
from datetime import date, timedelta

from server.live_activity_schedule import (build_day, conflicts_between, instant, occurrence_id, own_table,
                                           own_timetable, refresh_at, share_table)
from server.live_activity_timeline import ProtocolError

PERIODS = [{"start": "08:00", "end": "08:45"}, {"start": "08:55", "end": "09:40"},
           {"start": "10:00", "end": "10:45"}, {"start": "10:55", "end": "11:40"},
           {"start": "14:00", "end": "14:45"}, {"start": "14:55", "end": "15:40"}]
TUESDAY = date(2026, 9, 22)  # week 3 of a term starting 2026-09-07


def at(clock, day=TUESDAY):
    return instant(day, clock)


def table(courses, periods=PERIODS, adjustments=(), weeks=18, **extra):
    return own_table({"scope": "own-scope", "periods": periods, "semesterStartMonday": "2026-09-07", "weekCount": weeks,
                      "adjustments": list(adjustments), "courses": courses, **extra})


def course(key, first, last, day=2, weeks=()):
    return {"id": key, "day": day, "first": first, "last": last, "weeks": list(weeks)}


def spans(occurrence):
    return [(frame["from"], frame["until"], frame["lead"]["table"], frame["lead"]["course"], frame["lead"]["phase"],
             frame["companion"] and frame["companion"]["course"]) for frame in occurrence["frames"]]


class OwnTableTests(unittest.TestCase):
    def test_unknown_fields_are_ignored_and_not_kept(self):
        _, kept = own_timetable({"scope": "s", "periods": [dict(PERIODS[0], number=1, name="第1节")], "semesterStartMonday": "2026-09-07",
                                 "weekCount": 18, "timeZone": "Asia/Shanghai", "adjustments": [{"date": "2026-10-01", "kind": "off", "note": "国庆"}],
                                 "courses": [dict(course("a", 1, 1), name="高数", teacher="王")]})
        self.assertEqual(kept, {"scope": "s", "periods": [PERIODS[0]], "semesterStartMonday": "2026-09-07", "weekCount": 18,
                                "adjustments": [{"date": "2026-10-01", "kind": "off"}],
                                "courses": [{"id": "a", "day": 2, "first": 1, "last": 1, "weeks": []}]})

    def test_rejects_impossible_timetables(self):
        with self.assertRaises(ProtocolError):
            table([course("a", 1, 9)])
        with self.assertRaises(ProtocolError):
            table([], periods=[{"start": "09:00", "end": "08:00"}])
        with self.assertRaises(ProtocolError):
            own_table({"scope": "s", "periods": PERIODS, "semesterStartMonday": "2026-09-08", "weekCount": 18,
                       "adjustments": [], "courses": []})
        with self.assertRaises(ProtocolError):
            table([], adjustments=[{"date": "2026-10-11", "kind": "swap"}])


class SingleTableTests(unittest.TestCase):
    def test_consecutive_periods_form_one_class_and_the_lead_stops_at_the_previous_class(self):
        own = table([course("a", 1, 2), course("b", 3, 3)])
        occurrences, _ = build_day("device", TUESDAY, own, settings={"leadMinutes": 30})
        self.assertEqual([(o["reminder"], o["start"], o["end"]) for o in occurrences],
                         [(at("07:30"), at("08:00"), at("09:40")), (at("09:40"), at("10:00"), at("10:45"))])
        self.assertEqual(spans(occurrences[0]), [(at("07:30"), at("08:00"), "own", "a", "upcoming", None),
                                                 (at("08:00"), at("09:40"), "own", "a", "inProgress", None)])

    def test_per_period_frames_show_the_break(self):
        occurrences, _ = build_day("device", TUESDAY, table([course("a", 1, 2)]), settings={"leadMinutes": 15, "perPeriod": True})
        frames = occurrences[0]["frames"]
        self.assertEqual([(f["from"], f["until"], f["lead"]["phase"], f["lead"].get("break")) for f in frames],
                         [(at("07:45"), at("08:00"), "upcoming", None), (at("08:00"), at("08:45"), "inProgress", None),
                          (at("08:45"), at("08:55"), "upcoming", 2), (at("08:55"), at("09:40"), "inProgress", None)])
        self.assertEqual(frames[3]["lead"]["start"], at("08:55"))
        self.assertEqual(refresh_at(occurrences[0]), [at("08:00"), at("08:45"), at("08:55")])

    def test_weeks_and_calendar_adjustments(self):
        own = table([course("odd", 1, 1, weeks=[1, 3, 5]), course("even", 3, 3, weeks=[2, 4])],
                    adjustments=[{"date": "2026-10-01", "kind": "off"},
                                 {"date": "2026-10-10", "kind": "swap", "source": "2026-09-29"}])
        settings = {"leadMinutes": 15}
        # Week 3 runs the odd-week course only.
        self.assertEqual([o["frames"][0]["lead"]["course"] for o in build_day("device", TUESDAY, own, settings=settings)[0]], ["odd"])
        # Saturday 10-10 runs Tuesday 09-29 (week 4): the even-week course, on its own date.
        swapped, _ = build_day("device", date(2026, 10, 10), own, settings=settings)
        self.assertEqual([(o["frames"][0]["lead"]["course"], o["start"]) for o in swapped], [("even", at("10:00", date(2026, 10, 10)))])
        # The swap consumes its source day, and `off` cancels the day.
        self.assertEqual(build_day("device", date(2026, 9, 29), own, settings=settings)[0], [])
        self.assertEqual(build_day("device", date(2026, 10, 1), own, settings=settings)[0], [])
        # Outside the term there is nothing.
        self.assertEqual(build_day("device", date(2027, 3, 2), own, settings=settings)[0], [])

    def test_overlapping_courses_wait_for_a_choice(self):
        own = table([course("a", 1, 2), course("b", 2, 3)])
        occurrences, report = build_day("device", TUESDAY, own, settings={"leadMinutes": 15})
        self.assertEqual(occurrences, [])
        self.assertEqual(report["conflicts"], [{"id": "2026-09-22:2", "date": "2026-09-22", "period": 2, "choices": ["a", "b"]}])
        chosen, _ = build_day("device", TUESDAY, own, settings={"leadMinutes": 15}, conflicts={"2026-09-22:2": "b"})
        self.assertEqual([(o["frames"][-1]["lead"]["course"], o["start"], o["end"]) for o in chosen],
                         [("a", at("08:00"), at("08:45")), ("b", at("08:55"), at("10:45"))])
        found, _ = conflicts_between("device", TUESDAY, TUESDAY + timedelta(days=7), own, settings={"leadMinutes": 15}, now=at("07:00"))
        self.assertEqual([item["date"] for item in found], ["2026-09-22", "2026-09-29"])

    def test_finished_and_overlong_classes(self):
        own = table([course("a", 1, 1), course("long", 1, 6, day=3)])
        self.assertEqual(build_day("device", TUESDAY, own, settings={"leadMinutes": 15}, now=at("09:00"))[0], [])
        long_day = [{"start": "06:00", "end": "07:00"}, {"start": "14:00", "end": "15:00"}]
        _, report = build_day("device", TUESDAY, table([course("a", 1, 2)], periods=long_day), settings={"leadMinutes": 60})
        self.assertEqual(report["omitted"], 1)

    def test_ids_are_stable_and_per_device(self):
        own = table([course("a", 1, 2)])
        first = build_day("device", TUESDAY, own, settings={"leadMinutes": 15})[0][0]["occurrenceId"]
        self.assertEqual(first, build_day("device", TUESDAY, own, settings={"leadMinutes": 60})[0][0]["occurrenceId"])
        self.assertEqual(first, occurrence_id("device", "own:a:2026-09-22:1:2"))
        self.assertNotEqual(first, build_day("other", TUESDAY, own, settings={"leadMinutes": 15})[0][0]["occurrenceId"])


    def test_ids_hold_all_day(self):
        # Computed mid-afternoon, the morning chain keeps the id it had at dawn.
        own = table([course("a", 1, 2), course("b", 5, 6)])
        share = table([course("s", 2, 5)])
        dawn = build_day("device", TUESDAY, own, share, settings={"leadMinutes": 15}, now=at("06:00"))[0]
        later = build_day("device", TUESDAY, own, share, settings={"leadMinutes": 15}, now=at("14:30"))[0]
        self.assertEqual([o["occurrenceId"] for o in later], [o["occurrenceId"] for o in dawn])
        self.assertEqual(later[0]["frames"], dawn[0]["frames"])


class MergedTests(unittest.TestCase):
    # The share's school rings at other times.
    SHARE_PERIODS = [{"start": "09:30", "end": "10:30"}, {"start": "16:00", "end": "17:00"}]

    def share(self, courses):
        return table(courses, periods=self.SHARE_PERIODS)

    def test_each_table_reminds_by_its_own_lead(self):
        own = table([course("mine", 3, 3)])            # 10:00–10:45
        share = self.share([course("theirs", 1, 1)])   # 09:30–10:30
        occurrences, _ = build_day("device", TUESDAY, own, share, settings={"leadMinutes": 60, "sharedLeadMinutes": 15})
        self.assertEqual(len(occurrences), 1)
        merged = occurrences[0]
        # My course reminds at 09:00, before theirs at 09:15: it opens the countdown.
        self.assertEqual((merged["reminder"], merged["start"], merged["end"]), (at("09:00"), at("09:30"), at("10:45")))
        self.assertEqual(spans(merged), [
            (at("09:00"), at("09:15"), "own", "mine", "upcoming", None),
            (at("09:15"), at("09:30"), "share", "theirs", "upcoming", "mine"),
            (at("09:30"), at("10:00"), "share", "theirs", "inProgress", "mine"),
            (at("10:00"), at("10:30"), "share", "theirs", "inProgress", "mine"),
            (at("10:30"), at("10:45"), "own", "mine", "inProgress", None)])
        self.assertEqual(merged["alertAt"], [at("09:15")])
        self.assertEqual(merged["frames"][2]["companion"]["phase"], "upcoming")
        self.assertEqual(merged["frames"][3]["companion"]["phase"], "inProgress")
        self.assertIn(at("09:15"), refresh_at(merged))

    def test_same_lead_matches_a_single_reminder(self):
        own = table([course("mine", 3, 3)])
        share = self.share([course("theirs", 1, 1)])
        merged = build_day("device", TUESDAY, own, share, settings={"leadMinutes": 30, "sharedLeadMinutes": 30})[0][0]
        self.assertEqual(merged["reminder"], at("09:00"))
        self.assertEqual(spans(merged)[0][:5], (at("09:00"), at("09:30"), "share", "theirs", "upcoming"))
        self.assertEqual(merged["alertAt"], [at("09:30")])

    def test_courses_apart_remind_on_their_own(self):
        own = table([course("mine", 1, 1)])            # 08:00–08:45
        share = self.share([course("theirs", 2, 2)])   # 16:00–17:00
        occurrences, _ = build_day("device", TUESDAY, own, share, settings={"leadMinutes": 15, "sharedLeadMinutes": 30})
        self.assertEqual([(o["reminder"], o["frames"][0]["lead"]["table"]) for o in occurrences],
                         [(at("07:45"), "own"), (at("15:30"), "share")])
        self.assertTrue(all(o["alertAt"] == [] for o in occurrences))

    def test_a_long_chain_hands_over_to_a_new_activity(self):
        # Their two long classes back to back, overlapped by my morning and afternoon courses.
        share = table([course("theirs", 1, 2)], periods=[{"start": "08:30", "end": "12:00"}, {"start": "12:00", "end": "16:00"}])
        own = table([course("morning", 1, 1), course("noon", 5, 6)])
        occurrences, _ = build_day("device", TUESDAY, own, share, settings={"leadMinutes": 15, "sharedLeadMinutes": 15})
        self.assertEqual(len(occurrences), 2)
        self.assertEqual(occurrences[0]["end"], occurrences[1]["start"])
        self.assertLessEqual(occurrences[0]["end"] - occurrences[0]["reminder"], 8 * 3600)
        self.assertNotEqual(occurrences[0]["occurrenceId"], occurrences[1]["occurrenceId"])


class ShareRowTests(unittest.TestCase):
    def row(self, courses, **extra):
        value = {"class_time_list_json": json.dumps([{"id": 1, "name": "第1节", "start": "08:00", "end": "08:45"},
                                                     {"id": 2, "name": "第2节", "start": "08:55", "end": "09:40"}]),
                 "term_snapshot_json": json.dumps({"weekCount": 18}), "semester_start_monday": "2026-09-07",
                 "adjustments_json": "[]", "payload_json": json.dumps(courses)}
        value.update(extra)
        return value

    def test_reads_the_publishers_rows(self):
        share, texts = share_table(self.row([
            {"id": 7, "name": "高数", "teacher": "王", "classroom": "A101", "week_time": 2, "start_time": 1, "time_count": 1, "weeks": "[1,3]"},
            {"id": 8, "name": "英语", "weekTime": 2, "startTime": 2, "timeCount": 0, "weeks": [2, 3]},
            {"id": 9, "name": "收起的课", "week_time": 2, "start_time": 1, "time_count": 0, "weeks": [], "hidden": True},
            {"id": 10, "name": "自由课", "week_time": 0, "start_time": 0, "weeks": []}]))
        self.assertEqual([(c["id"], c["first"], c["last"], sorted(c["weeks"])) for c in share.courses],
                         [("7", 1, 2, [1, 3]), ("8", 2, 2, [2, 3])])
        self.assertEqual(texts["7"], {"name": "高数", "teacher": "王", "location": "A101"})

    def test_rows_without_unique_ids_stay_unscheduled(self):
        share, _ = share_table(self.row([{"id": 1, "name": "a", "week_time": 2, "start_time": 1},
                                         {"id": 1, "name": "b", "week_time": 3, "start_time": 1}]))
        self.assertEqual(share.courses, [])


if __name__ == "__main__":
    unittest.main()

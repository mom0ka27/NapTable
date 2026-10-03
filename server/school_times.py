"""Annual bell schedules; choose by the actual teaching date, never a swap's source date."""
from copy import deepcopy
from datetime import date
import json
import re

CLOCK = re.compile(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]")


def default_seasons(school):
    if str(school or "").lower() != "xjtu":
        return []
    # 西交大教务处标准作息：https://due.xjtu.edu.cn/xxfw/zxsj.htm
    morning = [("08:00", "08:50"), ("09:00", "09:50"), ("10:10", "11:00"), ("11:10", "12:00")]
    summer = [("14:30", "15:20"), ("15:30", "16:20"), ("16:40", "17:30"),
              ("17:40", "18:30"), ("19:40", "20:30"), ("20:40", "21:30")]
    winter = [("14:00", "14:50"), ("15:00", "15:50"), ("16:10", "17:00"),
              ("17:10", "18:00"), ("19:10", "20:00"), ("20:10", "21:00")]
    return [{"from": start, "periods": [{"start": a, "end": b} for a, b in morning + afternoon]}
            for start, afternoon in (("05-01", summer), ("10-01", winter))]


def normalize_seasons(value, count=None):
    if not isinstance(value, list) or len(value) > 4:
        raise ValueError("seasonalPeriods must contain at most 4 schedules")
    result, seen, lengths = [], set(), set()
    for season in value:
        if not isinstance(season, dict):
            raise ValueError("invalid seasonal schedule")
        start = season.get("from")
        if not isinstance(start, str) or not re.fullmatch(r"\d{2}-\d{2}", start):
            raise ValueError("season start must be MM-dd")
        try: date.fromisoformat("2001-" + start)
        except ValueError: raise ValueError("invalid annual season start")
        if start in seen:
            raise ValueError("duplicate season start")
        seen.add(start)
        periods = season.get("periods")
        if not isinstance(periods, list) or not 1 <= len(periods) <= 32:
            raise ValueError("expected 1–32 seasonal periods")
        clean, previous = [], "00:00"
        for period in periods:
            if not isinstance(period, dict): raise ValueError("invalid seasonal period")
            a, b = period.get("start"), period.get("end")
            if not all(isinstance(clock, str) and CLOCK.fullmatch(clock) for clock in (a, b)):
                raise ValueError("invalid seasonal period clock")
            if a < previous or b <= a:
                raise ValueError("seasonal periods must be ordered and non-overlapping")
            previous = b
            clean.append({"start": a, "end": b})
        lengths.add(len(clean))
        result.append({"from": start, "periods": clean})
    if len(lengths) > 1 or (count is not None and lengths and lengths != {count}):
        raise ValueError("seasonal schedules must have the same number of periods as the base schedule")
    return sorted(result, key=lambda season: season["from"])


def periods_on(base, seasons, day):
    if not seasons:
        return base
    month_day = day.isoformat()[5:] if isinstance(day, date) else str(day)[5:]
    ordered = sorted(seasons, key=lambda season: season["from"])
    return next((season["periods"] for season in reversed(ordered) if season["from"] <= month_day), ordered[-1]["periods"])


def stored_seasons(db, school):
    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='school_seasonal_periods'").fetchone():
        row = db.execute("SELECT periods_json FROM school_seasonal_periods WHERE school_id=?", (school,)).fetchone()
        if row:
            return json.loads(row[0])
    return deepcopy(default_seasons(school))

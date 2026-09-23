"""Read the State Council holiday arrangement and turn it into 调休 rows.

The published arrangement says which dates are off and which weekend dates are
worked; it never says *which weekday's classes* a worked day runs, because that
is each school's own notice. So this module proposes rows and leaves the swap
source for the admin to confirm — guessing it would silently delete a day of
classes on every client.
"""
from __future__ import annotations
import json
import re
from datetime import date, timedelta
from urllib.request import Request, urlopen

# Match CPU-Web’s public holiday providers. holiday-cn is generated from
# State Council announcements; its CDN mirror is the final fallback.
SOURCES = (
    "https://api.jiejiariapi.com/v1/holidays/{year}",
    "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/{year}.json",
    "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{year}.json",
)
TIMEOUT = 10
MAX_BYTES = 256 * 1024


class HolidayError(RuntimeError):
    """The arrangement could not be fetched or did not parse."""


def _open(url, timeout=TIMEOUT):  # pragma: no cover - replaced in tests
    request = Request(url, headers={"User-Agent": "NapTable/1.0", "Accept": "application/json"})
    return urlopen(request, timeout=timeout)


def fetch_year(year, opener=_open):
    """Return the parsed arrangement for one year, trying each mirror in turn."""
    year = int(year)
    errors = []
    for template in SOURCES:
        url = template.format(year=year)
        try:
            with opener(url) as response:
                raw = response.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise HolidayError("响应过大")
            value = json.loads(raw.decode("utf-8"))
            if not isinstance(value, dict):
                raise ValueError("数据格式异常")
            if "jiejiariapi.com" in url:
                days = list(value.values())
                if any(not isinstance(row, dict) or row.get("date") != key for key, row in value.items()):
                    raise ValueError("日期键不匹配")
            else:
                if value.get("year") != year:
                    raise ValueError("年份不匹配")
                days = value.get("days")
            cleaned = _clean(days, year)
            return {"year": year, "papers": value.get("papers") or [], "days": cleaned, "source": url}
        except Exception as error:
            errors.append(f"{url}: {error}")
    raise HolidayError(f"{year} 年安排获取失败：" + "；".join(errors))


def _clean(days, year=None):
    if not isinstance(days, list) or not days:
        raise ValueError("数据尚未发布或缺少 days 字段")
    rows, seen = [], set()
    for item in days:
        if not isinstance(item, dict):
            raise ValueError("日期数据格式异常")
        value = item.get("date", "")
        if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            raise ValueError("日期格式异常")
        day = date.fromisoformat(value)
        if (year is not None and day.year != year) or value in seen:
            raise ValueError("年份不匹配或日期重复")
        if type(item.get("isOffDay")) is not bool or not isinstance(item.get("name"), str) or not item["name"].strip():
            raise ValueError("假期名称或放假标记异常")
        seen.add(value)
        # The API includes observances such as 小年; only official worked
        # weekends are makeup candidates, as in CPU-Web.
        if not item["isOffDay"] and (day.weekday() < 5 or item["name"] not in
                {"元旦", "春节", "清明节", "劳动节", "端午节", "中秋节", "国庆节"}):
            continue
        rows.append({"date": value, "name": item["name"][:40], "isOffDay": item["isOffDay"]})
    return sorted(rows, key=lambda row: row["date"])


def plan(days, existing=None):
    """Turn one year of arrangement days into rows for the 调休 editor.

    Dates already configured are reported as `kept` and never rewritten: the
    admin may have corrected them. Worked weekends become `swap` rows with an
    empty source and `needsSource` set, so the UI can ask which day's classes
    they run.
    """
    existing_dates = {str(item.get("date")) for item in (existing or []) if isinstance(item, dict)}
    off_days = [row for row in days if row["isOffDay"]]
    proposed, kept = [], []
    for row in days:
        if row["date"] in existing_dates:
            kept.append(row["date"])
            continue
        if row["isOffDay"]:
            proposed.append({"date": row["date"], "kind": "off", "note": row["name"], "needsSource": False})
        else:
            proposed.append({"date": row["date"], "kind": "swap", "source": "",
                             "note": f"{row['name']}调休", "needsSource": True,
                             "candidates": _candidates(row, off_days)})
    return {"proposed": proposed, "kept": kept,
            "needsSource": [row["date"] for row in proposed if row.get("needsSource")]}


def _candidates(worked, off_days):
    """Weekdays inside the same holiday block — the classes a worked weekend
    most often makes up. Offered as choices, never applied on their own."""
    day = date.fromisoformat(worked["date"])
    block = [row for row in off_days
             if row["name"] == worked["name"] and date.fromisoformat(row["date"]).weekday() < 5]
    block.sort(key=lambda row: abs((date.fromisoformat(row["date"]) - day).days))
    return [row["date"] for row in block[:5]]


def years_to_fetch(today):
    """This year, plus next year once its arrangement is normally published."""
    years = [today.year]
    if (today + timedelta(days=120)).year != today.year:
        years.append(today.year + 1)
    return years

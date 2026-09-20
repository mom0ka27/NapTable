"""Read the State Council holiday arrangement and turn it into 调休 rows.

The published arrangement says which dates are off and which weekend dates are
worked; it never says *which weekday's classes* a worked day runs, because that
is each school's own notice. So this module proposes rows and leaves the swap
source for the admin to confirm — guessing it would silently delete a day of
classes on every client.
"""
from __future__ import annotations
import json
from datetime import date, timedelta
from urllib.request import Request, urlopen

# holiday-cn is regenerated from the gov.cn announcements and keeps one file per
# year; the second entry is a CDN mirror of the same repository.
SOURCES = (
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
        except HolidayError:
            raise
        except Exception as error:
            errors.append(f"{url}: {error}")
            continue
        days = value.get("days")
        if not isinstance(days, list):
            errors.append(f"{url}: 缺少 days 字段")
            continue
        return {"year": year, "papers": value.get("papers") or [], "days": _clean(days), "source": url}
    raise HolidayError(f"{year} 年安排获取失败：" + "；".join(errors))


def _clean(days):
    rows = []
    for item in days:
        if not isinstance(item, dict):
            continue
        try:
            day = date.fromisoformat(str(item.get("date", "")))
        except ValueError:
            continue
        rows.append({"date": day.isoformat(), "name": str(item.get("name") or "")[:40],
                     "isOffDay": bool(item.get("isOffDay"))})
    rows.sort(key=lambda row: row["date"])
    return rows


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

"""Protocol v2 validation and public timeline. All wire instants are Unix seconds."""
import hashlib
import json
import math
import re
from datetime import date, datetime
from zoneinfo import ZoneInfo

DAY = 86400


class ProtocolError(ValueError):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", value):
        raise ProtocolError("invalid identifier")
    return value


def integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise ProtocolError("integer outside accepted range")
    return value


def instant(value):
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ProtocolError("expected finite Unix seconds")
    return value


def normalize_schedule(periods, timezone):
    try:
        ZoneInfo(timezone)
    except (ValueError, KeyError, TypeError):
        raise ProtocolError("invalid IANA time zone")
    if not isinstance(periods, list) or not 1 <= len(periods) <= 32:
        raise ProtocolError("expected 1–32 periods")
    result, previous = [], "00:00"
    for index, period in enumerate(periods, 1):
        start, end = period.get("start"), period.get("end")
        for clock in (start, end):
            if not isinstance(clock, str) or not re.fullmatch(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]", clock):
                raise ProtocolError("invalid period clock")
        if start < previous or end <= start:
            raise ProtocolError("periods must be ordered and non-overlapping")
        previous = end
        result.append({"number": index, "start": start, "end": end})
    return {"periods": result, "timeZone": timezone}


def timestamp(day, clock, timezone):
    try:
        if date.fromisoformat(day).isoformat() != day:
            raise ValueError()
        local = datetime.fromisoformat(day + "T" + clock).replace(tzinfo=ZoneInfo(timezone))
        stamp = int(local.timestamp())
        # Refuse DST gaps and ambiguous bells rather than silently choosing one.
        if datetime.fromtimestamp(stamp, ZoneInfo(timezone)).replace(tzinfo=None) != local.replace(tzinfo=None):
            raise ValueError()
        if local.replace(fold=1).utcoffset() != local.utcoffset():
            raise ValueError()
        return stamp
    except (ValueError, TypeError):
        raise ProtocolError("invalid or ambiguous local date/time")


def validate_plan(plan, schedule, now):
    allowed = {"protocolVersion", "planRevision", "scheduleScope", "schoolID", "scheduleId", "scheduleVersion",
               "coverageStart", "coverageEndExclusive", "leadMinutes", "items", "busyIntervals"}
    # `pushMode` is optional so a channel plan stays byte-identical to older clients.
    if not isinstance(plan, dict) or set(plan) - {"pushMode"} != allowed:
        raise ProtocolError("expected complete v2 plan; personal display fields are forbidden")
    if plan.get("pushMode", "channel") not in ("channel", "token"):
        raise ProtocolError("pushMode must be channel or token")
    integer(plan["protocolVersion"], 2, 2)
    integer(plan["planRevision"], 1, 2**53 - 1)
    for key in ("scheduleScope", "schoolID", "scheduleId", "scheduleVersion"):
        identifier(plan[key])
    start, end = instant(plan["coverageStart"]), instant(plan["coverageEndExclusive"])
    if start > now + 300 or end <= start or end > start + 200 * DAY or start < now - DAY:
        raise ProtocolError("invalid coverage window")
    integer(plan["leadMinutes"], 15, 60)
    if plan["leadMinutes"] not in (15, 30, 60):
        raise ProtocolError("leadMinutes must be 15, 30 or 60")
    items, busy = plan["items"], plan["busyIntervals"]
    if not isinstance(items, list) or len(items) > 10000 or not isinstance(busy, list) or len(busy) > 10000:
        raise ProtocolError("too many intervals")
    blocks = []
    for interval in busy:
        if set(interval) != {"start", "end"}:
            raise ProtocolError("invalid busy interval")
        a, b = instant(interval["start"]), instant(interval["end"])
        if not start - DAY <= a < b <= end + DAY:
            raise ProtocolError("busy interval outside coverage")
        blocks.append((a, b))
    events, seen = [], set()
    periods = schedule["periods"]
    # A followed share also reminds the reader of their own courses, which sit on
    # another school's bells: token mode may place an occurrence by its instants.
    shapes = [{"occurrenceId", "supersedes", "dateKey", "startPeriod", "endPeriod"}]
    if plan.get("pushMode") == "token":
        shapes.append({"occurrenceId", "supersedes", "dateKey", "start", "end"})
    for item in items:
        if not isinstance(item, dict) or set(item) not in shapes:
            raise ProtocolError("invalid occurrence; display fields are forbidden")
        occurrence = identifier(item["occurrenceId"])
        if occurrence in seen:
            raise ProtocolError("duplicate occurrenceId")
        seen.add(occurrence)
        if not isinstance(item["supersedes"], list) or len(item["supersedes"]) > 64:
            raise ProtocolError("invalid supersedes")
        for value in item["supersedes"]:
            if identifier(value) == occurrence:
                raise ProtocolError("occurrence cannot supersede itself")
        if "start" in item:
            try:
                if not isinstance(item["dateKey"], str) or date.fromisoformat(item["dateKey"]).isoformat() != item["dateKey"]:
                    raise ValueError()
            except ValueError:
                raise ProtocolError("invalid dateKey")
            a, b = instant(item["start"]), instant(item["end"])
            if b <= a:
                raise ProtocolError("occurrence must end after it starts")
        else:
            first = integer(item["startPeriod"], 1, len(periods))
            last = integer(item["endPeriod"], first, len(periods))
            a = timestamp(item["dateKey"], periods[first - 1]["start"], schedule["timeZone"])
            b = timestamp(item["dateKey"], periods[last - 1]["end"], schedule["timeZone"])
        if b <= start or a >= end:
            raise ProtocolError("occurrence outside coverage")
        events.append(dict(item, start=a, end=b))
    events.sort(key=lambda item: (item["start"], item["occurrenceId"]))
    previous = None
    for event in events:
        if previous is not None and previous > event["start"]:
            raise ProtocolError("resolve overlapping courses before scheduling")
        if any(a < event["end"] and b > event["start"] for a, b in blocks):
            raise ProtocolError("course overlaps nonstandard busy interval")
        occupied = max([b for a, b in blocks if b <= event["start"]] + [previous or 0])
        event["fireAt"] = max(event["start"] - plan["leadMinutes"] * 60, occupied)
        if event["end"] - event["fireAt"] > 8 * 3600:
            raise ProtocolError("activity exceeds eight hours")
        previous = event["end"]
    return events


def validate_activity(value, now):
    """Per-activity refresh times for token mode. Times only: no course field is accepted.
    `alertAt` (optional) names the refreshes that also sound the course reminder."""
    if not isinstance(value, dict) or set(value) - {"alertAt"} != {"token", "dateKey", "refreshAt", "end"}:
        raise ProtocolError("expected token, dateKey, refreshAt and end only")
    token = value["token"]
    if not isinstance(token, str) or not 16 <= len(token) <= 512 or any(c not in "0123456789abcdefABCDEF" for c in token):
        raise ProtocolError("invalid activity push token")
    day = value["dateKey"]
    try:
        if not isinstance(day, str) or date.fromisoformat(day).isoformat() != day:
            raise ValueError()
    except ValueError:
        raise ProtocolError("invalid dateKey")
    end, refresh = instant(value["end"]), value["refreshAt"]
    if not now < end <= now + 8 * DAY:
        raise ProtocolError("activity end outside accepted range")
    if not isinstance(refresh, list) or len(refresh) > 64:
        raise ProtocolError("expected at most 64 refresh instants")
    previous = None
    for stamp in refresh:
        if not now - 60 <= instant(stamp) < end or (previous is not None and stamp <= previous):
            raise ProtocolError("refreshAt must be increasing and inside the activity")
        previous = stamp
    if end - min(refresh + [now]) > 8 * 3600:
        raise ProtocolError("activity exceeds eight hours")
    alerts = value.get("alertAt", [])
    if not isinstance(alerts, list) or len(alerts) > 16 or any(type(stamp) not in (int, float) or stamp not in refresh for stamp in alerts):
        raise ProtocolError("alertAt must be refresh instants")
    return {"token": token, "day": day, "refreshAt": refresh, "end": end, "alertAt": alerts}


def public_state(day, period, phase, stamp):
    return {"broadcastDateKey": day, "broadcastPeriod": period, "broadcastPhase": phase,
            "broadcastTimestamp": stamp, "updatedAt": stamp, "startDate": stamp, "endDate": stamp}


def boundaries(schedule, day, final_period):
    result = {}
    for period in schedule["periods"][:final_period]:
        for phase, clock in (("started", period["start"]), ("ended", period["end"])):
            stamp = timestamp(day, clock, schedule["timeZone"])
            event = "end" if period["number"] == final_period and phase == "ended" else "update"
            result[stamp] = {"aps": {"timestamp": stamp, "event": event,
                "content-state": public_state(day, period["number"], phase, stamp),
                **({"dismissal-date": stamp} if event == "end" else {"stale-date": stamp + 60})}}
    return sorted(result.items())

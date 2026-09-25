"""Protocol v2 shared helpers and the public broadcast timeline. All wire instants are Unix seconds."""
import hashlib
import json
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

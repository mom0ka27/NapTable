"""Server-side reminder schedule: the only place occurrences are computed.

A device uploads the time structure of its timetable (never course names) and
its reminder settings; a followed share is read from the `shares` table. The
engine turns one day of that into occurrences — one live activity each — with
their frames: which course of which table leads the display, which one rides
along as the companion, and when that changes. Frames carry course ids and
periods only; the phone renders the text.

Every date and clock is UTC+8. Ported from `LiveActivityTimeline.build`.
"""
from datetime import date, datetime, timedelta, timezone
import json
import re
import uuid

try:
    from .live_activity_timeline import ProtocolError, identifier
except ImportError:
    from live_activity_timeline import ProtocolError, identifier

ZONE = timezone(timedelta(hours=8))
LEADS = (15, 30, 60)
EIGHT_HOURS = 8 * 3600
NAMESPACE = uuid.UUID("5b0a3f53-2f1e-4d52-9a0c-7c1f6f0d2a61")
CLOCK = re.compile(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]")


def today(now):
    return datetime.fromtimestamp(now, ZONE).date()


def instant(day, clock):
    hour, minute = map(int, clock.split(":"))
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=ZONE).timestamp()


def occurrence_id(device, key):
    return str(uuid.uuid5(NAMESPACE, device + "\n" + key))


# MARK: Tables

def _day(value, message):
    try:
        if not isinstance(value, str) or date.fromisoformat(value).isoformat() != value:
            raise ValueError()
        return date.fromisoformat(value)
    except ValueError:
        raise ProtocolError(message)


def _periods(value):
    if not isinstance(value, list) or not 1 <= len(value) <= 32:
        raise ProtocolError("expected 1–32 periods")
    result, previous = [], "00:00"
    for period in value:
        if not isinstance(period, dict):
            raise ProtocolError("invalid period")
        start, end = period.get("start"), period.get("end")
        if not all(isinstance(clock, str) and CLOCK.fullmatch(clock) for clock in (start, end)):
            raise ProtocolError("invalid period clock")
        if start < previous or end <= start:
            raise ProtocolError("periods must be ordered and non-overlapping")
        previous = end
        result.append((start, end))
    return result


def _adjustments(value):
    """`date -> (sourceDay, sourceWeek date)` like `CalendarAdjustmentResolver`:
    `off` and a swap's consumed source day map to None (no classes)."""
    if not isinstance(value, list) or len(value) > 400:
        raise ProtocolError("expected at most 400 adjustments")
    direct, result = {}, {}
    for item in value:
        if not isinstance(item, dict) or item.get("kind") not in ("off", "swap"):
            raise ProtocolError("invalid adjustment")
        day = _day(item.get("date"), "invalid adjustment date")
        source = _day(item.get("source"), "a swap needs its source date") if item["kind"] == "swap" else None
        direct[day] = source
    for day, source in direct.items():
        result[day] = source
    for source in direct.values():
        if source is not None and source not in direct:
            result.setdefault(source, None)
    return result


class Table:
    """One timetable on the clock: periods, term and courses by weekday."""

    def __init__(self, periods, monday, weeks, adjustments, courses):
        self.periods, self.monday, self.weeks = periods, monday, weeks
        self.adjustments, self.courses = adjustments, courses

    def week(self, day):
        return (day - self.monday).days // 7 + 1

    def on(self, day):
        """The courses running on `day`, after 调休."""
        week = self.week(day)
        if not 1 <= week <= self.weeks:
            return []
        if day in self.adjustments:
            source = self.adjustments[day]
            if source is None:
                return []
            weekday, week = source.isoweekday(), self.week(source)
        else:
            weekday = day.isoweekday()
        return [course for course in self.courses
                if course["day"] == weekday and (not course["weeks"] or week in course["weeks"])]

    def last_day(self):
        return self.monday + timedelta(days=7 * self.weeks - 1)


def own_timetable(value):
    """The device's own timetable as uploaded: (Table, the fields kept).

    Unknown fields are ignored and never stored, so a newer client adding one
    does not break an older server, and nothing beyond times is persisted."""
    if not isinstance(value, dict):
        raise ProtocolError("own timetable must be an object")
    kept = {"scope": identifier(value.get("scope"))}
    if value.get("schoolID") is not None:
        kept["schoolID"] = identifier(value["schoolID"])
    periods = _periods(value.get("periods"))
    kept["periods"] = [{"start": start, "end": end} for start, end in periods]
    monday = _day(value.get("semesterStartMonday"), "invalid semesterStartMonday")
    if monday.isoweekday() != 1:
        raise ProtocolError("semesterStartMonday must be a Monday")
    kept["semesterStartMonday"] = monday.isoformat()
    weeks = value.get("weekCount")
    if type(weeks) is not int or not 1 <= weeks <= 60:
        raise ProtocolError("weekCount must be 1–60")
    kept["weekCount"] = weeks
    raw = value.get("adjustments", [])
    adjustments = _adjustments(raw)
    kept["adjustments"] = [{key: item[key] for key in ("date", "kind", "source") if key in item and (key != "source" or item["kind"] == "swap")}
                           for item in raw]
    courses, seen = [], set()
    if not isinstance(value.get("courses"), list) or len(value["courses"]) > 1000:
        raise ProtocolError("expected at most 1000 courses")
    for course in value["courses"]:
        if not isinstance(course, dict):
            raise ProtocolError("invalid course")
        key = identifier(course.get("id"))
        day, first, last, listed = course.get("day"), course.get("first"), course.get("last"), course.get("weeks", [])
        if type(day) is not int or not 1 <= day <= 7:
            raise ProtocolError("course day must be 1–7")
        if type(first) is not int or type(last) is not int or not 1 <= first <= last <= len(periods):
            raise ProtocolError("course periods outside the timetable")
        if not isinstance(listed, list) or len(listed) > 60 or any(type(week) is not int or not 1 <= week <= 60 for week in listed):
            raise ProtocolError("invalid course weeks")
        if (key, day, first, last) in seen:
            continue
        seen.add((key, day, first, last))
        courses.append({"id": key, "day": day, "first": first, "last": last, "weeks": sorted(set(listed))})
    kept["courses"] = courses
    table = Table(periods, monday, weeks, adjustments, [dict(course, weeks=set(course["weeks"])) for course in courses])
    return table, kept


def own_table(value):
    return own_timetable(value)[0]


def _weeks(value):
    """`CoursePayloadCodec.normalizeWeeks`: a list, a JSON list or free text."""
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            value = re.findall(r"\d+", value)
    if not isinstance(value, list):
        return set()
    result = set()
    for item in value:
        try:
            week = int(item)
        except (TypeError, ValueError):
            continue
        if week > 0:
            result.add(week)
    return result


def _integer(row, *keys):
    for key in keys:
        value = row.get(key)
        if value is None:
            continue
        try:
            return int(str(value).strip()) if isinstance(value, str) else int(value)
        except (TypeError, ValueError):
            return None
    return None


def share_table(row):
    """A share row as the reader's app installs it. Rows without a unique
    publisher id stay unscheduled, as on the client."""
    periods = [(period["start"], period["end"]) for period in json.loads(row["class_time_list_json"] or "[]")
               if isinstance(period, dict) and CLOCK.fullmatch(str(period.get("start", ""))) and CLOCK.fullmatch(str(period.get("end", "")))]
    snapshot = json.loads(row["term_snapshot_json"] or "{}")
    try:
        monday = date.fromisoformat(row["semester_start_monday"])
    except (TypeError, ValueError):
        return None, {}
    adjustments = {}
    try:
        adjustments = _adjustments([{key: item[key] for key in ("date", "kind", "source") if key in item}
                                    for item in json.loads(row["adjustments_json"] or "[]")])
    except (ProtocolError, TypeError, KeyError):
        adjustments = {}
    rows = json.loads(row["payload_json"] or "[]")
    ids = [_integer(course, "id") or 0 for course in rows]
    unique = len(set(ids)) == len(ids)
    courses, texts = [], {}
    for course, key in zip(rows, ids):
        if not unique or key <= 0 or course.get("hidden"):
            continue
        day = _integer(course, "week_time", "weekTime") or 0
        first = _integer(course, "start_time", "startTime") or 0
        count = max(0, _integer(course, "time_count", "timeCount") or 0)
        last = first + count
        if not 1 <= day <= 7 or first < 1 or last > len(periods):
            continue
        courses.append({"id": str(key), "day": day, "first": first, "last": last, "weeks": _weeks(course.get("weeks"))})
        texts[str(key)] = {field: str(course.get(source) or "") for field, source in
                           (("name", "name"), ("teacher", "teacher"), ("location", "classroom"))}
    return Table(periods, monday, max(1, int(snapshot.get("weekCount") or 0)), adjustments, courses), texts


# MARK: Frames
#
# A frame is `{from, until, lead, companion}`. `lead` and `companion` are refs:
# `{table, course, day, phase, first, last, start, end}` plus `break: n` for the
# gap before period n. `phase` is `upcoming` (counting down to `start`) or
# `inProgress` (running to `end`).

def _ref(table, course, day, phase, first, last, start, end, pause=None):
    ref = {"table": table, "course": course, "day": day.isoformat(), "phase": phase,
           "first": first, "last": last, "start": start, "end": end}
    if pause is not None:
        ref["break"] = pause
    return ref


def _frame(start, until, lead, companion=None):
    return {"from": start, "until": until, "lead": lead, "companion": companion}


class Piece:
    """One course of either table placed on the clock, before merging."""

    def __init__(self, key, table, course, day, first, last, start, end, reminder, frames, own=False):
        self.key, self.table, self.course, self.day = key, table, course, day
        self.first, self.last, self.start, self.end = first, last, start, end
        self.reminder, self.frames, self.own = reminder, frames, own

    def upcoming(self, since):
        return _ref(self.table, self.course, self.day, "upcoming", self.first, self.last, self.start, self.end)


def _bells(table, day, first, last):
    return [(number, instant(day, table.periods[number - 1][0]), instant(day, table.periods[number - 1][1]))
            for number in range(first, last + 1)]


def _class_frames(name, table, day, course, first, last, start, end, per_period):
    """In class: one frame, or per period with 「课间」 breaks between."""
    if not per_period:
        return [_frame(start, end, _ref(name, course, day, "inProgress", first, last, start, end))]
    frames = []
    for number, a, b in _bells(table, day, first, last):
        if frames and frames[-1]["until"] < a:
            frames.append(_frame(frames[-1]["until"], a, _ref(name, course, day, "upcoming", number, number, a, b, pause=number)))
        frames.append(_frame(a, b, _ref(name, course, day, "inProgress", first, last, a, b)))
    return frames


def _lead_pieces(name, table, day, lead, per_period, conflicts, report):
    """The leading table's courses: consecutive periods of one course form one
    class; overlapping courses need the reader's choice, else the day is skipped."""
    occupants = {}
    for course in table.on(day):
        if course["last"] > len(table.periods):
            continue
        for period in range(course["first"], course["last"] + 1):
            occupants.setdefault(period, {})[course["id"]] = course
    selected, unresolved = [], False
    for period in sorted(occupants):
        candidates = occupants[period]
        key = f"{day.isoformat()}:{period}"
        if len(candidates) > 1:
            report["conflicts"].append({"id": key, "date": day.isoformat(), "period": period, "choices": sorted(candidates)})
        source = next(iter(candidates)) if len(candidates) == 1 else conflicts.get(key)
        if source not in candidates:
            unresolved = True
            continue
        selected.append((period, source))
    if unresolved:
        return []
    segments = []
    for period, source in selected:
        if segments and segments[-1][-1][1] == source and segments[-1][-1][0] + 1 == period:
            segments[-1].append((period, source))
        else:
            segments.append([(period, source)])
    pieces, previous = [], 0
    for segment in segments:
        first, last, source = segment[0][0], segment[-1][0], segment[0][1]
        start, end = instant(day, table.periods[first - 1][0]), instant(day, table.periods[last - 1][1])
        reminder = max(start - lead * 60, previous)
        previous = end
        if end - reminder > EIGHT_HOURS:
            report["omitted"] += 1
            continue
        frames = [_frame(reminder, start, _ref(name, source, day, "upcoming", first, last, start, end))] if reminder < start else []
        frames += _class_frames(name, table, day, source, first, last, start, end, per_period)
        pieces.append(Piece(f"{name}:{source}:{day.isoformat()}:{first}:{last}", name, source, day, first, last, start, end, reminder, frames))
    return pieces


def _own_courses(table, day, per_period):
    """Every own course as its own interval. Forgiving like the client: conflicts
    are all kept (a class beats a break, then the earliest wins)."""
    courses, seen = [], set()
    for course in table.on(day):
        first, last = course["first"], course["last"]
        key = f"own:{course['id']}:{day.isoformat()}:{first}:{last}"
        if key in seen:
            continue
        seen.add(key)
        start, end = instant(day, table.periods[first - 1][0]), instant(day, table.periods[last - 1][1])
        if per_period and last > first:
            spans = []
            for number, a, b in _bells(table, day, first, last):
                if spans and spans[-1]["until"] < a:
                    spans.append({"from": spans[-1]["until"], "until": a, "ref": _ref("own", course["id"], day, "upcoming", number, number, a, b, pause=number)})
                spans.append({"from": a, "until": b, "ref": _ref("own", course["id"], day, "inProgress", first, last, a, b)})
        else:
            spans = [{"from": start, "until": end, "ref": _ref("own", course["id"], day, "inProgress", first, last, start, end)}]
        courses.append({"key": key, "course": course["id"], "first": first, "last": last, "start": start, "end": end, "spans": spans})
    return sorted(courses, key=lambda course: (course["start"], course["end"]))


def _lead_span(course, minutes, day):
    start = course["start"] - minutes * 60
    return {"from": start, "until": course["start"],
            "ref": _ref("own", course["course"], day, "upcoming", course["first"], course["last"], course["start"], course["end"])}


def _attach(spans, frames):
    """Split frames where an own course starts or ends; each part carries the
    own course running then (a class beats a break) as its companion."""
    result = []
    for frame in frames:
        overlapping = [span for span in spans if span["from"] < frame["until"] and span["until"] > frame["from"]]
        if not overlapping:
            result.append(frame)
            continue
        cuts = sorted({edge for span in overlapping for edge in (span["from"], span["until"]) if frame["from"] < edge < frame["until"]})
        edges = [frame["from"]] + cuts + [frame["until"]]
        for a, b in zip(edges, edges[1:]):
            covering = [span for span in overlapping if span["from"] <= a < span["until"]]
            active = next((span for span in covering if span["ref"]["phase"] == "inProgress"), covering[0] if covering else None)
            result.append(_frame(a, b, frame["lead"], active["ref"] if active else None))
    return result


def _overlay(candidates, start, until):
    """At every instant the first candidate covering it wins; equal neighbours join."""
    edges = sorted({edge for frame in candidates for edge in (frame["from"], frame["until"])} | {start, until})
    edges = [edge for edge in edges if start <= edge <= until]
    frames = []
    for a, b in zip(edges, edges[1:]):
        winner = next((frame for frame in candidates if frame["from"] <= a < frame["until"]), None)
        if winner is None:
            continue
        if frames and frames[-1]["until"] == a and (frames[-1]["lead"], frames[-1]["companion"]) == (winner["lead"], winner["companion"]):
            frames[-1]["until"] = b
        else:
            frames.append(_frame(a, b, winner["lead"], winner["companion"]))
    return frames


def refresh_at(occurrence):
    """When the display changes after it first renders: every frame start but
    the first, the end of a frame followed by a gap, and every reminder."""
    frames = occurrence["frames"]
    gaps = [a["until"] for a, b in zip(frames, frames[1:]) if a["until"] != b["from"]]
    stamps = {frame["from"] for frame in frames[1:]} | set(gaps) | set(occurrence["alertAt"])
    return sorted(stamp for stamp in stamps if stamp < occurrence["end"])


# MARK: Days

def build_day(device, day, own, share=None, settings=None, conflicts=None, now=0):
    """The occurrences of one day. `own` leads alone; with `share`, both tables
    remind and overlapping courses merge into one activity.

    Finished classes still take part in grouping, and only activities over by
    `now` are left out, so an occurrence keeps its id and frames whenever in
    the day it is computed."""
    settings, conflicts = settings or {}, conflicts or {}
    per_period = bool(settings.get("perPeriod"))
    own_lead = settings.get("leadMinutes", 60)
    report = {"conflicts": [], "omitted": 0}
    occurrences = []

    def emit(key, pieces, start, end, reminder, frames, alerts=()):
        chunks = []
        for frame in frames:
            if chunks and frame["until"] - chunks[-1][0]["from"] <= EIGHT_HOURS:
                chunks[-1].append(frame)
            else:
                chunks.append([frame])
        for index, chunk in enumerate(chunks):
            begin, until = chunk[0]["from"], chunk[-1]["until"]
            if until <= now:
                continue
            opening = pieces[0]
            occurrences.append({
                "occurrenceId": occurrence_id(device, key if index == 0 else f"{key}#{index}"),
                "dateKey": day.isoformat(), "start": start if index == 0 else begin, "end": until,
                "reminder": reminder if index == 0 else begin,
                "firstPeriod": opening.first, "lastPeriod": opening.last,
                "alertAt": sorted(stamp for stamp in alerts if begin < stamp < until)[:16], "frames": chunk,
                "overlaps": [(piece.table, piece.course, piece.start, piece.end) for piece in pieces]})

    if share is None:
        for piece in _lead_pieces("own", own, day, own_lead, per_period, conflicts, report):
            if piece.end > now:
                emit(piece.key, [piece], piece.start, piece.end, piece.reminder, piece.frames)
        return occurrences, report

    share_lead = settings.get("sharedLeadMinutes", own_lead)
    mine = _own_courses(own, day, per_period) if own is not None else []
    companions = []
    for course in mine:
        for span in [_lead_span(course, own_lead, day)] + course["spans"]:
            if span not in companions:
                companions.append(span)
    companions.sort(key=lambda span: (span["from"], span["until"]))
    pieces = _lead_pieces("share", share, day, share_lead, per_period, conflicts, report)
    for piece in pieces:
        piece.frames = _attach(companions, piece.frames)
    for course in mine:
        if course["end"] - course["start"] > EIGHT_HOURS:
            continue
        spans = [_lead_span(course, own_lead, day)] + course["spans"]
        pieces.append(Piece(course["key"], "own", course["course"], day, course["first"], course["last"],
                            course["start"], course["end"], course["start"] - own_lead * 60,
                            [_frame(span["from"], span["until"], span["ref"]) for span in spans], own=True))
    clusters = []
    for piece in sorted(pieces, key=lambda piece: (piece.start, 1 if piece.own else 0)):
        if clusters and piece.start < max(other.end for other in clusters[-1]):
            clusters[-1].append(piece)
        else:
            clusters.append([piece])
    previous = 0
    for cluster in clusters:
        start, end = min(piece.start for piece in cluster), max(piece.end for piece in cluster)
        # Each course reminds by its own table's lead; the cluster opens at the earliest.
        reminder = max(min(piece.reminder for piece in cluster), previous)
        previous = end
        shared = [frame for piece in cluster if not piece.own for frame in piece.frames]
        owned = sorted((frame for piece in cluster if piece.own for frame in piece.frames),
                       key=lambda frame: (0 if frame["lead"]["phase"] == "inProgress" else 1, frame["from"]))
        first = min(cluster, key=lambda piece: (piece.reminder, piece.start))
        fallback = [_frame(reminder, first.start, first.upcoming(reminder))] if reminder < first.start else []
        frames = _overlay(shared + owned + fallback, reminder, end)
        # Every course reminding later than the opening sounds its own reminder.
        joins = {max(piece.reminder, reminder) for piece in cluster} - {reminder}
        if end > now:
            emit(cluster[0].key, cluster, start, end, reminder, frames, joins)
    return occurrences, report


def conflicts_between(device, first, last, own, share=None, settings=None, conflicts=None, now=0):
    """Unresolved and resolved overlaps over a date range, for the settings page."""
    found, omitted, day = [], 0, first
    while day <= last and len(found) < 200:
        _, report = build_day(device, day, own, share, settings, conflicts, now)
        found += report["conflicts"]
        omitted += report["omitted"]
        day += timedelta(days=1)
    return found[:200], omitted

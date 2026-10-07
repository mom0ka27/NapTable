"""Allowlisted feature observations; durations use server time, never client clocks."""
import re
from datetime import datetime, timedelta

CATALOG = {
    "styles": {"style.minimal": "简约", "style.grid": "格子", "style.table": "表格",
               "style.paper": "素笺", "style.board": "站牌"},
    "features": {"background": "背景图", "separateBackgrounds": "深浅色独立背景图",
                 "widgetBackground": "小组件背景图", "liveActivity": "实时活动"},
    "widgets": {"widget.upcoming.small": "今日课程 · 小号", "widget.upcoming.medium": "今日课程 · 中号",
                "widget.upcoming.large": "今日课程 · 大号", "widget.upcoming.inline": "锁屏 · 行内",
                "widget.upcoming.circular": "锁屏 · 圆形", "widget.upcoming.rectangular": "锁屏 · 矩形",
                "widget.twoday.large": "两日课表 · 大号"},
}
KEYS = {key for group in CATALOG.values() for key in group}
SCHEMA = """
CREATE TABLE IF NOT EXISTS usage_features (
 installation_id TEXT NOT NULL, feature TEXT NOT NULL, session TEXT NOT NULL,
 first_seen TEXT NOT NULL, last_seen TEXT NOT NULL,
 PRIMARY KEY (installation_id, feature)
);
"""


def validate(value):
    if not isinstance(value, dict) or set(value) - KEYS:
        raise ValueError("invalid usageFeatures")
    for session in value.values():
        if not isinstance(session, str) or (session and not re.fullmatch(r"[a-f0-9]{32}", session)):
            raise ValueError("invalid feature session")
    if sum(bool(value.get(key)) for key in CATALOG["styles"]) > 1:
        raise ValueError("only one active style allowed")
    return value


def clean(db, stamp):
    db.execute("DELETE FROM usage_features WHERE last_seen<? OR installation_id NOT IN "
               "(SELECT installation_id FROM usage_devices)", ((stamp - timedelta(days=90)).isoformat(),))


def report(db, installation_id, value, stamp):
    if value is None:
        # Older clients cannot confirm the current feature state after a downgrade.
        db.execute("DELETE FROM usage_features WHERE installation_id=?", (installation_id,))
        return
    for key, session in value.items():
        if not session:
            db.execute("DELETE FROM usage_features WHERE installation_id=? AND feature=?", (installation_id, key))
            continue
        if key in CATALOG["styles"]:
            db.execute("DELETE FROM usage_features WHERE installation_id=? AND feature LIKE 'style.%' AND feature<>?",
                       (installation_id, key))
        db.execute("INSERT INTO usage_features VALUES (?,?,?,?,?) ON CONFLICT(installation_id,feature) "
                   "DO UPDATE SET first_seen=CASE WHEN session<>excluded.session OR last_seen<=? "
                   "THEN excluded.first_seen ELSE first_seen END, session=excluded.session,last_seen=excluded.last_seen",
                   (installation_id, key, session, stamp.isoformat(), stamp.isoformat(),
                    (stamp - timedelta(days=30)).isoformat()))


def summarize(rows):
    counts = {key: 0 for key in KEYS}
    observed = {key: 0 for key in KEYS}
    for row in rows:
        if row["feature"] not in KEYS:
            continue
        observed[row["feature"]] += 1
        if datetime.fromisoformat(row["last_seen"]) - datetime.fromisoformat(row["first_seen"]) > timedelta(days=1):
            counts[row["feature"]] += 1
    return {"minimumHours": 24, **{
        group: [{"id": key, "name": name, "users": counts[key], "observedUsers": observed[key]}
                for key, name in catalog.items()] for group, catalog in CATALOG.items()}}

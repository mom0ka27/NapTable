"""Small, versioned publication feed. Content is Markdown, never executable HTML."""
import math
import re
from urllib.parse import urlsplit


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,6}(?:\.[0-9]{1,6}){0,3}", value):
        raise ValueError("App 版本须为数字版本号，例如 1.2.0")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (4 - len(parts))


def validate(value):
    if not isinstance(value, dict) or type(value.get("revision")) is not int:
        raise ValueError("缺少配置版本，请重新加载")
    messages = value.get("messages")
    if not isinstance(messages, list) or len(messages) > 30:
        raise ValueError("最多保留 30 条更新与通知")
    result, ids = [], set()
    for item in messages:
        if not isinstance(item, dict):
            raise ValueError("通知格式无效")
        row = {}
        for key, limit in (("id", 80), ("kind", 10), ("platform", 10), ("title", 80),
                           ("subtitle", 160), ("body", 12000), ("version", 30),
                           ("minVersion", 30), ("maxVersion", 30), ("actionTitle", 30), ("actionURL", 2048)):
            text = item.get(key, "")
            if not isinstance(text, str) or len(text) > limit:
                raise ValueError(f"{key} 内容过长或格式无效")
            row[key] = text.strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", row["id"]) or row["id"] in ids:
            raise ValueError("通知 ID 无效或重复")
        ids.add(row["id"])
        if row["kind"] not in ("update", "notice") or row["platform"] not in ("all", "ios", "macos", "visionos"):
            raise ValueError("通知类型或平台无效")
        if not row["title"] or not row["body"]:
            raise ValueError("请填写标题和正文")
        if type(item.get("enabled")) is not bool:
            raise ValueError("发布状态无效")
        row["enabled"] = item["enabled"]
        for key in ("version", "minVersion", "maxVersion"):
            if row[key]: version(row[key])
        if row["minVersion"] and row["maxVersion"] and version(row["minVersion"]) > version(row["maxVersion"]):
            raise ValueError("最低适用版本不能高于最高适用版本")
        if row["actionURL"]:
            try:
                url = urlsplit(row["actionURL"])
                valid = url.scheme == "https" and url.hostname and not url.username and not url.password
            except ValueError:
                valid = False
            if not valid or any(c.isspace() or ord(c) < 32 for c in row["actionURL"]) or "\\" in row["actionURL"]:
                raise ValueError("跳转链接须为完整 HTTPS 地址")
        if row["kind"] == "update" and (not row["version"] or not row["actionURL"]):
            raise ValueError("更新提示须填写新版本号和更新链接")
        for key in ("startsAt", "endsAt"):
            stamp = item.get(key)
            if stamp is not None and (type(stamp) not in (int, float) or not math.isfinite(stamp) or not 0 <= stamp <= 253402300799):
                raise ValueError("生效时间无效")
            row[key] = stamp
        if row["startsAt"] is not None and row["endsAt"] is not None and row["startsAt"] >= row["endsAt"]:
            raise ValueError("结束时间必须晚于开始时间")
        result.append(row)
    return result


def active(item, now):
    return item["enabled"] and (item["startsAt"] is None or item["startsAt"] <= now) and (item["endsAt"] is None or now < item["endsAt"])

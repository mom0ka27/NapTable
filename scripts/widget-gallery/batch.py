#!/usr/bin/env python3
"""批量渲染所有小组件和实时活动的预览图，写一张总览页。

由 scripts/widget-gallery.sh --all 调用，画廊服务要先跑起来。只用标准库。

    --devices    pro（默认）、all，或逗号分隔：se,standard,pro,promax
    --schemes    light,dark（默认两个都出）
    --times      快捷时刻 id，逗号分隔；all（默认）
    --scenarios  课表场景 id，逗号分隔；默认 normal，all 是全部
    --widgets    只出这些：upcoming,today,twoday,activity（默认全部）
    --date       哪一天，YYYY-MM-DD；默认今天，周末换成下周一
    --zip        另外打一个 zip 发给别人：里面是离线版的画廊网页（单个 HTML，图片内嵌），
                 和原网页一样操作，只是只能在导出过的组合之间切换；解不解压都能直接打开
    --scale      出图倍数；默认按设备（多数是 3 倍），带 --zip 时默认 2 倍省体积
"""
import argparse
import base64
import hashlib
import html
import json
import os
import sys
import urllib.error
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

AFTER = [("nextCourseDay", "接着显示下一次课"), ("todayOnly", "只看今天")]
LAYOUTS = [("timeline", "时间线"), ("list", "列表")]


def fetch_json(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


def pick(value, available, default):
    if value is None:
        return default
    if value == "all":
        return available
    chosen = [v.strip() for v in value.split(",") if v.strip()]
    unknown = [v for v in chosen if v not in available]
    if unknown:
        sys.exit(f"不认识：{', '.join(unknown)}（可选 {', '.join(available)}）")
    return chosen


def intents(kind, family):
    """只展开这个画面「编辑小组件」里真有的选项。"""
    if kind == "twoday":
        return [({"layout": v}, t) for v, t in LAYOUTS]
    base = [({"afterClass": v}, t) for v, t in AFTER]
    if kind == "upcoming" and family == "systemSmall":
        return [({**job, "courseCount": c}, f"{t} · {'两节' if c == 2 else '一节'}") for job, t in base for c in (1, 2)]
    if kind == "today" and family == "systemLarge":
        return [({**job, "layout": v}, f"{t} · {lt}") for job, t in base for v, lt in LAYOUTS]
    return base


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default="http://127.0.0.1:8765")
    parser.add_argument("--out", required=True)
    parser.add_argument("--devices")
    parser.add_argument("--schemes")
    parser.add_argument("--times")
    parser.add_argument("--scenarios")
    parser.add_argument("--widgets")
    parser.add_argument("--date")
    parser.add_argument("--zip", help="zip 的输出路径")
    parser.add_argument("--scale", type=float)
    args = parser.parse_args()
    scale = args.scale or (2 if args.zip else None)

    meta = fetch_json(args.server + "/api/meta")
    families = {f["id"]: f["title"] for f in meta["families"]}
    devices = pick(args.devices, [d["id"] for d in meta["devices"]], ["pro"])
    schemes = pick(args.schemes, ["light", "dark"], ["light", "dark"])
    presets = {p["id"]: p for p in meta["timePresets"]}
    times = pick(args.times, list(presets), list(presets))
    scenarios = pick(args.scenarios, [s["id"] for s in meta["scenarios"]], ["normal"])
    kinds = pick(args.widgets, [w["kind"] for w in meta["widgets"]] + ["activity"],
                 [w["kind"] for w in meta["widgets"]] + ["activity"])
    device_titles = {d["id"]: d["title"] for d in meta["devices"]}
    scenario_titles = {s["id"]: s["title"] for s in meta["scenarios"]}
    date = args.date or meta["defaultDate"]

    # 分组：每个画面一组，组内按设置排开。
    groups = []
    for scenario in scenarios:
        for widget in meta["widgets"]:
            if widget["kind"] not in kinds:
                continue
            for family in widget["families"]:
                jobs = []
                for intent, intent_title in intents(widget["kind"], family):
                    for time_id in times:
                        for device in devices:
                            for scheme in schemes:
                                job = {"surface": "widget", "kind": widget["kind"], "family": family, "scenario": scenario,
                                       "date": date, "time": presets[time_id]["detail"], "scheme": scheme, "device": device, **intent}
                                label = [t for t in (intent_title, presets[time_id]["title"], "深色" if scheme == "dark" else "浅色") if t]
                                if len(devices) > 1:
                                    label.append(device_titles[device])
                                jobs.append((job, " · ".join(label)))
                title = f"{widget['title']} · {families[family]}"
                if len(scenarios) > 1:
                    title += f" · {scenario_titles[scenario]}"
                groups.append((title, f"{widget['kind']}-{family}-{scenario}", jobs))
        if "activity" in kinds:
            for part in meta["activityParts"]:
                jobs = []
                for time_id in times:
                    for device in devices:
                        for scheme in schemes:
                            job = {"surface": "activity", "activity": part["id"], "scenario": scenario, "date": date,
                                   "time": presets[time_id]["detail"], "scheme": scheme, "device": device}
                            label = [presets[time_id]["title"], "深色" if scheme == "dark" else "浅色"]
                            if len(devices) > 1:
                                label.append(device_titles[device])
                            jobs.append((job, " · ".join(label)))
                title = f"实时活动 · {part['title']}"
                if len(scenarios) > 1:
                    title += f" · {scenario_titles[scenario]}"
                groups.append((title, f"activity-{part['id']}-{scenario}", jobs))

    if scale:
        for _, _, jobs in groups:
            for job, _ in jobs:
                job["scale"] = scale

    os.makedirs(args.out, exist_ok=True)
    tasks = []
    for _, slug, jobs in groups:
        os.makedirs(os.path.join(args.out, slug), exist_ok=True)
        for index, (job, _) in enumerate(jobs):
            tasks.append((job, os.path.join(slug, f"{index:03d}-{job['scheme']}-{job['device']}-{job['time'].replace(':', '')}.png")))

    total = len(tasks)
    print(f"==> 共 {total} 张，输出到 {args.out}")
    failures = []

    def render(task):
        job, path = task
        url = args.server + "/api/render?j=" + base64.urlsafe_b64encode(json.dumps(job).encode()).decode().rstrip("=")
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
                width = float(response.headers.get("X-Point-Width", "0"))
            with open(os.path.join(args.out, path), "wb") as f:
                f.write(data)
            return path, width, None
        except urllib.error.HTTPError as error:
            return path, 0, error.read().decode(errors="replace")
        except Exception as error:  # noqa: BLE001
            return path, 0, str(error)

    widths = {}
    with ThreadPoolExecutor(max_workers=4) as pool:
        for count, (path, width, error) in enumerate(pool.map(render, tasks), 1):
            widths[path] = width
            if error:
                failures.append((path, error))
            if count % 20 == 0 or count == total:
                print(f"    {count}/{total}")

    write_index(args.out, groups, tasks, widths, date)
    print(f"==> 完成。总览：{os.path.join(args.out, 'index.html')}")
    if args.zip:
        write_zip(args.out, args.zip, meta, tasks, date, scale,
                  dims={"devices": devices, "schemes": schemes, "scenarios": scenarios,
                        "times": [presets[t]["detail"] for t in times]})
    if failures:
        print(f"!! {len(failures)} 张失败：")
        for path, error in failures[:10]:
            print(f"   {path}: {error}")
        sys.exit(1)


def stage(job):
    if job["surface"] == "activity":
        if job["activity"] == "lockScreen":
            return "home-dark" if job["scheme"] == "dark" else "home-light"
        return "lock"
    if job["family"].startswith("accessory"):
        return "lock"
    return "home-dark" if job["scheme"] == "dark" else "home-light"


# 离线版里固定住的设置：和画廊网页、batch 出图时的默认值一致。
OFFLINE_FIXED = {
    "theme": "bunny", "solid": False, "renderingMode": "auto", "state": "loaded",
    "tableName": "", "sourceLabel": "", "persistent": False, "companion": False, "payload": None,
    "display": {k: True for k in ("showCourseName", "showRoom", "showTeacher", "showTime", "showLunarDate", "showHoliday")},
}


def layout_of(job):
    """有「显示方式」的画面才有值；没选就是这个小组件的默认。和 web/index.html 的 layoutOf 一致。"""
    if job.get("kind") == "twoday":
        return job.get("layout") or "list"
    if job.get("kind") == "today" and job.get("family") == "systemLarge":
        return job.get("layout") or "timeline"
    return None


def offline_key(job):
    """和 web/index.html 的 offlineKey 一一对应。"""
    intent = ""
    if job["surface"] == "widget":
        if job["kind"] == "twoday":
            intent = layout_of(job)
        elif job["kind"] == "upcoming" and job["family"] == "systemSmall":
            intent = f"{job['afterClass']}/{job['courseCount']}"
        elif layout_of(job):
            intent = f"{job['afterClass']}/{layout_of(job)}"
        else:
            intent = job["afterClass"]
    return "|".join([job["surface"], job.get("kind") or job.get("activity"), job.get("family", ""), intent,
                     job["scheme"], job["time"], job["device"], job["scenario"]])


def write_zip(out, zip_path, meta, tasks, date, scale, dims):
    """离线版画廊：原网页加一段内嵌数据，图片去重后转 base64。解不解压都能直接打开。"""
    images, seen, index = [], {}, {}
    for job, path in tasks:
        full = os.path.join(out, path)
        if not os.path.exists(full):
            continue
        with open(full, "rb") as f:
            data = f.read()
        digest = hashlib.sha1(data).hexdigest()
        if digest not in seen:
            seen[digest] = len(images)
            images.append(base64.b64encode(data).decode())
        index[offline_key(job)] = seen[digest]

    offline = {"meta": meta, "dims": dims, "scale": scale, "date": date, "fixed": OFFLINE_FIXED,
               "index": index, "images": images}
    payload = json.dumps(offline, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "web", "index.html"), encoding="utf-8") as f:
        page = f.read()
    marker = "<script>"
    assert page.count(marker) == 1, "web/index.html 里应该只有一个 <script>"
    page = page.replace(marker, f"<script>window.GALLERY_OFFLINE = {payload};</script>\n{marker}")

    # 文件名用英文：中文名在一些解压工具（尤其是旧版 Windows）里会乱码。
    name = f"NapTable-widgets-{date}.html"
    os.makedirs(os.path.dirname(os.path.abspath(zip_path)), exist_ok=True)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(name, page)
    size = os.path.getsize(zip_path) / 1024 / 1024
    print(f"==> 已打包：{zip_path}（{size:.1f} MB，{len(index)} 种组合、{len(images)} 张不重复的图；"
          f"里面是「{name}」，双击就能看）")


def write_index(out, groups, tasks, widths, date):
    page = render_page(groups, tasks, widths, date, source=lambda path: path)
    with open(os.path.join(out, "index.html"), "w", encoding="utf-8") as f:
        f.write(page)


def render_page(groups, tasks, widths, date, source):
    paths = iter(path for _, path in tasks)
    sections = []
    for title, _, jobs in groups:
        cards = []
        for job, label in jobs:
            path = next(paths)
            width = widths.get(path) or 0
            style = f' style="width:{width:.0f}px"' if width else ""
            cards.append(
                f'<figure><div class="stage {stage(job)}"><img src="{html.escape(source(path))}"{style} loading="lazy"></div>'
                f"<figcaption>{html.escape(label)}</figcaption></figure>"
            )
        sections.append(f"<section><h2>{html.escape(title)}</h2><div class=\"cards\">{''.join(cards)}</div></section>")
    page = f"""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>NapTable 小组件全部模式</title>
<style>
body{{margin:0;padding:20px;font:13px/1.45 -apple-system,"PingFang SC",sans-serif;background:#f4f5f7;color:#1d1f24}}
h1{{font-size:17px;margin:0 0 4px}} .sub{{color:#6b7079;margin-bottom:20px}}
h2{{font-size:13px;color:#6b7079;margin:26px 0 10px}}
.cards{{display:flex;flex-wrap:wrap;gap:14px;align-items:flex-start}}
figure{{margin:0;background:#fff;border:1px solid #e3e5e9;border-radius:12px;overflow:hidden}}
figcaption{{padding:6px 10px;font-size:11.5px;color:#6b7079}}
.stage{{padding:16px;display:flex;justify-content:center;align-items:center}}
.stage img{{display:block}}
.home-light{{background:linear-gradient(160deg,#cfe3f5,#f3d9e4 55%,#f7ecd6)}}
.home-dark{{background:linear-gradient(160deg,#1b2440,#3a2446 55%,#1d2b36)}}
.lock{{background:linear-gradient(170deg,#3b4d74,#6b4f7a 60%,#2c3550)}}
</style></head><body>
<h1>NapTable 小组件全部模式</h1>
<div class="sub">日期 {html.escape(date)} · 共 {len(tasks)} 张 · scripts/widget-gallery.sh --all 生成</div>
{''.join(sections)}
</body></html>"""
    return page


if __name__ == "__main__":
    main()

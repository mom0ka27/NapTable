#!/bin/bash
# 小组件和实时活动的视图只能从 WidgetClock.now 读「现在」、从 scheduleWidgetFamily 读尺寸，
# 预览画廊（scripts/widget-gallery.sh）才能把时刻和尺寸钉住。直接用 Date() / .now /
# \.widgetFamily 的地方会让画廊里的图和设置对不上。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

# 允许的例外：时间线本身（什么时候刷新看真实时间）、彩炮按下的时间（和时间线的真实时间比）、
# 占位条目、ScheduleWidgetRoot 转存系统尺寸。
allow='ScheduleTimeline\.make\(now: \.now\)|set\(Date\(\), forKey: Self\.firedAtKey\)|:\s*date: \.now,$|private var systemFamily|widgetFamily` 只读|系统给的 `widgetFamily`|When\(widgetFamily:|Use the content.s stable origin'

hits="$(grep -nE 'Date\(\)|Date\.now|[(: ]\.now\b|\\\.widgetFamily' \
    NapTableWidgets/ScheduleWidgets.swift NapTableWidgets/ScheduleWidgetIntents.swift WidgetCore/WidgetScheduleModels.swift \
    | grep -vE "$allow" || true)"

if [ -n "$hits" ]; then
    echo "视图代码里直接读了系统时间或尺寸，改用 WidgetClock.now / \\.scheduleWidgetFamily："
    echo "$hits"
    exit 1
fi
echo "widget clock checks passed"

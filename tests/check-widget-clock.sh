#!/bin/bash
# 小组件的视图只能从 \.scheduleWidgetNow（ScheduleWidgetRoot 放进去的 entry.date）读「现在」、
# 从 scheduleWidgetFamily 读尺寸。时间线一次排好一整天的条目，系统提前把每一条画好：
# 直接用 Date() / .now / WidgetClock.now 会让每一条都画成生成时间线的那一刻；预览画廊
#（scripts/widget-gallery.sh）也是靠条目的日期和 familyOverride 钉住时刻和尺寸。
# 实时活动的视图不在时间线里，照旧读 WidgetClock.now（画廊用 override 钉住）。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

files=(
    NapTableWidgets/ScheduleWidgets.swift
    NapTableWidgets/ScheduleWidgetIntents.swift
    WidgetCore/WidgetScheduleModels.swift
    WidgetCore/ChineseCalendar.swift
)

# 系统时间和系统尺寸。允许的例外：时间线本身（看真实时间）、彩炮按下的时间（和时间线的真实时间比）、
# ScheduleWidgetRoot 转存系统尺寸。
allow='ScheduleTimeline\.make\(now: \.now\)|set\(Date\(\), forKey: Self\.firedAtKey\)|private var systemFamily|widgetFamily` 只读|系统给的 `widgetFamily`|When\(widgetFamily:|Use the content.s stable origin'

hits="$(grep -nE 'Date\(\)|Date\.now|[(: ]\.now\b|\\\.widgetFamily' "${files[@]}" | grep -vE "$allow" || true)"
if [ -n "$hits" ]; then
    echo "视图代码里直接读了系统时间或尺寸，改用 \\.scheduleWidgetNow / \\.scheduleWidgetFamily："
    echo "$hits"
    exit 1
fi

# WidgetClock.now 只留给实时活动、占位条目、环境值的缺省值和坏日期的退路；小组件视图要读 \.scheduleWidgetNow。
clock_allow='resolveStored\(attributes: attributes, at: WidgetClock\.now\)|localState\.endDate <= WidgetClock\.now|max\(broadcastTimestamp, WidgetClock\.now\)|placeholder\(at: WidgetClock\.now\)|defaultValue: Date \{ WidgetClock\.now \}|func brokenDateFallback'

clock_hits="$(grep -nE 'WidgetClock\.now' "${files[@]}" | grep -vE "$clock_allow" || true)"
if [ -n "$clock_hits" ]; then
    echo "小组件视图读了 WidgetClock.now，多条时间线条目会画成同一刻，改用 @Environment(\\.scheduleWidgetNow)："
    echo "$clock_hits"
    exit 1
fi
echo "widget clock checks passed"

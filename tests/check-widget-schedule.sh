#!/bin/bash
# 小组件数据模型：寒暑假、课表过期、时间线条目。只编译 WidgetCore，不需要模拟器。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/naptable-widget-schedule-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 5 \
    "$repo_dir/WidgetCore/ChineseCalendar.swift" \
    "$repo_dir/WidgetCore/WidgetConfiguration.swift" \
    "$repo_dir/WidgetCore/WidgetScheduleModels.swift" \
    "$repo_dir/WidgetCore/WidgetClock.swift" \
    "$repo_dir/tests/WidgetScheduleChecks.swift" \
    -o "$check_dir/checks"
"$check_dir/checks"

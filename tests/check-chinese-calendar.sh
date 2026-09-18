#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/naptable-chinese-calendar-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 5 \
    "$repo_dir/WidgetCore/ChineseCalendar.swift" \
    "$repo_dir/WidgetCore/WidgetConfiguration.swift" \
    "$repo_dir/WidgetCore/WidgetScheduleModels.swift" \
    "$repo_dir/tests/ChineseCalendarChecks.swift" \
    -o "$check_dir/checks"
"$check_dir/checks"

#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/naptable-live-activity-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 5 -emit-library -emit-module -module-name ActivityKit \
    "$repo_dir/tests/fixtures/ActivityKit.swift" \
    -o "$check_dir/libActivityKit.dylib" -emit-module-path "$check_dir/ActivityKit.swiftmodule"
swiftc -swift-version 5 -D LIVE_ACTIVITY_CHECKS -I "$check_dir" -L "$check_dir" -lActivityKit \
    -Xlinker -rpath -Xlinker "$check_dir" \
    "$repo_dir/NapTable/Models/PrivacyConsent.swift" \
    "$repo_dir/NapTable/Models/Course.swift" \
    "$repo_dir/NapTable/Utils/WeekCalculator.swift" \
    "$repo_dir/NapTable/Models/CalendarAdjustment.swift" \
    "$repo_dir/NapTable/Schedule/ScheduleModels.swift" \
    "$repo_dir/NapTable/Schedule/ScheduleSnapshot.swift" \
    "$repo_dir/WidgetCore/ScheduleLiveActivityAttributes.swift" \
    "$repo_dir/WidgetCore/LiveActivityV2.swift" \
    "$repo_dir/NapTable/Schedule/LiveActivityTimeline.swift" \
    "$repo_dir/NapTable/Schedule/NativeLiveActivityController.swift" \
    "$repo_dir/tests/NativeLiveActivityChecks.swift" \
    -o "$check_dir/checks"
"$check_dir/checks" "$repo_dir/tests/fixtures/live-activity-v2.json"

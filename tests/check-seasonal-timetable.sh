#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/naptable-seasonal-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
cd "$repo_dir"
swiftc -swift-version 5 -emit-library -emit-module -module-name ActivityKit \
    tests/fixtures/ActivityKit.swift -o "$check_dir/libActivityKit.dylib" \
    -emit-module-path "$check_dir/ActivityKit.swiftmodule"
swiftc -swift-version 5 -parse-as-library -D LIVE_ACTIVITY_CHECKS \
    -I "$check_dir" -L "$check_dir" -lActivityKit -Xlinker -rpath -Xlinker "$check_dir" \
    NapTable/Models/*.swift NapTable/Utils/*.swift NapTable/Views/ScheduleLayout.swift \
    NapTable/Schedule/SchedulePreferences.swift NapTable/Import/ImportedSchedule.swift \
    NapTable/Support/BundledConfig.swift NapTable/Support/PlatformCompat.swift \
    NapTable/Schedule/ScheduleModels.swift NapTable/Schedule/ScheduleStore.swift \
    NapTable/Schedule/ScheduleSnapshot.swift NapTable/Schedule/NativeWidgetSettings.swift \
    NapTable/Schedule/LiveActivityTimeline.swift NapTable/Schedule/NativeLiveActivityController.swift \
    NapTable/Schedule/ScheduleICSExport.swift WidgetCore/*.swift \
    tests/SeasonalTimetableChecks.swift -o "$check_dir/checks"
"$check_dir/checks" "$repo_dir/tests/fixtures/xjtu-seasonal-times.json"

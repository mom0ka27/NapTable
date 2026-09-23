#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/naptable-onboarding-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
cd "$repo_dir"
swiftc -swift-version 5 -parse-as-library \
    NapTable/Models/*.swift \
    NapTable/Utils/*.swift \
    NapTable/Views/ScheduleLayout.swift \
    NapTable/Schedule/SchedulePreferences.swift \
    NapTable/Import/ImportedSchedule.swift \
    NapTable/Support/BundledConfig.swift \
    NapTable/Support/PlatformCompat.swift \
    NapTable/Schedule/ScheduleModels.swift \
    NapTable/Schedule/ScheduleStore.swift \
    NapTable/Schedule/ScheduleSnapshot.swift \
    NapTable/Schedule/NativeWidgetSettings.swift \
    WidgetCore/*.swift \
    tests/OnboardingChecks.swift -o "$check_dir/checks"
"$check_dir/checks"

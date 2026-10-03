#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/naptable-web-import-retry-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 5 -parse-as-library \
    "$repo_dir/NapTable/Models/Course.swift" \
    "$repo_dir/NapTable/Models/CalendarAdjustment.swift" \
    "$repo_dir/NapTable/Utils/WeekCalculator.swift" \
    "$repo_dir/NapTable/Import/ImportedSchedule.swift" \
    "$repo_dir/NapTable/Import/RucLoginFlow.swift" \
    "$repo_dir/tests/WebImportRetryChecks.swift" \
    -o "$check_dir/checks"
"$check_dir/checks"

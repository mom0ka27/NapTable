#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/naptable-course-html-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 5 -parse-as-library \
    "$repo_dir/NapTable/Models/Course.swift" \
    "$repo_dir/NapTable/Models/CalendarAdjustment.swift" \
    "$repo_dir/NapTable/Utils/WeekCalculator.swift" \
    "$repo_dir/NapTable/Import/LightHTML.swift" \
    "$repo_dir/NapTable/Import/CourseHTMLParser.swift" \
    "$repo_dir/tests/CourseHTMLParserChecks.swift" \
    -o "$check_dir/checks"
"$check_dir/checks"

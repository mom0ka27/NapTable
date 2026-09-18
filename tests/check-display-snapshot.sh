#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/naptable-display-snapshot-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 5 \
    "$repo_dir/NapTable/Schedule/SchedulePreferences.swift" \
    "$repo_dir/tests/DisplaySnapshotChecks.swift" \
    -o "$check_dir/checks"
"$check_dir/checks"

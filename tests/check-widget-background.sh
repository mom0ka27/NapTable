#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/naptable-widget-background-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 5 \
    "$repo_dir/WidgetCore/WidgetBackground.swift" \
    "$repo_dir/tests/WidgetBackgroundChecks.swift" \
    -o "$check_dir/checks"
"$check_dir/checks"

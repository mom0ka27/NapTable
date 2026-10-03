#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/naptable-purchase-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 5 -parse-as-library \
    "$repo_dir/NapTable/Models/PurchaseManager.swift" \
    "$repo_dir/tests/PurchaseManagerChecks.swift" -o "$check_dir/checks"
"$check_dir/checks"

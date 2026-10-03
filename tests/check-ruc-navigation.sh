#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/naptable-ruc-navigation-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
python3 - "$repo_dir" "$check_dir" <<'PY'
import pathlib, sys
source = (pathlib.Path(sys.argv[1]) / "NapTable/Import/WebImporterView.swift").read_text()
coordinator = source[source.index("nonisolated enum WebImportState:"):]
(pathlib.Path(sys.argv[2]) / "Coordinator.swift").write_text("import SwiftUI\nimport WebKit\n" + coordinator)
PY
swiftc -swift-version 5 -parse-as-library \
    "$repo_dir/NapTable/Models/Course.swift" \
    "$repo_dir/NapTable/Models/CalendarAdjustment.swift" \
    "$repo_dir/NapTable/Utils/WeekCalculator.swift" \
    "$repo_dir/NapTable/Import/ImportedSchedule.swift" \
    "$repo_dir/NapTable/Import/RucLoginFlow.swift" \
    "$check_dir/Coordinator.swift" \
    "$repo_dir/tests/RucNavigationChecks.swift" \
    -o "$check_dir/checks"
"$check_dir/checks"

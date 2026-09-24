#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
node "$repo_dir/tests/SysuExtractorChecks.mjs"

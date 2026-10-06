#!/bin/bash
# App 的强调色是用户选的主题色，由 MyApp 在根部用 `.appThemeTint` 统一挂上。
# `Color.accentColor` 不跟 `.tint` 走，工程也没配全局强调色，它在 App 里显示成系统蓝；
# 改用 `.tint` 形状样式（`.foregroundStyle(.tint)`、`.fill(.tint)` 等）或环境里的主题色。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

hits="$(grep -rnI 'accentColor' NapTable || true)"
if [ -n "$hits" ]; then
    echo "NapTable/ 里用了 accentColor，它不跟主题色走，改用 .tint 或环境里的主题色："
    echo "$hits"
    exit 1
fi
echo "accent color checks passed"

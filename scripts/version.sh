#!/bin/bash
# 用法：
#   scripts/version.sh          查询当前 version 与 build
#   scripts/version.sh 1.2.0    设置 version，并把 build 自动 +1
set -euo pipefail

PBXPROJ="$(cd "$(dirname "$0")/.." && pwd)/NapTable.xcodeproj/project.pbxproj"

# 读取某个构建设置在 pbxproj 中的所有取值（去重）
read_setting() {
  grep -E "^[[:space:]]*$1 = " "$PBXPROJ" | sed -E "s/.*$1 = \"?([^\";]*)\"?;.*/\1/" | sort -u
}

single_value() {
  local values count
  values="$(read_setting "$1")"
  count="$(printf '%s\n' "$values" | grep -c . || true)"
  if [[ "$count" -ne 1 ]]; then
    echo "错误：$1 在各 target/配置中不一致或缺失：" >&2
    printf '  %s\n' $values >&2
    exit 1
  fi
  printf '%s' "$values"
}

version="$(single_value MARKETING_VERSION)"
build="$(single_value CURRENT_PROJECT_VERSION)"

if [[ $# -eq 0 ]]; then
  echo "version: $version"
  echo "build:   $build"
  exit 0
fi

if [[ $# -gt 1 ]]; then
  echo "用法：$0 [新版本号]" >&2
  exit 1
fi

new_version="$1"
if ! [[ "$new_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "错误：版本号格式应为 X、X.Y 或 X.Y.Z，收到：$new_version" >&2
  exit 1
fi
if ! [[ "$build" =~ ^[0-9]+$ ]]; then
  echo "错误：当前 build 不是整数：$build" >&2
  exit 1
fi
new_build=$((build + 1))

sed -i '' -E \
  -e "s/(MARKETING_VERSION = )[^;]*;/\1$new_version;/" \
  -e "s/(CURRENT_PROJECT_VERSION = )[^;]*;/\1$new_build;/" \
  "$PBXPROJ"

echo "version: $version -> $new_version"
echo "build:   $build -> $new_build"

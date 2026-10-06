#!/bin/zsh
set -euo pipefail

# 真实 NapTable Debug App 的 5 × 2 × 3 截图集。每次运行只使用本脚本创建的模拟器，
# 串行重启 App，等 Demo 的缓存就绪标记后再截图；不读取或修改用户课表。
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
timestamp="$(date +%Y%m%d-%H%M%S)"
run_tag="${timestamp}-$$"
out_dir="/tmp/naptable-style-gallery-$run_tag"
derived_dir="${TMPDIR:-/tmp}/naptable-schedule-style-gallery-$run_tag"
device_name="NapTable Style Gallery $run_tag"
bundle_id="com.niyiwei.naptable"
scheme="NapTable"
runtime="${NAPTABLE_STYLE_GALLERY_RUNTIME:-}"
device_type="${NAPTABLE_STYLE_GALLERY_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-16}"
udid=""
keep_device=0
build_only=0

usage() {
    cat <<'EOF'
用法：scripts/schedule-style-gallery.sh [--out DIR] [--build-only] [--keep-device]

默认生成 30 张真实 App 截图和 index.html。NAPTABLE_STYLE_GALLERY_RUNTIME 与
NAPTABLE_STYLE_GALLERY_DEVICE_TYPE 可覆盖专用模拟器的 runtime / device type。
EOF
}

while (( $# )); do
    case "$1" in
        --out)
            if (( $# < 2 )); then print -u2 '--out 需要目录'; exit 2; fi
            out_dir="$2"; shift 2 ;;
        --build-only) build_only=1; shift ;;
        --keep-device) keep_device=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) print -u2 "未知参数：$1"; usage >&2; exit 2 ;;
    esac
done

if [[ "$build_only" -eq 0 && -z "$runtime" ]]; then
    runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
items = [r for r in json.load(sys.stdin)["runtimes"]
         if r.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
         and r.get("isAvailable", False)]
if not items: raise SystemExit("没有可用的 iOS Simulator runtime")
print(sorted(items, key=lambda r: tuple(int(x) for x in r["version"].split(".")))[-1]["identifier"])
')"
fi

cleanup() {
    if [[ "$keep_device" -eq 0 && -n "$udid" ]]; then
        xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
        xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 防止第二次运行混入旧图，已有非空输出目录直接报错。
if [[ -d "$out_dir" && -n "$(ls -A "$out_dir")" ]]; then
    print -u2 "输出目录非空，请换一个目录：$out_dir"
    exit 2
fi
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
echo "==> 独立构建：$derived_dir"
if ! xcodebuild \
    -project "$repo_dir/NapTable.xcodeproj" \
    -scheme "$scheme" \
    -sdk iphonesimulator \
    -configuration Debug \
    -derivedDataPath "$derived_dir" \
    -destination "generic/platform=iOS Simulator" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$out_dir/build.log" 2>&1; then
    tail -n 60 "$out_dir/build.log" >&2
    print -u2 "构建失败，完整日志：$out_dir/build.log"
    exit 1
fi

if [[ "$build_only" -eq 1 ]]; then
    echo "已编译：$derived_dir/Build/Products/Debug-iphonesimulator/NapTable.app"
    exit 0
fi

echo "==> 创建专用模拟器：$device_name"
udid="$(xcrun simctl create "$device_name" "$device_type" "$runtime")"
echo "专用模拟器 UDID：$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$derived_dir/Build/Products/Debug-iphonesimulator/NapTable.app"
xcrun simctl status_bar "$udid" override --time 11:05 --batteryLevel 100 --batteryState charged \
    --wifiBars 3 --cellularBars 4 --operatorName "" >/dev/null 2>&1 || true

# Caches 在 data container 中，不在只读的 .app bundle 中。
container="$(xcrun simctl get_app_container "$udid" "$bundle_id" data)"
cache_dir="$container/Library/Caches"
marker="$cache_dir/schedule-style-demo-ready.json"
mkdir -p "$out_dir"

typeset -a styles=(minimal grid table paper board)
typeset -a views=(week day month)
typeset -a themes=(light dark)
count=0

for style in $styles; do
    for theme in $themes; do
        dark=0
        [[ "$theme" == dark ]] && dark=1
        for view in $views; do
            (( count += 1 ))
            name="${style}-${view}-${theme}.png"
            run_id="${run_tag}-${count}-${style}-${view}-${theme}"
            # run ID 每次唯一，无须删除旧标记；匹配失败就继续等待当前进程。
            xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
            SIMCTL_CHILD_NAPTABLE_STYLE_DEMO=1 \
            SIMCTL_CHILD_NAPTABLE_DEMO_STYLE="$style" \
            SIMCTL_CHILD_NAPTABLE_DEMO_VIEW="$view" \
            SIMCTL_CHILD_NAPTABLE_DEMO_DARK="$dark" \
            SIMCTL_CHILD_NAPTABLE_DEMO_RUN_ID="$run_id" \
                xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" >/dev/null

            ready=0
            for attempt in {1..80}; do
                if [[ -f "$marker" ]] && python3 - "$marker" "$run_id" "$style" "$view" "$dark" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as stream:
        marker = json.load(stream)
    expected = dict(zip(("runID", "style", "view", "dark"), sys.argv[2:]))
    raise SystemExit(0 if all(marker.get(k) == v for k, v in expected.items()) else 1)
except (OSError, ValueError):
    raise SystemExit(1)
PY
                then
                    ready=1
                    break
                fi
                sleep 0.25
            done
            if [[ "$ready" -ne 1 ]]; then
                echo "Demo 未就绪：$style / $view / $theme" >&2
                exit 1
            fi
            sleep 0.35
            xcrun simctl io "$udid" screenshot "$out_dir/$name" >/dev/null
            [[ -s "$out_dir/$name" ]] || { print -u2 "截图为空：$name"; exit 1; }
            echo "[$count/30] $name"
        done
    done
done

cat > "$out_dir/index.html" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>NapTable schedule style gallery $timestamp</title>
<style>
body { margin: 24px; font: 15px -apple-system, BlinkMacSystemFont, sans-serif; background: #f2f2f7; color: #1c1c1e; }
h1 { font-size: 24px; } h2 { margin-top: 28px; }
section { display: grid; grid-template-columns: repeat(3, minmax(220px, 1fr)); gap: 14px; }
figure { margin: 0; padding: 10px; background: white; border-radius: 14px; box-shadow: 0 2px 8px #0001; }
figure.dark { background: #2c2c2e; color: #fff; } img { width: 100%; display: block; border-radius: 9px; }
figcaption { padding: 8px 2px 0; } code { font-size: 12px; }
</style>
<h1>NapTable schedule style gallery</h1>
<p>固定示例：2027-04-07 11:05；真实 SwiftUI 组件；共 30 张。</p>
EOF
for style in $styles; do
    print -r -- "<h2>$style</h2><section>" >> "$out_dir/index.html"
    for theme in $themes; do
        for view in $views; do
            name="${style}-${view}-${theme}.png"
            if [[ "$theme" == dark ]]; then
                print -r -- "<figure class=dark>" >> "$out_dir/index.html"
            else
                print -r -- "<figure>" >> "$out_dir/index.html"
            fi
            print -r -- "<a href=\"$name\"><img src=\"$name\" alt=\"$style $view $theme\" loading=\"lazy\"></a><figcaption><code>$name</code></figcaption></figure>" >> "$out_dir/index.html"
        done
    done
    print -r -- "</section>" >> "$out_dir/index.html"
done

cat > "$out_dir/run.txt" <<EOF
device=$device_name
udid=$udid
runtime=$runtime
device_type=$device_type
derived_data=$derived_dir
fixture=1
date=2027-04-07T11:05:00+08:00
count=$count
EOF
if [[ "$keep_device" -eq 1 ]]; then
    echo "保留专用模拟器：$udid（用 xcrun simctl shutdown/delete 此 UDID 清理）"
fi
echo "已生成：$out_dir"
echo "索引：$out_dir/index.html"

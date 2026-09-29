#!/bin/bash
# NapTable 小组件 / 实时活动预览画廊。
#
#   scripts/widget-gallery.sh              编译、装进专用模拟器、打开网页
#   scripts/widget-gallery.sh --all [目录] 批量渲染所有模式（默认 build/widget-gallery/）
#   scripts/widget-gallery.sh --zip        批量渲染并打包成 build/widget-gallery.zip，发给别人双击就能看
#       可加 --devices all|se,pro  --schemes light,dark  --times all|inClass,...
#            --scenarios all|normal,...  --widgets upcoming,twoday,activity  --date YYYY-MM-DD
#   scripts/widget-gallery.sh --build      只编译
#   scripts/widget-gallery.sh --web        只把改过的网页同步进已安装的画廊，刷新浏览器即可
#   scripts/widget-gallery.sh --stop       关掉画廊用的模拟器
#
# 环境变量：GALLERY_PORT（默认 8765）、GALLERY_RUNTIME（模拟器系统，默认最新 iOS）
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
src_dir="$repo_dir/scripts/widget-gallery"
build_dir="$repo_dir/build/widget-gallery-app"
app="$build_dir/WidgetGallery.app"
bundle_id="com.niyiwei.naptable.widgetgallery"
device_name="NapTable Widget Gallery"
port="${GALLERY_PORT:-8765}"

mode="open"
out_dir="$repo_dir/build/widget-gallery"
batch_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --all) mode="all"; if [ $# -gt 1 ] && [[ "$2" != --* ]]; then out_dir="$2"; shift; fi ;;
        --zip) mode="all"; batch_args+=("--zip" "${out_dir}.zip") ;;
        --build) mode="build" ;;
        --stop) mode="stop" ;;
        --web) mode="web" ;;
        --no-open) mode="serve" ;;
        --devices|--schemes|--times|--scenarios|--widgets|--date) batch_args+=("$1" "$2"); shift ;;
        -h|--help) sed -n 2,14p "$0"; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
    shift
done

find_device() {
    xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name and d.get("isAvailable", True):
            print(d["udid"]); sys.exit()
' "$device_name"
}

if [ "$mode" = "stop" ]; then
    udid="$(find_device)"
    [ -n "$udid" ] && xcrun simctl shutdown "$udid" 2>/dev/null || true
    echo "已关闭画廊模拟器"
    exit 0
fi

if [ "$mode" = "web" ]; then
    udid="$(find_device)"
    container="$( [ -n "$udid" ] && xcrun simctl get_app_container "$udid" "$bundle_id" app 2>/dev/null || true)"
    [ -n "$container" ] || { echo "画廊还没装，先运行 scripts/widget-gallery.sh" >&2; exit 1; }
    cp "$src_dir/web/index.html" "$container/index.html"
    echo "网页已同步，刷新浏览器即可"
    exit 0
fi

build() {
    echo "==> 编译画廊 App"
    rm -rf "$app"
    mkdir -p "$app"
    local arch
    arch="$(uname -m)"
    [ "$arch" = "arm64" ] || arch="x86_64"
    xcrun -sdk iphonesimulator swiftc \
        -target "$arch-apple-ios18.0-simulator" \
        -swift-version 5 \
        -default-isolation MainActor \
        -enable-upcoming-feature InferIsolatedConformances \
        -enable-upcoming-feature NonisolatedNonsendingByDefault \
        -D WIDGET_GALLERY -D DEBUG -Onone -suppress-warnings \
        -module-name WidgetGallery \
        "$repo_dir"/WidgetCore/*.swift \
        "$repo_dir"/NapTableWidgets/*.swift \
        "$src_dir"/*.swift \
        -o "$app/WidgetGallery"
    xcrun actool "$repo_dir/NapTableWidgets/Assets.xcassets" \
        --compile "$app" --platform iphonesimulator --minimum-deployment-target 18.0 \
        --target-device iphone --output-format human-readable-text \
        --output-partial-info-plist "$build_dir/assets-info.plist" >/dev/null
    cp "$src_dir/web/index.html" "$app/index.html"
    cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleExecutable</key><string>WidgetGallery</string>
    <key>CFBundleName</key><string>WidgetGallery</string>
    <key>CFBundleDisplayName</key><string>小组件画廊</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>MinimumOSVersion</key><string>18.0</string>
    <key>UIDeviceFamily</key><array><integer>1</integer></array>
    <key>UILaunchScreen</key><dict/>
    <key>CPUAppGroupIdentifier</key><string>group.com.niyiwei.naptable.gallery</string>
</dict>
</plist>
PLIST
    codesign --force --sign - "$app" >/dev/null 2>&1
}

build
[ "$mode" = "build" ] && { echo "已编译：$app"; exit 0; }

echo "==> 准备模拟器「${device_name}」"
udid="$(find_device)"
if [ -z "$udid" ]; then
    runtime="${GALLERY_RUNTIME:-$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(sorted(rs, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"])')}"
    devtype="$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
import re
# 挑最新一代带灵动岛的 Pro（不要 Max），按名字里的代数排，别依赖列表顺序。
ts = [t for t in json.load(sys.stdin)["devicetypes"] if re.fullmatch(r"iPhone \d+ Pro", t["name"])]
print(max(ts, key=lambda t: int(re.search(r"\d+", t["name"]).group()))["identifier"])')"
    udid="$(xcrun simctl create "$device_name" "$devtype" "$runtime")"
fi
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
SIMCTL_CHILD_GALLERY_PORT="$port" xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" \
    --web-root "$src_dir/web" >/dev/null

echo -n "==> 等待画廊服务"
for _ in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:$port/api/health" >/dev/null; then echo " 就绪"; break; fi
    echo -n "."; sleep 0.5
done
curl -sf "http://127.0.0.1:$port/api/health" >/dev/null || { echo; echo "画廊服务没起来" >&2; exit 1; }

case "$mode" in
    open)
        open "http://127.0.0.1:$port"
        echo "网页：http://127.0.0.1:$port（模拟器在后台运行，用 --stop 关闭）" ;;
    serve)
        echo "网页：http://127.0.0.1:$port" ;;
    all)
        python3 "$src_dir/batch.py" --server "http://127.0.0.1:$port" --out "$out_dir" "${batch_args[@]+"${batch_args[@]}"}" ;;
esac

# 开发与构建

## 项目结构

| 路径 | 用途 |
| --- | --- |
| `NapTable/` | App 本体，包括导入、数据模型、课表视图和设置页 |
| `WidgetCore/` | App 与小组件共用的 payload、主题、显示选项和 Live Activity model |
| `NapTableWidgets/` | 小组件扩展 target，包括临近课程、今日课表、两日课表和实时活动 |
| `server/` | Python（FastAPI + uvicorn）+ SQLite 服务端，负责学校配置、分享和可选推送调度 |
| `tests/` | Swift 模型检查和 Python 服务端测试 |
| `Config/` | App 与扩展的 Info.plist、entitlements 和构建配置 |

`WidgetCore` 同时属于 App 与扩展，`NapTableWidgets` 只属于扩展。这样扩展不会把 App 的视图代码编译进去。

## 平台与最低版本

| 平台 | 最低版本 |
| --- | --- |
| iOS / iPadOS | 17.0 |
| macOS | 14.0 |
| visionOS | 2.0 |
| 小组件扩展 | iOS 17.0 |

Live Activity 本身需要 iOS 16.1+，当前 iOS 部署目标为 17.0。iOS、macOS 和 visionOS 的差异通过条件编译和可用性判断收口；修改跨平台代码时，应保留这些平台边界。

## Bundle ID 与 App Group

| 项 | 值 |
| --- | --- |
| App bundle id | `me.mom0ka27.naptable` |
| 小组件扩展 bundle id | `me.mom0ka27.naptable.widgets` |
| App Group | `group.me.mom0ka27.naptable` |
| 回跳 URL scheme | `naptable://schedule` |

App 与扩展通过 App Group 共享课表 payload、主题和实时活动设置。修改 Team 或 bundle 前缀时，优先修改构建设置中的 `CPU_APP_GROUP_IDENTIFIER` 和 `PRODUCT_BUNDLE_IDENTIFIER`，同时检查 Info.plist 的 URL 配置。

App Group 只有在签名构建中才会分配共享容器。使用 `CODE_SIGNING_ALLOWED=NO` 构建时，小组件显示「等待课表同步」属于预期行为。

## 构建

在 Xcode 中打开 `NapTable.xcodeproj`，可以直接运行 `NapTable` 或 `NapTableWidgets` scheme。命令行构建示例：

```sh
xcodebuild -project NapTable.xcodeproj -scheme NapTable \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/dd \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project NapTable.xcodeproj -scheme NapTable \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/dd-mac \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project NapTable.xcodeproj -scheme NapTableWidgets \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/dd \
  CODE_SIGNING_ALLOWED=NO build
```

若要验证签名 App Group，可使用已启动的 iOS 模拟器执行：

```sh
xcodebuild -project NapTable.xcodeproj -scheme NapTable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/dd-signed build

xcrun simctl install booted .build/dd-signed/Build/Products/Debug-iphonesimulator/NapTable.app
xcrun simctl launch booted me.mom0ka27.naptable
xcrun simctl get_app_container booted me.mom0ka27.naptable groups
```

## 测试与验证

Swift 模型、实时活动和导入检查（`tests/check-*.sh`；`check-sysu-extractor.sh` 用 Node 运行中山大学导入脚本）：

```sh
for script in tests/check-*.sh; do bash "$script" || break; done
```

服务端测试需先安装 `server/requirements.txt`（FastAPI、uvicorn 和加密依赖；`deploy/deploy.sh` 发布前也用本机 `python3` 跑这些测试）：

```sh
python3 -m pip install -r server/requirements.txt
python3 -m unittest discover -s tests -p 'test_*.py'
```

Debug 模拟器可以通过环境变量直接打开指定入口：

- `SIMCTL_CHILD_NAPTABLE_DEBUG_SHEET=editor|weekPicker|free|detail`

## 小组件预览画廊

`scripts/widget-gallery.sh` 把小组件和实时活动的正式视图代码编进一个只在模拟器里跑的 App（不进 Xcode 工程），在网页里改设置、实时出图：

```sh
scripts/widget-gallery.sh              # 编译、装进专用模拟器「NapTable Widget Gallery」、打开 http://localhost:8765
scripts/widget-gallery.sh --all        # 批量出所有模式到 build/widget-gallery/，附 index.html 总览
scripts/widget-gallery.sh --all --devices all --scenarios all   # 再按设备、课表场景展开
scripts/widget-gallery.sh --zip        # 导出离线版画廊 build/widget-gallery.zip：和网页一样操作，只能在导出过的组合间切换，发给别人双击就能看
scripts/widget-gallery.sh --stop       # 关掉画廊用的模拟器
```

- 改了 `scripts/widget-gallery/web/index.html` 后运行 `scripts/widget-gallery.sh --web` 同步进模拟器，刷新浏览器即可，不用重新编译；改 Swift 要重跑脚本。（仓库在「文稿」里时模拟器进程读不到源文件，网页取的是装进 App 的那份。）
- 小组件视图里的「现在」从 `\.scheduleWidgetNow`（`ScheduleWidgetRoot` 放进环境的 `entry.date`）读，尺寸从 `\.scheduleWidgetFamily` 读：时间线一次排好一整天的条目，每条要按自己的日期画，画廊也是靠条目的日期钉住时刻。实时活动的视图照旧读 `WidgetClock.now`（画廊用 `override` 钉住）。`tests/check-widget-clock.sh` 会拦住直接用 `Date()` / `WidgetClock.now` / `\.widgetFamily` 的写法。
- 离线版默认只带「普通一周」课表和 iPhone 18 Pro，约 3 MB；加 `--scenarios all` 约 12 MB，再加 `--devices all` 约 47 MB。主题色、显示开关等在离线版里固定为默认值。
- 系统外观是画廊补画的：小组件背景和圆角、16pt 内边距、锁屏圆形底、染色桌面与锁屏半透明效果、灵动岛外形都是近似值，灵动岛的边距尤其只是经验值。iPhone 18 系列的小组件尺寸不在 Apple 公布的表里，按屏宽推算。

## 跨平台注意事项

- `NativeLiveActivityController.swift` 和 `WidgetCore/ScheduleLiveActivityAttributes.swift` 的 ActivityKit 代码只在 iOS 编译。
- `ScheduleGlass.swift` 的新系统材质判断需要同时考虑操作系统，而不是只判断 iOS 版本。
- `NativeWidgetSettings.swift` 在 visionOS 上使用统一的时间线刷新入口，并遵守对应系统版本可用性。
- visionOS 没有 `UIScreen`，生成分享图时不要直接读取屏幕 scale。

更具体的服务端开发、APNs 配置和 API 示例见 [`server/README.md`](../server/README.md)。

课程实时活动采用 v2：服务端按上传的课表计算提醒并远程启动；iOS 18 远程启动，iOS 26 及以上本地预约最近几节、其余远程启动，iOS 17 只保留预览。协议、加密依赖与验收见 [live-activity-v2.md](live-activity-v2.md)，设计取舍见 [server-scheduled-reminders.md](server-scheduled-reminders.md)。

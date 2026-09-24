# 开发与构建

## 项目结构

| 路径 | 用途 |
| --- | --- |
| `NapTable/` | App 本体，包括导入、数据模型、课表视图和设置页 |
| `WidgetCore/` | App 与小组件共用的 payload、主题、显示选项和 Live Activity model |
| `NapTableWidgets/` | 小组件扩展 target，包括临近课程、今日课表、两日课表和实时活动 |
| `server/` | Python 标准库 + SQLite 服务端，负责学校配置、分享和可选推送调度 |
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

Swift 模型和实时活动检查：

```sh
bash tests/check-live-activity.sh
bash tests/check-chinese-calendar.sh
bash tests/check-calendar-adjustment.sh
bash tests/check-sharing.sh
bash tests/check-import-conflicts.sh
```

服务端测试：

```sh
python3 -m unittest tests.test_term_authority tests.test_shares tests.test_server \
  tests.test_live_activity tests.test_apns
```

Debug 模拟器可以通过环境变量直接打开指定入口：

- `SIMCTL_CHILD_NAPTABLE_DEBUG_SHEET=editor|weekPicker|free|detail`

## 跨平台注意事项

- `NativeLiveActivityController.swift` 和 `WidgetCore/ScheduleLiveActivityAttributes.swift` 的 ActivityKit 代码只在 iOS 编译。
- `ScheduleGlass.swift` 的新系统材质判断需要同时考虑操作系统，而不是只判断 iOS 版本。
- `NativeWidgetSettings.swift` 在 visionOS 上使用统一的时间线刷新入口，并遵守对应系统版本可用性。
- visionOS 没有 `UIScreen`，生成分享图时不要直接读取屏幕 scale。

更具体的服务端开发、APNs 配置和 API 示例见 [`server/README.md`](../server/README.md)。

课程实时活动采用 v2：iOS 26 本地逐课程预约（关心共享课表时改为远程启动），iOS 18 远程启动，iOS 17 前台本地能力。协议、加密依赖、模式交接与验收见 [live-activity-v2.md](live-activity-v2.md)。

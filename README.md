# NapTable（我上早八）

## 许可证

本项目自身的源代码以 GNU Affero General Public License v3.0 或更高版本（AGPL-3.0-or-later）发布，完整协议见根目录的 [LICENSE](LICENSE)。除非另有说明，项目中的源代码、脚本和配置文档均适用该许可证。

项目包含来自其他开源项目的移植或改编内容。第三方版权、来源、许可证和适用范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；其中上游 `NJU-Class-Shedule-Flutter` 使用的 Apache License 2.0 原文保存在 [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt)。第三方代码的原有许可证不因本项目采用 AGPL-3.0 而被替换。

多平台课表客户端（iOS / iPadOS / macOS / visionOS），课表界面移植自同源的
`../CPU-Web/ios_next`（CpuTime）原生端。本地数据由 `NapTable/Models/AppStore`
持有，不发网络请求；课表数据来自文件导入或网页导入。

## 目录

| 路径 | 说明 |
| --- | --- |
| `NapTable/` | App 本体（Xcode 26+ 同步文件夹，新增文件自动入 target） |
| `NapTable/Schedule/ScheduleSurfaceView.swift` | 课表界面，对齐 CpuTime 4.0：原生分页器、顶部溢出菜单、图片分享、ICS 导出 |
| `NapTable/Schedule/ScheduleMonthView.swift` | 月视图日历：公历 + 农历/节日 + 每天课程圆点，下方是所选那天的课程清单 |
| `NapTable/Schedule/SchedulePreferences.swift` | 课表显示偏好（背景图、配色、密度、默认视图），存 `UserDefaults` |
| `NapTable/Models/CalendarAdjustment.swift` | 调休：按日期覆盖课表的「放假 / 上哪天的课」，由服务端学期配置下发 |
| `WidgetCore/ChineseCalendar.swift` | 农历换算、传统节日与法定假期，App 与小组件共用 |
| `NapTable/Schedule/NativeWidgetSettings.swift` | 把本地课表投影成小组件 payload 写入 App Group |
| `NapTable/Schedule/NativeLiveActivityController.swift` | 灵动岛课程实时活动（仅 iOS），并把接下来一周渲染成推送计划 |
| `NapTable/Schedule/LiveActivityPushService.swift` | push-to-start：上报令牌、上传计划，让实时活动不打开 App 也能启动 |
| `server/apns.py` | 只用标准库的 APNs 客户端：ES256 签名、HPACK、HTTP/2 帧层 |
| `server/live_activity.py` | 设备注册、推送计划存储与到点调度 |
| `NapTable/Views/DeviceSettingsView.swift` | 「课表与设备设置」页：对齐 CpuTime 4.2，课表 / 小组件 / 实时活动独立子页及演示入口 |
| `WidgetCore/` | App 与小组件扩展共用的模型：payload、主题、显示选项、Live Activity attributes |
| `NapTableWidgets/` | 小组件扩展 target（`NapTableWidgets.appex`）：临近课程、今日课表、两日课表、实时活动 |
| `Config/` | App 与扩展的 Info.plist / entitlements |

`WidgetCore` 与 `NapTableWidgets` 是两个顶层同步文件夹：前者同时属于 App 与扩展，
后者只属于扩展，因此扩展不会把 App 的视图代码编进去。

## 课表视图

顶栏的视图切换是「日 / 周 / 月」三档，都在同一个课表界面里，共用学期选择、溢出菜单和课程编辑弹窗：

- 日 / 周仍是按节次画的课表网格，横向分页翻天、翻周。
- 月视图是一张日历而不是网格：每格显示公历日、农历（或当天的节日、法定假期）和最多三个课程圆点，圆点颜色与课程卡片同源；左侧窄栏是教学周序号，学期之外的日期不显示周次也没有课程。点某天会在下方列出当天课程（点课程进编辑弹窗），「日视图」按钮切到日视图并自动跳到对应教学周。
- 「默认视图」设置新增「月历」，顶栏的定位按钮在月视图里是「回到本月」。
- 调休按**日期**覆盖：补班那天画的是「上哪一天的课」那一天的课（跨周也对），放假那天不画课。周视图的日期下面、月视图格子右上角有「班」「休」角标，周 / 日视图顶部列出当周受影响的日子。在补班那天点课程或长按空格，存的是被补的那一天，不会把课挪到周六。

## 农历与节假日

`WidgetCore/ChineseCalendar.swift` 用 Foundation 自带的农历（`Calendar(identifier: .chinese)`）换算农历日期、干支和生肖，在此之上推导节日与法定假期，全部离线计算并按公历年缓存：

- 农历节日：春节、除夕（跟着腊月大小月走，不写死腊月三十）、元宵、龙抬头、端午、七夕、中元、中秋、重阳、腊八、小年；公历节日：元旦、妇女节、植树节、劳动节、青年节、儿童节、建党节、建军节、教师节、国庆节、圣诞节。
- 法定假期按《全国年节及纪念日放假办法》（2024 年修订）推导：元旦 1 天、春节自除夕起 4 天、清明 1 天、劳动节 2 天、端午 1 天、中秋 1 天、国庆 3 天。这里**不包含**各年度国务院通知里的调休连休与补班安排——那部分每年单独公布，走服务端的学期配置（`adjustments`），见下面的「调休」。所以日期栏的节日徽标和课表里的调休是两件事：前者只认固定规则，后者才改课。
- 二十四节气只计算清明（用于清明假期），清明日期用 2020—2043 有效的四年周期规则，再往后需要按天文历重新校正。
- 小组件设置里「农历日期」「节假日提示」「最近节假日常驻」控制小组件日期栏的显示，默认全开；月视图的农历和节日始终显示。
- 常驻开启时，「距中秋节 7 天」单独占日期栏下面一行，右端和上一行的「第 N 周」对齐（两日课表的窄列除外），查未来 120 天。这一行只报天数，天数单独加粗上色；只差一两天时改说「明天就是中秋节」「后天就是中秋节」。假期日期（「9.25 周五」「10.1 - 10.3 · 休 3 天」）只在课后那张假期大字卡片上显示；卡片出现时日期栏这一行自动让开，不重复；关掉后只有今日课表在临近假期（30 天内）时显示。当天本身是节日时，日期栏右侧的节日徽标接管提示。
- 日期栏排版：大号日期 │ 竖排星期 │ 竖排农历（或窄组件里的节日），两条竖线分隔。
- 假期数据也用于小组件的课后提示（见下）：今天课上完后可以显示最近一段法定假期。

## 小组件与实时活动

## 服务端分享与学校配置

服务端位于 [server/naptable_server.py](/Users/Jerry/Documents/Project/NapTable/server/naptable_server.py)，仅使用 Python 标准库和 SQLite：

```sh
python3 server/naptable_server.py --host 0.0.0.0 --port 8787 --db naptable.sqlite3
```

学校学期、第一周日期、总周数和节次由服务端管理员统一配置，客户端在从对应学校导入课表时自动匹配并应用，无需单独选择或同步模板。配置按服务地址缓存供离线使用；已绑定课表不再开放本地修改时间。管理员操作见 [服务端配置说明](server/README.md)。客户端也可生成持久化分享码或读取他人的课表，服务端保存所选学期的版本快照。分享写入权限通过一次性返回的 `writeToken` 保护，读取分享码不需要登录。分享携带的是**发布时那所学校那个学期的完整时间配置**——节次时间、第一周周一、总周数和调休，所以跨学校读一张课表不需要本机有对方学校的配置，也不会套用自己的作息。「设为提示来源」之后，小组件和灵动岛渲染的就是对方那张课表和对方学校的时间，主界面课表不受影响；App 回到前台时按 `/meta` 判断是否需要重新下载。管理员修正某个学校的作息不会动已发出的分享，需要分享者在「同步校历时间」里确认。内置 NJU 是可校准模板，不代表南京大学当前官方校历；请按实际校历修正后再使用。

真机局域网使用：让 Mac 与 iPhone/iPad 连接同一个可信 Wi-Fi，在 Mac 上用 `ifconfig` 找到局域网地址（例如 `192.168.1.23`），启动时绑定 `0.0.0.0`，然后在 App 的服务地址填写 `http://192.168.1.23:8787`。只应在可信局域网使用；服务默认无 TLS，分享内容会经过网络传输，公网部署前必须加 HTTPS、访问认证和防火墙规则。

- 小组件不访问网络：App 的 `NativeWidgetSettings` 把当前课表编码成
  `WidgetSchedulePayload` 写入 App Group 的 `UserDefaults`
  （`naptable.scheduleWidgetPayload`），扩展每 30 分钟读一次；此外还会在今天下一个课程边界（上课/下课那一分钟）额外安排一次刷新，下课后不用等满半小时才切换内容。
- 主题与显示选项共用 CpuTime 的键：`scheduleWidgetTheme`、
  `scheduleWidgetDisplayOptions`。
- 实时活动在 iOS 上跟随课表变化刷新；下一节课进入「提前显示」窗口才出现，下课即收起。提前量在设置页可选 15 分钟 / 30 分钟 / 1 小时 / 2 小时 / 3 小时，默认 1 小时，存在 App Group 的 `scheduleLiveActivityLeadMinutes`。提前量比课间还长时，课间也会直接接上下一节课，「全天常驻」的区别就只剩更长的空档和当天课程全部结束之后。
- 设置页「课间也保留」开启后，课间保留实时活动并倒计时到今天的下一节课；今天没有课程后自动收起（明天的课程交给小组件）。它只管「课间不收起」：今天第一节课还没开始时，同样要等课程进入「提前显示」窗口才出现，不会一大早就挂着晚上的课。
- 实时活动只显示今天的课：「下一节」一栏只认同一天的课程，跨天的那节交给小组件；今天的课全部上完后状态是「今日无课」，不会提前一晚预告明天的课。
- 到达下课时间时，实时活动自身会被系统标记为过期（`staleDate` = 本节课结束）。常驻模式下这一帧改为显示今天下一节课的倒计时；今天还有课但这一节已结束显示「已下课」，今天没课了显示「今日无课」，等 App 或后台任务把它收起。小组件扩展通过 App Group 里的 `scheduleLiveActivityPersistent` 判断当前模式。
- 下课时若 App 已被系统挂起，`LiveActivityBackgroundRefresh` 会用 `BGTaskScheduler` 在课程边界唤醒 App 收起（常驻模式下改为切到下一节）；系统决定具体执行时机，关闭「后台 App 刷新」时退回到下次打开 App 时收起。
- 实时活动默认必须打开一次 App 才会出现：iOS 不允许后台调用 `Activity.request`。设置页的「由服务端推送启动」打开后改走 iOS 17.2 的 push-to-start：`NativeLiveActivityController.pushPlan(from:)` 把接下来一周的每一帧渲染成一份计划（`start` / `update` / `end` 各带时刻），`LiveActivityPushService` 上传给服务端，到点由服务端经 APNs 推送启动，不需要先打开 App。内容仍由 App 渲染，服务端只做定时与转发，所以推来的那一帧和本地刷新出来的完全一致。需要服务端配置 APNs 密钥，见 [服务端说明](server/README.md)；没配置或关掉时行为回到上一条。
- `ContentState` 的时间字段显式编码成 Unix 秒而不是 `Date`：推送里的 `content-state` 由 ActivityKit 自己的 `JSONDecoder` 解码，App 无从配置它的日期策略，写明就不用赌。
- 实时活动与灵动岛布局同步 CpuTime 4.2（build 51）；设置页可启动本地演示，iOS 18 起支持 Watch 小尺寸镜像。真实课程时间始终读取当前课表的节次配置。
- 小组件只展示当天课程，不会中途滚到明天。今天的课全部上完后，设置页「今天课程结束后」决定那块位置显示什么：
  - `今天没有课程`：保持原样（今日课表仍列出已结束的课程，灰显）。
  - `明天的课程`（默认）：列出明天的课并整体灰显；明天也没课时自动退回假期提示。
  - `最近的节假日`：显示「距国庆节还有 12 天」和假期日期区间。
  锁屏的「临近课程」也按同一设置换掉那一行。两日课表本来就带明天，不受影响。
- payload 里除了当前周还带下一周（`nextWeekDays`），所以周日晚上的「明天」能落到下一周的周一。
- 小组件/实时活动点击回跳 `naptable://schedule`。

### Bundle ID 与 App Group

App 与扩展的 bundle id 已统一到 `me.mom0ka27`：

| 项 | 值 |
| --- | --- |
| App bundle id | `me.mom0ka27.naptable` |
| 小组件扩展 bundle id | `me.mom0ka27.naptable.widgets` |
| App Group | `group.me.mom0ka27.naptable` |
| 回跳 URL scheme | `naptable://schedule` |

扩展 id 是 App id 加 `.widgets` 后缀，App Group 名称也是由 App id 加 `group.`
前缀得到。两处都通过 `CPU_APP_GROUP_IDENTIFIER` / `PRODUCT_BUNDLE_IDENTIFIER`
构建设置下发，改 Team 或改前缀时只需改这两个设置（以及 Info.plist 里的
`CFBundleURLName`），不需要动代码。

## 部署目标

| 平台 | 最低版本 |
| --- | --- |
| iOS / iPadOS | 17.0 |
| macOS | 14.0 |
| visionOS | 2.0 |
| 小组件扩展 | iOS 17.0 |

Live Activity 需要 iOS 16.1+，低于上表下限，因此在 iOS 上按 17.0 起步时无需再判断。
新系统的能力都走可用性降级，不抬高最低版本：

- **iOS 26+**：底部/头部圆形控件使用原生 Liquid Glass；低于 26 或开启「减弱透明度」
  时回落到自绘的半透明材质（`ScheduleGlass.swift` 的 `legacyMaterial`）。
- **visionOS 26+**：才会调用 `WidgetCenter` 刷新时间线。
- 其余界面（原生分页器、溢出菜单、图片分享、ICS 导出、小组件、实时活动）在
  17.0 / 14.0 / 2.0 上都是完整功能。

手头只有 iOS 27 模拟器运行时，所以 17.0 只验证到「编译通过 + 高版本运行正常」，
真机 iOS 17 的实际观感建议再跑一次。

App Group 在**签名**构建下才真正分配。验证方式（模拟器即可）：

```sh
xcodebuild -project NapTable.xcodeproj -scheme NapTable \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/dd-signed build        # 不加 CODE_SIGNING_ALLOWED=NO

xcrun simctl install booted .build/dd-signed/Build/Products/Debug-iphonesimulator/NapTable.app
xcrun simctl launch booted me.mom0ka27.naptable
xcrun simctl get_app_container booted me.mom0ka27.naptable groups
# → group.me.mom0ka27.naptable  <共享容器路径>
```

用 `CODE_SIGNING_ALLOWED=NO` 构建时不会分配共享容器（`UserDefaults(suiteName:)`
退回应用私有 Preferences），此时小组件显示「等待课表同步」，属预期现象。

## 跨平台注意

App 同时构建 iOS / macOS / visionOS，而 Live Activity 与部分小组件 API 只存在于
iOS，相关判断都按平台收口，改这几处时不要退化成只判断 iOS 版本的写法：

- `NativeLiveActivityController.swift`、`WidgetCore/ScheduleLiveActivityAttributes.swift`：
  整体包在 `#if os(iOS)` 里。注意 `canImport(ActivityKit)` 在 macOS SDK 上为真但
  API 被标记为不可用，不能用它做判断。
- `ScheduleGlass.swift`：`glassEffect` 的平台判断必须是 `#if os(iOS)`（macOS 部署
  目标低于 26.0，仅写 `#available(iOS 26.0, *)` 会让 macOS 构建失败）。
- `NativeWidgetSettings.swift`：`WidgetCenter` 在 visionOS 需要 26.0，统一走
  `reloadScheduleWidgetTimelines()`。
- `PlatformCompat.swift`：visionOS 没有 `UIScreen`，渲染分享图时不要取它的 scale。

## 构建与验证

已适配 CPU-web iOS 4.4（`d4655a9`）的实时活动生命周期修复、课表菜单位置与小组件日期显示。实时活动回到前台时会重新校准，临时启动失败后会重试，清除数据会丢弃旧课表快照。

实时活动回归检查使用隔离的偏好存储和内存 ActivityKit 替身，覆盖课程边界、自动重试、权限变化、常驻与课间倒计时、数据清除和预览取消（约 35 秒）：

```sh
bash tests/check-live-activity.sh
```

农历换算、节日与法定假期区间，以及小组件 payload 的「明天」查找（含跨周、旧 payload 兼容）的校验（秒级，只编译 `WidgetCore`）：

```sh
bash tests/check-chinese-calendar.sh
```

调休解析（补班改上哪天的课、跨周调课、缺学期锚点、旧存档兼容）的校验（秒级，只编译模型层）：

```sh
bash tests/check-calendar-adjustment.sh
```

服务端（含调休配置的存取、校验与分享快照）：

```sh
python3 -m unittest tests.test_term_authority tests.test_shares tests.test_server \
  tests.test_live_activity tests.test_apns
```

```sh
xcodebuild -project NapTable.xcodeproj -scheme NapTable \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/dd \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project NapTable.xcodeproj -scheme NapTable \
  -destination 'generic/platform=macOS' -derivedDataPath .build/dd-mac \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project NapTable.xcodeproj -scheme NapTableWidgets \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/dd \
  CODE_SIGNING_ALLOWED=NO build
```

模拟器里的调试入口（仅 Debug）：

- `SIMCTL_CHILD_NAPTABLE_DEBUG_SHEET=editor|weekPicker|free|detail`：打开课表的某个弹层；
- `SIMCTL_CHILD_NAPTABLE_DEBUG_DEVICE=1`：直接打开「课表与设备设置」。

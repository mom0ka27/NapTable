# ScheduleStyle Debug 截图演示

`NapTable/Schedule/ScheduleStyleDemo.swift` 是 Debug 专用的 `ScheduleStyleDemoRoot: View`。它直接调用现有的 `NativeScheduleDayColumn`、`NativeScheduleDayTimeline` 与 `NativeScheduleMonthView`，日视图上方是正式的星期条 `ScheduleDayStrip`。此视图只使用内存里的固定示例课表，不创建 `AppStore` 或 `NativeScheduleStore`，也不调用课表或偏好的持久化方法。

`MyApp` 已将 `AppStore()` 放入只在正常启动使用的 `NormalAppRoot`，所以 `NAPTABLE_STYLE_DEMO=1` 的 Demo 分支不会构造 `AppStore`。`NativeThemeSettings.shared` 仍由根部读取主题设置，Demo 只读取其风格环境所需的主题单例状态；Demo 不调用主题、课表或用户偏好的写入方法。购买、推送和实时活动启动也已在 Demo 模式跳过。脚本通过新建专用模拟器运行，避免接触已有模拟器的用户课表。

`MyApp` 在 `NAPTABLE_STYLE_DEMO=1` 时已经切到这个入口，并跳过购买、推送和实时活动启动。Demo 的固定时间是 2027-04-07 11:05，日期为第 7 周 4 月 5–11 日；周视图、日视图、月视图共享同一组示例课程。

环境变量如下：

```text
NAPTABLE_STYLE_DEMO=1
NAPTABLE_DEMO_STYLE=minimal|grid|table|paper|board
NAPTABLE_DEMO_VIEW=week|day|month
NAPTABLE_DEMO_DARK=0|1
NAPTABLE_DEMO_TIME=HH:MM|none
```

`NAPTABLE_DEMO_TIME` 只影响日视图，用来看课间、全天结束这些状态：写一个时刻就把它当作“现在”，写 `none` 则当作不是今天。星期条始终选中周三；写 `none` 时今天挪到周二，选中和今天两种标记可以同时看到。不设时沿用 11:05；批量截图脚本不设这个变量。

先只验证构建：

```sh
scripts/schedule-style-gallery.sh --build-only
```

生成完整截图矩阵。脚本会自己创建并清理一个唯一命名的 iOS Simulator，按顺序生成 30 张图，不使用当前用户模拟器：

```sh
scripts/schedule-style-gallery.sh
```

输出目录默认为 `/tmp/naptable-style-gallery-YYYYMMDD-HHMMSS-PID/`，内含 30 张 PNG、`index.html`、`build.log` 和记录 runtime、设备、独立构建路径的 `run.txt`，不会在工作区产生未跟踪截图。文件名为 `<style>-<view>-<light|dark>.png`。非空输出目录会被拒绝，避免混入旧图。也可以指定一个新的目录：

```sh
scripts/schedule-style-gallery.sh --out /tmp/naptable-style-gallery
```

脚本默认使用已安装的最新 iOS runtime 和 iPhone 16（393×852 pt）。需要 Xcode 命令行工具、对应的模拟器 runtime、zsh 和 Python 3。`NAPTABLE_STYLE_GALLERY_RUNTIME` 和 `NAPTABLE_STYLE_GALLERY_DEVICE_TYPE` 可覆盖专用模拟器的 runtime 与设备类型；`--keep-device` 用于保留本次专用模拟器进行调试。模拟器由 `simctl create` 新建，脚本不接受用户设备 UDID，也不会使用 `booted` 或批量关闭其他设备。正常结束、失败或中断只清理本次创建的设备；强制杀进程后可按本次输出的 UDID 手动清理。

构建产物放在 `$TMPDIR/naptable-schedule-style-gallery-YYYYMMDD-HHMMSS-PID/`，不复用 Xcode 或其他 agent 的 DerivedData。脚本每次重启 App，等待 data container 中的 `Library/Caches/schedule-style-demo-ready.json` 与当前组合及 run ID 全部匹配，再截图。此文件只记录截图状态；Demo 样本课程、休／班和时间只在内存中使用，不写入课表。月历的农历缓存会在首帧之前预热。

这是组件演示，不包含正式课表页的全部导航、编辑和主视图私有装饰；它如实反映真实组件当前已实现的风格。周视图仅组合真实日列、节次轴与公共表面；日视图的状态计算固定传入 665 分钟；月视图选中 4 月 7 日且今天固定为同一天。示例休／班不代表官方假期安排。扩展的冲突课程、大字号、背景图片等验收需要另外增加样本。

Demo 不调用 `NativeThemeSettings` 的持久化方法。现有课程卡片仍会读取该单例的课程配色偏好，因此手动在已有安装上运行可能受旧配色影响；批量脚本使用新建模拟器，所有组合都从同一份空白偏好开始。普通课表、简约卡片及专业版卡片的实现没有为 Demo 改写。

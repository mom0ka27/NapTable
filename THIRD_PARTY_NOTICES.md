# 第三方代码与资源声明

本文件用于区分 NapTable 自身代码和第三方项目的移植、改编或数据资源。除下列明确列出的内容外，仓库中的原创代码按根目录 [LICENSE](LICENSE) 采用 AGPL-3.0-or-later 发布。

## 南哪课表 / NJU-Class-Shedule-Flutter

- 项目：<https://github.com/WheretoSleepinNJU/NJU-Class-Shedule-Flutter>
- 上游许可证：Apache License 2.0
- 许可证原文：[`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt)
- 上游许可证文件：<https://github.com/WheretoSleepinNJU/NJU-Class-Shedule-Flutter/blob/master/LICENSE>

NapTable 的以下部分包含对该项目数据格式、导入流程、学校导入器或资源快照的移植、改编或兼容实现：

- `NapTable/Import/ImportedSchedule.swift`
- `NapTable/Import/ImportPipeline.swift`
- `NapTable/Import/WebImporterView.swift`
- `NapTable/Import/SchoolCatalog.swift` 中对应的学校导入器和提取脚本
- `NapTable/Models/Course.swift`
- `NapTable/Models/ScheduleLogic.swift`
- `NapTable/Models/AppSettings.swift`
- `NapTable/Utils/CourseColor.swift`
- `NapTable/Resources/complete.json`
- `NapTable/Support/BundledConfig.swift` 中对 `complete.json` 的兼容加载逻辑

上述内容保留上游项目的来源和许可证义务；NapTable 对这些内容所作的新增、修改和围绕它们编写的独立代码，仍需同时遵守适用的 Apache License 2.0 条款以及本项目对原创部分作出的 AGPL-3.0-or-later 声明。若无法将某个文件或片段明确区分，应以其原始来源文件和许可证为准，不应仅因为仓库根目录存在 AGPL-3.0 就把第三方内容重新标为 AGPL-3.0。

## CpuTime / CPU-web

NapTable 的课表界面和部分小组件/实时活动实现还注明移植自 `CPU-web`：

- 项目：<https://github.com/sx120609/CPU-web>
- NapTable 中的来源说明见 `README.md`、`WidgetCore/`、`NapTable/Schedule/` 和相关 Swift 文件注释。

截至 2026 年 9 月 18 日，`CPU-web` 当前 `main` 分支 README 将代码许可证声明为 `AGPL-3.0-or-later`。NapTable 对其中移植内容按该许可证保留来源和许可证义务；根目录 [LICENSE](LICENSE) 提供对应的 AGPL v3 正文。`CPU-web` README 同时明确品牌、官方构建、在线服务、生产资源和第三方素材不包含在代码许可中，NapTable 不会将这些内容一并再分发。

## sysukcb

- 项目：<https://github.com/pipidu/sysukcb>
- 上游许可证：截至 2026 年 9 月 28 日，该仓库未附 LICENSE 文件，README 中也未声明许可证

NapTable 的中山大学教务导入参照了该项目的教务接口调用流程（`JwxtImportService`）和周次字符串展开规则（`WeekMask.parse`），并以 JavaScript 重新实现：

- `NapTable/Import/SysuExtractor.swift`
- `tests/SysuExtractorChecks.mjs` 中模拟的教务响应格式

在上游明确许可证之前，NapTable 仅在此注明来源与致谢，不将上游代码本身纳入本仓库或重新授权。

## NJFU-schedule

- 项目：<https://github.com/keggin-CHN/NJFU-schedule>
- 上游许可证：截至 2026 年 9 月 29 日，该仓库 README 声明为 MIT，但仓库未附 LICENSE 文件

NapTable 的南京林业大学教务导入参照了该项目 `NjfuImporter` 的登录入口（`jwxt.njfu.edu.cn/sso.jsp` 经统一认证回到教务）、课表页面（`/jsxsd/xskb/xskb_list.do`）和 `table#timetable` 的解析规则（`div.kbcontent` 分隔、`<font title>` 字段、按大节兜底节次），并以 JavaScript 在 App 内置网页中重新实现，不移植其原生登录与密码加密流程：

- `NapTable/Import/NjfuExtractor.swift`
- `tests/NjfuExtractorChecks.mjs` 中模拟的课表页面结构

NapTable 仅在此注明来源与致谢，不将上游代码本身纳入本仓库或重新授权。

## NauCourse

- 项目：<https://github.com/XFY9326/NauCourse>
- 上游许可证：GPL-3.0-or-later（Copyright © 2020 XFY9326）
- 上游许可证文件：<https://github.com/XFY9326/NauCourse/blob/master/LICENSE>
- 参考版本：`d1d36190503052148c0fe650593a7d0f6616d9ec`

南京审计大学导入参考该项目 `JwcClient` / `MyCourseScheduleTable` 中的教务入口、课表地址、表格字段顺序和周次/节次文本格式。`NapTable/Import/NauExtractor.swift` 在已登录的网页中以 JavaScript 重新实现解析；`tests/NauExtractorChecks.mjs` 使用按上述格式构造的匿名页面验证结果。未引入上游 Android 代码、原生登录或密码处理实现。

## njtech_timetable

- 项目：<https://github.com/GiuseppeLR/njtech_timetable>
- 上游许可证：Apache License 2.0（仓库 README 的开源协议声明）

南京工业大学导入参考该项目 `JwWebviewPage` / `NjtechWebParser` 中的教务入口、
课表接口参数、`kbList` / `sjkList` / `jxhjkcList` 字段和周次展开规则。NapTable
在 `NapTable/Import/NjtechExtractor.swift` 中以同步 XHR 重新实现解析，只在已登录的
WebView 内读取课表，不引入上游 Flutter 代码、账号密码处理或网络代理。

## fudan-course-table-export

- 项目：<https://github.com/lan-kehan/fudan-course-table-export>
- 上游许可证：仓库未附 LICENSE 文件

复旦大学导入最初参考该项目的新版课表字段；当前本科生导入以 DanXi 使用的
`studentTableVms[0].activities` 接口为准。NapTable 在
`NapTable/Import/FudanExtractor.swift` 中以 JavaScript 重新实现解析，不引入上游
Python 脚本或 pandas 依赖。

## DanXi

- 项目：<https://github.com/DanXi-Dev/DanXi>
- 上游许可证：GPL-3.0-or-later

复旦本科生课表导入参考该项目 `TimeTableRepository` 的
`/student/for-std/course-table/semester/{semesterId}/print-data` 接口，以及
`studentTableVms[0].activities` 中的 `courseName`、`teachers`、`weekIndexes`、
`weekday`、`startUnit` 和 `endUnit` 字段。NapTable 仅以独立 JavaScript 重新实现
字段转换，不引入 DanXi 的 Flutter 代码。

## xjtu-timetable-calendar

- 项目：<https://github.com/XLJFZ/xjtu-timetable-calendar>
- 上游许可证：MIT（Copyright © 2026 ZBZ and contributors）
- 许可证原文：[`LICENSES/xjtu-timetable-calendar-MIT.txt`](LICENSES/xjtu-timetable-calendar-MIT.txt)
- 参考版本：`145915a9e3c31032cc03dfc4d10e5396b6fce912`

西安交通大学导入参考该项目的 eHall 应用入口、`dqxnxq.do` 当前学期接口、
`xskcb.do` 学生课表接口，以及 `SKZC` 周次位掩码和 `KSJC` / `JSJC` 起止节次
字段。`NapTable/Import/XjtuExtractor.swift` 在已登录的网页中独立实现 JavaScript
转换。`tests/fixtures/xjtu-timetable.json` 保留上游匿名响应的课表字段子集，供
`tests/XjtuExtractorChecks.mjs` 验证，不包含真实姓名、学号或登录凭据。

## ruc-schedule-extension

- 项目：<https://github.com/KerryChia/ruc-schedule-extension>
- 上游许可证：MIT
- 许可证原文：<https://github.com/KerryChia/ruc-schedule-extension/blob/main/LICENSE>

中国人民大学本科、研究生课表导入参考该项目 `content.js` 的页面入口、
本科单元格周次/节次格式，以及研究生 `#jsTbl_01` 网格和同源 iframe 解析规则。
NapTable 在 `NapTable/Import/RucExtractor.swift` 中以独立 JavaScript 重新实现，
仅在用户已登录的 WebView 中读取课表，不引入上游扩展、ICS 生成器或服务端代码。

## 许可证适用范围

第三方许可证只适用于相应的第三方代码、资源及其衍生部分。所有贡献者仍应在新增或改编第三方文件时保留来源、版权和许可证声明，并在本文件中补充记录。

## Celechron

- 项目：<https://github.com/Celechron/Celechron>
- 上游许可证：GPL-3.0

浙江大学本科生教务导入参考 Celechron 的 ZDBK 登录后课表请求流程、`xnm/xqm` 学期参数、`kbList` 字段和 `dsz`/`djj`/`skcd` 课表解析规则。NapTable 在 `NapTable/Import/ZjuExtractor.swift` 中以独立 JavaScript 重新实现，仅在已登录的 WebView 中读取课表，不引入上游登录、账号密码或 Flutter 代码。

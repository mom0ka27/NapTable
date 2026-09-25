# 服务端排程的实时活动提醒

状态：第 1 步（服务端）已实现，第 2、3 步未开始；分支 `server-scheduled-reminders`。基线为 `live-activity-v2.md` 与 `live-activity-token-mode.md`；本文未写到的行为沿用现状。实现完成后，现状以 `live-activity-v2.md` 为准，本文只保留设计理由。

## 1. 目标

- 提醒计划只在服务端计算一份。客户端上传课表的时间结构和提醒设置，服务端保存原文、按天生成要发送的提醒；客户端只负责渲染，以及在 iOS 26 上本地预约最近几节。
- 不打开 App 也能一直提醒到学期结束；共享课表更新、撤销后，服务端直接替关注者重排。
- 关心共享课表时，自己和对方的提前量可以分开设置。
- 去掉每分钟一次的全量重算（`materialize`）、提前 48 小时生成任务、本地交接（`local-handoff` / `remote-resume` / `foreground-recovery`）和 7 天凭证（`createBefore`）。

非目标：不新开接口版本，直接修改 `/v2/live-activity`；尚未发布依赖旧契约的客户端。iOS 17 不再提供提醒，只保留打开 App 时的预览。

## 2. 已确认的取舍

| 取舍 | 决定 |
|---|---|
| 服务端记录「设备关注了哪份分享」 | 接受，隐私说明同步更新 |
| 共享课表的推送携带课程名、教师、地点 | 接受：分享内容本来就存在服务端。自己课表的文字永不上传 |
| 所有开启提醒的用户上传自己课表的时间结构 | 接受：只有星期、节次、周次和课程 ID，不含文字 |
| iOS 17 | 只保留预览 |
| iOS 26 本地预约 | 保留，只预约最近几节（系统一般只留约 5 个名额），由认领名单与服务端分工 |

## 3. 上传：`PUT /devices/{id}/timetable`

客户端在以下时机上传整份内容：导入或编辑课表之后、修改提醒设置之后、切换关注的分享之后，以及每次前台启动时（内容不变时幂等，不产生写入）。

```json
{
  "revision": 12,
  "own": {
    "scope": "<本机课表的 scheduleScope>",
    "schoolID": "<可选：学校 ID，用于判断能否走学校频道>",
    "periods": [{"start": "08:00", "end": "08:45"}],
    "semesterStartMonday": "2026-09-07",
    "weekCount": 18,
    "adjustments": [{"date": "2026-10-01", "kind": "off"}, {"date": "2026-10-11", "kind": "swap", "source": "2026-10-08"}],
    "courses": [{"id": "<liveActivitySourceID>", "day": 1, "first": 1, "last": 2, "weeks": [1, 2, 3]}]
  },
  "follow": {"share": "<分享码>"},
  "conflicts": {"2026-09-22:3": "<选中的课程 ID>"},
  "settings": {"leadMinutes": 60, "sharedLeadMinutes": 15, "perPeriod": true}
}
```

- `own`：只含时间结构。收起的课（`hidden`）不上传。没有星期或节次的自由课程不上传。手动创建的课表同样上传自己的节次和学期。
- `follow`：可选，关心共享课表时才有，只带分享码（知道分享码才能关注）。服务端用分享码找到 `shares` 行，登记它的 `schedule_scope`；之后按 scope 读取最新的有效分享，所以分享码轮换不影响关注。课程、节次、学期、调休都来自分享快照；分享里没有唯一行 ID 的课、收起的课不排提醒，与客户端一致。
- `conflicts`：两张课表各自的节次冲突选择，键为 `日期:节次`，含义与现有 `naptable.liveActivity.conflicts.<scope>` 相同。
- `settings.leadMinutes` 用于自己的课，`sharedLeadMinutes` 用于对方的课，取值都是 15 / 30 / 60；缺少 `sharedLeadMinutes` 时两边都用 `leadMinutes`。不关心共享课表时忽略 `sharedLeadMinutes`。「课间也保留」只影响手机上的显示，不上传。
- 所有日期和时刻一律按 UTC+8 解释，上传内容不带时区。
- 服务端只挑出上面列出的字段，规范化后保存；不认识的字段直接忽略、不会存下来（客户端多带了课程名也不会落库），新客户端加字段也不会让旧服务端拒收。仍然检查取值：节次必须有序且不重叠，课的节次不能超出节次表，提前量只能是 15 / 30 / 60，课程数、周数、调休条数都有上限，不合法返回 400。`revision` 和摘要都按规范化后的内容计算。
- `revision` 必须单调递增：旧 revision 返回 409；同一 revision 内容相同则幂等。
- 响应为 `{revision, pushMode, following, conflicts, omitted, pendingCount}`：`conflicts` 是从今天到学期末（最多 200 天）主导课表的节次冲突，每项 `{id: "日期:节次", date, period, choices: [课程 ID]}`，已选择的也列出；`omitted` 是超过 8 小时等无法排程的次数。
- `pushMode`：不关心共享课表、带了 `schoolID`，并且上传的节次与这所学校当前的作息完全一致时为 `channel`（订阅学校频道，上下课由公共广播刷新）；其余一律 `token`。

## 4. 服务端排程

### 4.1 引擎

在 `live_activity_timeline.py` 中移植 `LiveActivityTimeline.build` 的排程部分，作为唯一的实现：

- 按学期和调休展开实际日期（`off` 当天停课，`swap` 改上指定日期的课），再按周次筛选课程。
- 同一来源连续的节次合成一次上课；冲突未选择的日期不排提醒，并在结果中列出冲突。
- 提醒时刻为 `开课时间 − 提前量`，不早于同一张课表前一节课的结束时间。
- 分节计时：每一节是一段显示，节与节之间是「课间 · 第 n 节」。
- 关心共享课表时：两张课表时间重叠的课合成一个活动。对方在上课时由对方的课占主位，其余时间由自己的课占主位；另一张表同时在上的课作为 `companion` 并排显示。合并块的提醒时刻取块内每节课各自提醒时刻中最早的一个（每节课按自己那张表的提前量计算），开头的倒计时显示最早需要提醒的那节课。后加入的课在自己的提醒时刻响铃（`alertAt`，最多 16 个）。一串课超过 8 小时，在显示变化的时刻拆给下一个活动。
- occurrence ID 是「某一天的某一次上课」的编号，一个编号对应一个实时活动；服务端与手机靠它防止重复启动、对应推送令牌、记录拆分合并后的替换关系。编号可推算：以「设备 + 来源课程 + 日期 + 节次」（合并时取开场课程）做 UUIDv5，同一节课每次算出的 ID 相同，不需要保存 ID 对照表。重排后键变化的课（拆分、合并）对照已生成的行记录 `supersedes`，规则与现有客户端相同。
- 引擎按日期计算，每次只算指定的某一天。

实现：`server/live_activity_schedule.py`。引擎的输出只包含时间和结构，不包含课程文字：

```json
{"occurrenceId": "…", "supersedes": [], "dateKey": "2026-09-22", "start": 0, "end": 0, "reminder": 0,
 "pushMode": "channel", "channel": "<最后一节的频道，仅频道模式>",
 "alertAt": [],
 "frames": [{"from": 0, "until": 0,
             "lead": {"table": "own", "course": "<课程 ID>", "first": 1, "last": 2, "phase": "upcoming"},
             "companion": {"table": "share", "course": "…", "first": 3, "last": 3, "phase": "inProgress"}}]}
```

frames 中的 `lead` 与 `companion` 结构相同：`{table, course, day, phase, first, last, start, end}`，课间另有 `break: n`（第 n 节之前的课间）。`phase` 取 `upcoming`（倒计时到 `start`）或 `inProgress`（进行到 `end`）；`first`/`last` 用于生成「第 1–2 节」标签，有 `break` 时显示「课间 · 第 n 节」。`day` 是这门课所在的日期，客户端据此找到当天的调休说明。所有时刻都是 Unix 秒。

### 4.2 存储

- `la_timetables`：每台设备一行，永久保存上传的原文、revision、摘要、`push_mode`、频道用的学校与作息版本，以及关注的分享 scope 和上次读到的分享 `updated_at`（每台几 KB）。
- `la_start_jobs`：沿用现有的启动任务表，由引擎生成的行标记 `engine=1`，并新增 `day`（UTC+8 日期）和 `refresh`（令牌模式的 `refreshAt` / `alertAt`）两列。只存「今天 + 明天」。这类行的 `payload` 列只存这节课内容的摘要，用来判断重建时有没有变化；启动推送在发送或认领时，按课表原文重算这一天、找到这节课再现拼。发送时如果课表里已经没有这节课，这一行记为 `cancelled`，不发送。状态沿用现有取值，新增 `local`（手机本地负责）。
- `la_v2_meta`：记录夜间任务最近一次完成的日期。
- 生成时机：设备上传课表时生成「今天 + 明天」；每天 UTC+8 0:00 之后的第一轮夜间任务（每 30 秒检查一次）为所有设备重建「今天 + 明天」，删除结束超过一天的行，并为走频道的作息版本续期广播承诺。服务端启动时如果当天还没跑过，会立即补跑。

- 引擎分组时保留当天已经结束的课，只在输出时去掉已经结束的活动，所以同一节课在一天里任何时候计算，编号和 frames 都一样。

实测（M5，文件型 SQLite WAL，一万台设备，每台每天 5 节课、分节计时）：上传一份课表每台 4.3 ms（含整学期冲突扫描），重建两天 0.35 ms，夜间任务整体 4.5 s（每台一个短事务），库里 15 万行、121 MB；同一时刻现拼 1000 条启动推送约 0.1 s。

### 4.3 重排

以下事件触发重排，只重算「今天 + 明天」：

- 设备上传了新的课表或设置：在上传请求里直接完成；
- 关注的分享被替换、重新同步、轮换或撤销：后台每 30 秒比较一次每位关注者记下的 `updated_at` 与当前有效分享的 `updated_at`，不一致的逐台重建，每台一个短事务，下一次提醒最近的设备优先。分享代码本身不需要通知实时活动服务。撤销后找不到有效分享，重建时只保留自己的课。
- 管理员修改学校作息不会影响已发布的分享（分享是冻结快照），发布者重新同步后按上一条处理。自己的课表由客户端下次上传时更新。

重排规则：重算后与已有的行逐条比较，只写入有变化的行。`pending` 和 `local` 的行可以直接替换或删除；已经处于 `submitting`、`submitted`、`submissionUnknown` 的行保留，新结果中 `supersedes` 指向这些行的 occurrence 标记为 `superseded`，不再发送（与现有规则一致）。

### 4.4 发送

- `starts` 循环沿用现有实现：每秒取 `state='pending' AND fire_at<=now` 的行，逐条现拼启动推送后批量发送。频道模式写入 `input-push-channel`，令牌模式写入 `input-push-token: 1`。（一批满额时立即继续下一批：尚未实现。）
- 启动推送的 attributes 新增 `frames`，携带这个活动的全部 frames（只有课程 ID、节次和阶段，不含文字），随活动保存在手机上；小组件按当前时刻选出对应的一段，再按课程 ID 从本地课表取文字。这样客户端不需要提前下载排程也能渲染远程启动的活动。
- 共享课表的课：启动推送的 attributes 新增 `texts`，为 frames 里出现的每门对方课程带上 `{name, teacher, location}`（取自分享快照），供手机上还没有这节课内容时直接显示。自己的课不带文字。推送超过 3900 字节时先去掉 `texts`，frames 保留。
- 令牌模式的刷新时刻和提醒时刻（`refreshAt` / `alertAt`）由服务端根据 frames 计算。客户端只需上传令牌：`PUT /devices/{id}/activities/{occurrenceId}` 的请求体为 `{"token": "…"}`。已经启动的活动遇到重建时，保留启动记录，但尚未发送的刷新按新的 frames 重排。
- 频道承诺：上传时续到 8 天后；夜间任务为所有走频道的设备所用的作息版本再续到 8 天后，不再依赖客户端请求凭证。

## 5. 客户端

- 渲染：本地预约的活动用认领时返回的 frames，远程启动的活动用启动推送里的 frames。根据 frames 中的 `table + course + first/last + phase`，从本地课表（自己的课）或本地分享快照（对方的课）取出文字，生成 `ContentState`。本地找不到这节课时，使用推送中携带的文字；两者都没有时显示「课程提醒」。
- 本地预约（iOS 26）：打开 App 时调用 `POST /devices/{id}/claims`，请求体为 `{"slots": n}`（n 为本地可用的预约名额）。服务端在一个事务里，从「今天 + 明天」中挑出最近的 n 节还处于 `pending` 的课，标记为 `local`，并返回它们的 occurrence ID、提醒时刻、结束时刻、frames 和频道；之前认领过、仍未开始的课一并返回，已经发出或结果不明的课不会被选中。App 照着返回的内容预约；预约失败的课用 `DELETE /devices/{id}/claims/{occurrenceId}` 交还，服务端改回 `pending`。周末等没课的时候返回为空，全部交给服务端。关心共享课表时同样可以本地预约：模拟器上活动开始时 App 会在后台被拉起并拿到令牌（真机待验证，见 §7）。
- 设置页：关心共享课表时显示第二个提前量选项「对方课程提前显示」。
- 删除：`LiveActivityTimeline.build` 的排程部分、计划上传、`local-handoff`、`remote-resume`、`foreground-recovery`、`broadcast-config` 凭证与 7 天租约、iOS 17 的前台提醒。保留前台和后台的 `reconcile`，用于在推送没到时纠正画面。

## 6. 接口变化一览

| 方法 | 路径 | 变化 |
|---|---|---|
| POST | `/devices` | 不变 |
| PUT | `/devices/{id}/timetable` | 新增，取代 `PUT /devices/{id}/plan` |
| POST | `/devices/{id}/claims` | 新增：按名额认领最近几节并返回预约所需内容，取代 `local-handoff` / `remote-resume` / `foreground-recovery` |
| DELETE | `/devices/{id}/claims/{occurrenceId}` | 新增：交还预约失败的课 |
| PUT | `/devices/{id}/activities/{occurrenceId}` | 请求体只剩 `token` |
| DELETE | `/devices/{id}/activities/{occurrenceId}` | 不变 |
| GET | `/devices/{id}` | 另外返回 `timetableRevision`、`pushMode`、`following` |
| DELETE | `/devices/{id}` | 不变，同时删除课表和关注关系 |
| GET | `/broadcast-config` | 删除，频道 ID 随认领结果和启动推送返回 |
| PUT | `/devices/{id}/plan` 等 | 删除 |

第 1 步保留了旧接口（`plan`、`local-handoff`、`remote-resume`、`foreground-recovery`、`broadcast-config`，以及带 `refreshAt` 的活动令牌上传），现有客户端不受影响；设备一旦上传课表，旧计划中未发出的任务就会取消。旧接口在第 3 步删除。

部署顺序：先服务端，后客户端。旧计划的启动记录留在同一张表里（`engine=0`）；重建时，与旧计划中已发出、结果不明或已交给本地预约（`localTaken`）的任务时间重叠的新课记为 `superseded`，不会被重复启动。

## 7. 分步实施与验收

1. 服务端：引擎、存储、上传、下载、认领、发送改造、分享触发的重排，以及 Python 测试。引擎测试直接复用 `tests/NativeLiveActivityChecks.swift` 中合并、拆分、截断和分节的用例数据，对照期望结果。
2. 客户端：上传与下载、按 frames 渲染、认领与本地预约、两个提前量的设置、iOS 17 降级为预览，以及 Swift 检查。
3. 清理：删除旧接口和旧表的写入，更新 `live-activity-v2.md`、`FEATURES.md`、`server/README.md` 和 App 内隐私说明。

真机验收（需要维护者完成）：用户手动划掉 App 后，本地预约开始时 App 是否还会被拉起；低电量模式下是否一样；远程启动后拿到令牌需要多久；共享课表更新后，关注者不打开 App 也能按新课表提醒。

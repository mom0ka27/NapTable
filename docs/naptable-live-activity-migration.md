# APNs / 课程实时活动重构与 NapTable 迁移方案

整理日期：2026-09-22。本文是代码梳理与迁移建议，不代表 NapTable 已完成迁移、真机验收或上线。

核对基线：CPU-web `640785c872d4846ae154405dd3693eab66b291c1`；NapTable HEAD `8c7a4fbe9cdf845331ada3465c503b6d440ba5f7`，同时读取其当前工作区。两边均有已有未提交修改，尤其 NapTable 的课表、学校配置、分享与服务端正在变动；实施时需基于届时工作区逐项合并，不能覆盖文件或整批 cherry-pick。

## 1. 这次到底重构了什么

本次“实时通知”指 ActivityKit 实时活动及灵动岛，不是普通通知、WebSocket 消息或桌面 Widget 的通用后台刷新。

重构经历了三个阶段，迁移目标应直接采用第三阶段：

| 阶段 / 提交 | 核心变化 | 迁移结论 |
| --- | --- | --- |
| `764c2a6`、`3573a95`、`a249a14` | 独立 CPU APNs；逐设备远程启动；学校课节块广播；个人内容在本地解析 | 保留分工，淘汰按块活动模型 |
| `b6c8b39` | 日期频道改为跨日复用的固定频道；自动创建、维护与回收；隐藏手工频道管理 | 保留自动管理思想，不照搬 `cpu-block` / `cpu-day` 键 |
| `640785c` | 每次课程一个实例；作息版本 + 最终节次频道；iOS 26 本地预约；iOS 18 远程启动；持久账本与模式交接 | 本次迁移基线，协议 v2 |

最新行为：

- 一门课在某个实际日期的一次连续上课段对应一个 `occurrenceId`。同名不同来源不合并；连堂课不在课间销毁重建。逐节冲突先由用户选择，课程被其他课程隔开后拆成不同实例。
- 提前量改为 15 / 30 / 60 分钟，支持整堂与分节计时。提醒时间为 `max(首节开始 - 提前量, 前序课程或占用结束)`，避免下一门课提前占据上一门课的时间。
- App 与 Widget 共用绝对时间时间线；Widget 只读取当前实例的本地快照。服务器不接收课程名、教师、教室及完整展示帧。
- 最终第 p 节结束的课程订阅第 p 节结束频道。该频道接收第 1 至 p 节的公共边界更新，在 p 节结束时收到 `end`；活动结束不再拖到整个上午或全天结束。
- 频道跨日复用，作息版本不可变。学校调时间生成新版本，旧版本继续履行已有预约的广播承诺，不能原地覆盖。
- iOS 26+ 本地预约未来连续 168 小时，前台滚动补充；不使用远程启动兜底。映射允许创建 7 天内课程，并承诺 8 天广播；离线不能自行延长映射期限。
- iOS 18 上传完整课程计划，服务端保存快照、滚动物化未来 48 小时启动任务；使用 push-to-start 携带 `input-push-channel`，后续无需回传每个活动的更新 token。
- 预约账本处理重复配置、手动移除、额度不足与恢复；设备从 remote 切到 local 前必须交接，不能仅靠新客户端停止上传。
- 远程启动先持久化 `submitting`；已提交与结果不明保留历史，不能被计划重传清成待发送。公共广播与个人启动分别调度。

文档注意：`docs/apns.md` 仍描述旧课节块方案；`docs/live-activity-redesign.md` 首部仍写“尚未实现”。当前实现以代码和 `docs/live-activity-v2-implementation.md` 为准，后者记录的是本地检查，明确保留真机、多 worker 故障与容量验收。

## 2. NapTable 现状与差距

| 层 | 当前 NapTable | 需要迁移的部分 |
| --- | --- | --- |
| 课程数据 | 原生 `Course` / `CourseTable`，多学校、多课表、关注的共享课表 | 实例身份、逐节冲突、按实际日期展开、作息版本绑定 |
| Swift 控制器 | `NativeLiveActivityController.swift`；iOS 26 按今天/明天日期频道预约；旧持久模式及帧计划 | 逐课程时间线、7 天窗口、持久账本、近期优先及恢复 |
| 网络协调 | `LiveActivityPushService.swift`；设备 secret、启动及活动更新 token、完整帧上传 | v2 计划、版本冲突、设备模式交接、可重试撤销 |
| Widget | 已有 App Group 本地课表解析、广播标记 | 按作用域 + occurrence 精确匹配，缺失时安全降级 |
| Python 服务 | `server/live_activity.py` + SQLite；最多 240 帧；日期频道与学校频道并存 | 完整计划快照、48h 任务物化、不可变作息、最终节次频道、提交状态机 |
| APNs | `server/apns.py` 已有 JWT 缓存、连接复用、广播与频道管理 | 区分未发送/结果不明，避免启动自动重发；校验明确 HTTP 状态 |
| 管理后台 | 自动创建学校频道，仍展示频道 ID 及手工同步 | 自动维护版本频道，面向管理员展示健康状态与失败原因 |

建议保留 Swift + Python + SQLite。移植协议、纯逻辑与测试场景，不引入 CPU 的 Express / Prisma / PostgreSQL、Web 桥接或登录系统，也不复制 CPU 的 APNs 凭据、Bundle ID、App Group 或服务器地址。

## 3. NapTable 专属适配决策

### 3.1 身份和课表作用域

CPU 的 `userId` / `accountScope` 是账号隔离；NapTable 当前快照把本地 table ID 或分享 code 填入 account，不能直接当成服务端鉴权。

- `installationId`：持久化安装身份；沿用设备 secret 鉴权，凭据建议放 Keychain。
- `scheduleScope`：为本地课表、关注的共享课表建立独立持久 UUID；分享访问码轮换不改变逻辑课表身份。它只隔离内容，不授予修改其他设备的权限。
- `sourceCourseId`：本地可由课表作用域 + `Course.id` 建立；共享课程需要稳定行身份映射。禁止使用课程名，或每次刷新随机产生身份。
- `occurrenceId`：对来源、实际日期、选择后的连续节次段维护稳定 UUID 及 `supersedes`；文字编辑保留身份，拆分合并明确继承关系。
- 先明确为“当前选中的一份课表”安排活动；切课表撤销旧作用域的未启动计划，结束旧活动，再同步新作用域。关注课表遵守同一规则，不默认同时提醒所有课表。

`ScheduleStore.swift` 当前 `nativeId` 为 nil，`sourceKey` 刻意为空以维持编辑器语义。新增独立实时活动来源字段或适配映射，不要为了套用 CPU 代码改写编辑器的 `sourceKey`。

### 3.2 多学校、多作息和多 App

建议完整频道逻辑键：

```text
<bundleID>:<environment>:<schoolID>:<scheduleID>:<scheduleVersion>:end-period-<p>
```

`scheduleID` 标识学校/校区作息，不等同于个人课表 ID；`scheduleVersion` 由规范化节次表及 IANA 时区等作息语义生成。学期日期与调休影响课程展开，不应仅因课程内容变化重建频道。

NapTable 支持修改课表节次表。只有本地节次时间与服务端权威版本一致才允许使用对应频道；不一致时提示同步或不支持，不能拿学校默认频道结束个人时间不同的课程。首版不为任意私人作息自动创建频道。

去掉 CPU 的 `main-campus`、`Asia/Shanghai` 和 `+08:00` 硬编码，使用作息版本的时区。NapTable 多数学校虽在国内，协议仍须校验时区并固定日期解释，不跟随手机旅行后的时区。

现有服务文档提到 CPU / NapTable 可共用密钥，但频道归属于具体 App。首版建议只允许配置中的 NapTable Bundle ID；若确需服务多个 App，凭据配置、频道创建/回收、队列和广播端点均按 Bundle ID 隔离，不能只改 device push 的 topic。

### 3.3 系统版本与非标准课程

- iOS 26+：本地预约 + 最终节次广播；首次离线且尚未完成旧远程模式交接，不创建可能重复的预约。
- iOS 18：远程启动 + 最终节次广播。
- iOS 17：若保留该系统支持，首版仅保留明确标注的前台本地能力；这会收窄 NapTable 原 iOS 17.2 的远程能力，应在发布说明中说明，不能静默改变。
- macOS / visionOS 等维持现有平台条件编译，不把 iOS ActivityKit API 引入共享层的无条件依赖。
- 无固定日期时间的自由课程不能生成可靠预约；有具体时间但不匹配公共节次的课程，首版仅作为 `busyIntervals` 约束其他提醒，明确列为未安排。不静默映射到最近节次。此类课程与标准课程实际重叠时，应要求解决冲突，不能声称 CPU 已支持自动解决。
- 没有服务端映射的纯本地课表仍可正常使用课表功能；实时活动显示受限原因，可保留独立的前台演示/本地能力，不能宣称自动启动和广播结束可用。

## 4. 协议与数据迁移

### 4.1 API（建议的新契约，不是现有接口）

使用独立 `/v2/live-activity` 前缀，避免旧客户端把新响应当成帧计划协议。设备所有写操作校验 `X-Device-Secret`，安装 ID 或 table ID 本身不是凭据。

| 接口 | 责任 |
| --- | --- |
| `POST /devices` | 首次注册；已有设备的更新必须验证 secret，返回模式和版本 |
| `GET /broadcast-config` | 按 App、环境、学校、作息返回不可变版本、完整 periods、时区、有效期限；local 模式返回最终节次映射 |
| `PUT /devices/{id}/plan` | 原子替换完整 v2 课程快照；同 revision 同内容幂等，不同内容或旧 revision 返回 409 |
| `GET /devices/{id}` | 当前模式、计划版本、实际接受范围及错误状态 |
| `POST /devices/{id}/local-handoff` | 幂等切换 local，取消未提交远程任务，返回已提交/不明实例历史 |
| `POST /devices/{id}/foreground-recovery` | 协调前台接管未提交实例，避免和远程同时启动；已提交/不明不能简单重置 |
| `DELETE /devices/{id}` | 幂等撤销并保留防重历史/墓碑；客户端持久化离线撤销，成功后清凭据 |

当前 `register()` 更新已有 deviceID 时未在该分支验证 secret；迁移必须补上，不能复制这个入口行为。

计划至少包含 `protocolVersion`、`planRevision`、`scheduleScope`、`schoolID`、`scheduleId`、`scheduleVersion`、`coverageStart`、`coverageEndExclusive`、`leadMinutes`、`items`、`busyIntervals`。每个 item 仅含 `occurrenceId`、`supersedes`、`dateKey`、`startPeriod`、`endPeriod`。服务端用权威作息还原时间并校验整份快照，再执行写入。token 注册信息与计划摘要关联，但不要将明文 token 复制进计划快照或日志。

先原子保存本地个人展示快照，再提交计划/创建预约。广播只带公共信息；共享 Swift schema 必须能解码 start/update/end 三类 payload。

特别注意时间编码：APNs `timestamp` / `stale-date` / `dismissal-date` 使用 Unix 秒；CPU 当前 Swift 默认 Codable `Date` 字段使用 2001-01-01 参考秒，转换差值为 `978307200`。Python 重写时必须逐字段约定编码，并以真实 JSON fixture 验证，不能一律写 Unix 秒。

### 4.2 SQLite 存储

建议通过显式、可重复执行的数据库迁移新增或扩展：

- `la_devices`：安装身份、作用域、协议版本、launch_mode、mode_revision、handoff_id/result、plan_revision、plan_digest、完整 plan_snapshot；token 加密保存，密钥位于数据库与 release 之外。
- `la_schedule_versions`：学校/作息身份、不可变 periods/timezone、版本、broadcast_until。
- `la_channels`：上述完整逻辑键、Apple channel ID、状态、重试与回收信息；替代按日期增长的 `la_day_channels`。
- 启动任务：按 device + occurrence 唯一；记录 revision、fire_at、expires_at、尝试次数、提交状态和结果。不能用计划覆盖操作抹掉历史。
- 广播任务：按 App/环境/版本/最终节次/日期/边界/类型唯一；记录频道推进位置，确保 `end` 后不补发更早 update。

迁移先新增结构，保留旧表供审计；旧未提交任务取消，旧设备显式要求升级。不能把 PostgreSQL advisory lock 代码直译为 Python 进程内锁：模式交接、计划替换与发送前提交意图要用 SQLite 事务和条件更新形成同一个互斥边界。

首版采用单进程调度、短写事务、工作线程独立连接或专用 DB 写入器；APNs 网络请求不得占用数据库写事务。需要多进程时再验证跨进程 claim、崩溃恢复及交接竞争。SQLite 的单写者约束不能靠增加线程消除。

### 4.3 发送与频道管理

建议启动状态为 `pending → claimed → submitting → submitted / submissionUnknown / terminal`；取消、过期与本地接管另有终态。明确 429/5xx 等可按有效期重试；连接断开但可能已发送时保留 unknown，不自动重发 start。客户端重新同步、换 token、重启不能重置这些记录。

`apns.py.push()` 当前遇到传输错误会换连接再发一次，且缺失 HTTP status 时可能推断 200。应先修正为返回明确状态与提交确定性，再接新调度器；不能靠 `collapse-id` 宣称 exactly-once。保留现有连接/JWT 复用能力，增加并发时先确认连接线程安全，按连接加锁或建立有界连接池。

把频道维护、48h 启动任务物化、启动发送、公共广播拆成独立工作循环/队列；避免当前 `dispatch_due()` 先做频道网络管理而阻塞到点任务。Python/SQLite 的批次与并发按压测配置，不复制 CPU 默认 2000 / 64 就认定性能达标。

广播按所有仍有保留承诺的作息版本逐日生成，不能依赖存在远程设备、个人计划或“今天非节假日”。NapTable 当前按全局休假跳过广播的逻辑需移除：本地调课与 iOS 26 预约仍可能需要这些边界。

映射签发与版本保留原子协调：7 天内可创建，至少广播到签发后第 8 天，并覆盖已提交/不明启动的最终结束。缺失频道返回明确缺失状态，自动补建；未过承诺期不能删。`apns-expiration=0`、No Message Storage，广播边界后 60 秒过期，同刻去重且 end 优先。

频道数按 App/环境/学校/保留版本/节次数增长，而不按用户或日期增长；新方案广播量也高于单一学校频道，P 个节次通常产生 O(P²) 个边界请求，应统计容量而非沿用“全校几十条”的旧估算。

## 5. 实施顺序与文件落点

| 阶段 | 改动 | 完成标准 |
| --- | --- | --- |
| P0：冻结契约 | 新增 v2 协议文档与跨语言 JSON fixtures；确定 scope、时区、自由课程、旧客户端策略 | Swift/Python 对同一日期及 payload 得出相同结果 |
| P1：共享领域逻辑 | `WidgetCore/ScheduleLiveActivityAttributes.swift`；`ScheduleStore.swift` / `ScheduleModels.swift` / `ScheduleSnapshot.swift` 适配；身份与冲突存储 | 同源连续段、调休、分节/整堂、作用域隔离测试通过 |
| P2：服务端基础 | `server/live_activity.py` 拆分 timeline、schedule_versions、channels、repository；补迁移及 `apns.py` 发送确定性 | 版本/频道管理、鉴权、计划幂等、unknown 与崩溃恢复测试通过 |
| P3：远程路径 | Python v2 调度与 API；`LiveActivityPushService.swift`；控制器远程模式 | iOS 18 start 自带频道，更新/结束无需活动 token |
| P4：本地路径 | `NativeLiveActivityController.swift` 账本、交接、7 天预约；Widget 精确解析；设置与前台接入 | iOS 26 交接完成后预约，限额和离线展示真实覆盖 |
| P5：切换与收尾 | `DeviceSettingsView.swift`、`MyApp.swift`、后台刷新入口、管理页、文档与旧路径退役 | 旧计划/旧预约不会重复启动，新旧作息保留期限正确 |

CPU 对照文件：`NativeLiveActivityController.swift`、`LiveActivityPushService.swift`、共享 `ScheduleLiveActivityAttributes.swift`，以及 `server/src/services/liveActivityTimeline.ts`、`liveActivitySchedule.ts`、`liveActivityRemoteStart.ts`、`liveActivityPush.ts`、`apnsChannels.ts`、相关测试。Swift 可逐段移植纯逻辑；网络协调器需要重写鉴权适配；TypeScript 服务端仅作为语义与测试参考。

不要照搬 CPU 的 `auth.authenticated` 登录前置条件：NapTable 本地有课表即可进入本地领域逻辑，联网服务资格由设备注册和有效作息映射单独判断。App Group、持久化键与品牌文案沿用 NapTable。

## 6. 发布、旧数据与回退

建议“一次协议切换”，不长期并行维护旧帧计划与 v2。先准备可接受 v2 的服务端，再发布配套客户端；明确旧客户端停止远程服务并提示升级。新 v2 API 不等于允许同一设备同时运行两套调度。

切换前备份数据库与配置；迁移取消旧未提交任务，停止旧协议产生新任务。新版客户端第一次进入时清理旧预约，完成设备交接后才创建 v2 活动。旧活动引用的频道短期排空后再回收，不直接套用 CPU 单学校频道清理正则。

回退时关闭新任务产生、保留已签发频道的广播承诺与提交历史。禁止直接恢复旧数据库并重新发送旧 pending，这会使已发生的启动再次执行。若必须整体恢复备份，应先停推送、重新核对设备和任务，再启用。

本方案不包含提交、推送或部署操作。实施后上线仍需单独授权；CPU-web 的生产推送遵循本仓库精确 SHA 的 GitHub Actions 制品门禁，NapTable 按其自身发布流程验收，不能把本地测试等同生产完成。

## 7. 验收清单

1. 领域测试：15/30/60 分钟；整堂/分节与无课间边界；同名不同源；逐节冲突和分段；调休实际日期；前序占用；超 8 小时拒绝；非匹配作息和自由课程显式未安排。
2. 跨语言协议：start/update/end 可由真实 Swift Codable 解码；Unix/Apple 参考时间转换；不同学校/时区/环境/App 隔离；无个人文案上传。
3. 生命周期：重复同步、token 轮换、计划 revision 冲突；切课表、分享码轮换；关闭期间迟到响应；离线撤销重试；同会话移除不重建、下次前台恢复；手动关闭总开关后不自动开启。
4. 预约：完整 168 小时目标，实际 N/M 统计；额度不足只替换更晚 pending；active 不让位；离线映射不延期；首次交接未确认不预约；升级 iOS 26 时远程同步迟到不能切回 remote。
5. 服务端故障：发送前后进程崩溃；APNs 接受后响应丢失不重发；明确拒绝按期限重试；计划替换/撤销/交接与 submitting 竞争；保留期与回收竞争；多实例能力若宣称支持需真实进程验证。
6. 广播：本地预约用户无远程计划仍能收到；假日调课仍广播；第 2 节 end 不结束第 4 节课程；作息修改后旧活动按旧版本结束；跨日不补发昨日 end。
7. 真机：iOS 18 与 26，开发签名与 TestFlight，退后台、锁屏、断网恢复、课程最终结束收起。APNs 200 仅是接受，不能作为真机展示证据。
8. 容量：按 NapTable 的学校数、保留版本数、同时开课人数测启动延迟、过期率、unknown 数、公共结束延迟、SQLite 写锁等待与 APNs 限流。

可复用入口：`tests/check-live-activity.sh`、`tests/test_live_activity.py`、`tests/test_day_channels.py`（改为版本频道测试）、`tests/test_apns.py`；新增网络协调器的迟到响应/撤销测试，不能仅测控制器替身。建议运行 `python3 -m unittest discover -s tests -p 'test_*.py'`、相关 Swift 检查脚本和真实 Xcode SDK 构建，并回归现有调休、分享、学校模板测试。本次仅整理方案，未执行这些测试。

已知产品边界：本地预约不保证第 8 天自动续约；漏收广播可能暂留旧阶段；离线漏收 end 不保证准点收起；APNs 送达与系统额度受系统控制。设置页应展示实际结果和失败原因。

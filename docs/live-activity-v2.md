# Live Activity v2

实现依据：`naptable-live-activity-migration.md`。本文件记录工作区实现与本地验证，不代表部署、真机送达或容量验收。

## 客户端行为

- 当前用于提醒的一份课表具有持久 `scheduleScope`。本地课程用独立 `liveActivitySourceID`，不改变编辑器 `sourceKey`。共享课表保留发布者行 ID；服务端 `scheduleScope` 随分享码轮换继承。不含可靠行 ID 的旧分享不自动安排，刷新新版分享后恢复。
- 实际日期展开调休，每一来源的连续选中节次对应持久 UUID。文字变更不换 UUID，分段/合并记录 `supersedes`。冲突在设置页逐节选择；未解决的日期不安排。
- 15 / 30 / 60 分钟提前量，提醒不早于前序课程结束。支持整堂与分节计时；连堂课间不重建实例。无具体日期时间的自由课程明确未安排。目前 Course 模型没有任意绝对时间课程；协议已支持 `busyIntervals`，没有把自由课猜测成公共节次。
- App Group 先保存完整展示快照，Widget 只按 scope、occurrence、日期、作息版本读取。保留同作用域的旧作息快照供已有活动结束。网络计划和 APNs 不含课程名、教师、地点或展示帧。
- iOS 26：服务端确认 `local-handoff` 后本地预约未来连续 168 小时。账本持久记录预约和错误；当前会话移除不立即重建，下次前台可恢复。只让更晚的 pending 为近期课程让出额度，active 不让位。显示实际 N/M；映射离线不延期。没有远程启动兜底。
- iOS 18：完整计划上传后，服务端滚动物化未来 48 小时。start 自带最终节次频道，无活动更新 token 注册。前台自动重复启动路径已移除；`foreground-recovery` API 提供一次性接管，当前客户端依赖远程启动而不主动接管。
- iOS 17：仅前台本地提醒/预览，升级会撤销旧远程服务。总开关不会因前台恢复自动打开。
- 缺少学校映射、私有作息或时区不匹配时自动能力不可用，课表功能及预览仍可使用。设置页显示原因。

## HTTP 契约

前缀 `/v2/live-activity`。所有设备写入以及设备状态查询使用 `X-Device-Secret`；scope 不是凭据。初次注册可由客户端先生成并持久保存该 secret，使首次响应丢失后仍能认证重试。安装 ID/secret 存储于 UserDefaults/Keychain，兼容迁移旧 secret。

| 方法 | 路径 | 内容 |
|---|---|---|
| POST | `/devices` | `installationId`（与可选 `deviceID` 相同）、`bundleID`、`environment`、可选 `startToken`；已有 ID 必须验证 secret，不改变 local 模式 |
| GET | `/broadcast-config` | 查询 `bundleID`、`environment`、`schoolID`、`scheduleId=default`；返回版本、periods、IANA 时区、最终节次 channels、status、issuedAt、createBefore、broadcastUntil |
| PUT | `/devices/{id}/plan` | 原子完整快照，见下文；同 revision 同内容幂等，旧 revision 或同 revision 不同内容 409 |
| GET | `/devices/{id}` | 模式/版本、接受的覆盖范围、pendingCount、提交历史及错误 |
| POST | `/devices/{id}/local-handoff` | 幂等单向切换 local，终止未提交任务，返回 submitting/submitted/unknown 历史 |
| POST | `/devices/{id}/foreground-recovery` | `{occurrenceId}`；仅未提交任务返回一次 `mayStart=true` |
| DELETE | `/devices/{id}` | 幂等墓碑；取消未提交任务，保留防重历史；关闭时离线撤销持久重试，成功前不清凭据 |

计划严格包含：`protocolVersion=2`、`planRevision`、`scheduleScope`、`schoolID`、`scheduleId`、`scheduleVersion`、`coverageStart`、`coverageEndExclusive`、`leadMinutes`、`items`、`busyIntervals`。每个 item 仅含 `occurrenceId`、`supersedes`、`dateKey`、`startPeriod`、`endPeriod`。busy interval 为 `{start,end}`。服务器拒绝额外展示字段、重叠、无效时区、非法节次、超过 8 小时的实例。当前快照最大 200 天 / 10,000 项；客户端展开未来 180 天，接受覆盖区间 181 天。

### 时间编码

- 计划、映射、APNs 的 `timestamp` / `stale-date` / `dismissal-date`、ContentState 的所有时间：Unix 秒。
- **兼容已有 Swift attributes 编码**：`reservationStart`、`reservationEnd`、`reminderDate` 仍为 Swift Codable Date 的 2001 参考秒，服务器转换为 `unix - 978307200`。这些字段不是 ContentState。
- 日期按作息 IANA 时区解释；不存在或歧义的 DST 时刻拒绝。手机旅行不改变学校时区。
- `tests/fixtures/live-activity-v2.json` 的 start/update/end 同时用于真实 Swift Codable 与 Python 测试。

## 调度与存储

`live_activity_timeline.py` 保存纯验证/时间线；`live_activity_v2.py` 保存 SQLite 仓储、版本频道、生命周期与独立工作循环。旧 `live_activity.py` 仅提供旧表审计/短期排空与配置接入，不产生新 v1 任务。

显式可重复迁移新增 `la_v2_migrations`、`la_v2_devices`、`la_schedule_versions`、`la_channels`、`la_start_jobs`、`la_v2_broadcasts`，保留旧表。旧客户端接口返回 426；认证撤销仍保留。既有日期频道广播排空 3 天，不再创建旧频道。旧已提交活动在最多 8 小时排空前阻止迁移设备的本地交接完成。

SQLite 短 `BEGIN IMMEDIATE` 事务共同保护计划替换、撤销、交接和提交意图。一个进程共享序列化 DB 连接，网络在写事务外；数据库旁的进程锁禁止第二个 v2 调度器启动。频道维护、物化、start、broadcast 分别运行；APNs device/broadcast 连接按环境加锁，管理连接使用独立锁。本版不宣称多进程或高并发容量。

start 的提交意图在网络前落盘。明确拒绝的 408/429/5xx 在期限内退避；传输或响应不明进入 `submissionUnknown`，不自动重发。重启将遗留 submitting 转为 unknown。计划重传、token 轮换、关闭及交接均不能清除提交历史。APNs 缺少明确 HTTP 状态不视为 200。

频道键包含 Bundle ID、环境、学校、作息、不可变版本、最终节次；版本由规范 periods/timeZone 的 SHA-256 生成。映射允许 7 天内创建，原子承诺至少 8 天广播。公共广播不依赖个人计划或全局节假日；第 p 节结束频道只在该节最终边界 end。边界同刻去重，end 优先，60 秒过期，`apns-expiration=0` / No Message Storage；已尝试较新边界后不补发旧边界。回收前事务标记 retiring，映射签发及物化遇到回收必须重试，避免删除已承诺频道。

## 运行和切换

远程 token 使用 Fernet 认证加密，不写入计划或日志。部署时安装 `server/requirements.txt`，在数据库和 release 目录外生成、备份并限制权限的 Fernet key，通过 `NAPTABLE_LA_TOKEN_KEY_PATH` 指定。未配置 key 时不能注册远程 token，但本地预约设备可注册。不要更换或丢失密钥后继续假设旧 token 可用。

先备份数据库/配置，准备配套服务端，再发布客户端。本次工作不包含提交、推送、部署或真实 APNs 请求。回退必须保留提交历史与广播承诺，不能恢复旧 pending 队列后直接启动旧调度器。

## 验证及发布前验收

本地检查入口：

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
bash tests/check-live-activity.sh
bash tests/check-live-activity-service.sh
```

加密集成检查需安装 `server/requirements.txt`，缺少依赖时该单项测试跳过；完整验收应在依赖齐全的环境执行。另回归现有调休、分享轮换、学校模板、显示快照检查，并执行真实 Xcode SDK 构建。

仍需 iOS 18/26 真机、开发签名/TestFlight、锁屏/后台/断网恢复和最后结束收起验收，以及学校数/版本数/并发启动容量压测。APNs 200 仅代表接受。系统预约额度、离线漏收 end 和第 8 天不打开 App 的续约均无保证；不能把本地测试描述为生产完成。

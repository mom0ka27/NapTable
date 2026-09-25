# Live Activity v2

课程实时活动的现状。设计理由与取舍见 `server-scheduled-reminders.md`；更早的客户端计划方案（`plan`、`local-handoff`、`broadcast-config` 等）已经删除，历史见 `naptable-live-activity-migration.md` 与 `live-activity-token-mode.md`。本文件记录实现与本地验证，不代表部署、真机送达或容量验收。

## 分工

- 服务端是唯一计算提醒的地方：手机上传课表的时间结构和提醒设置，服务端按天算出今天、明天每个实时活动的提醒时刻、结束时刻、刷新时刻，并负责远程启动。
- 手机负责渲染：画面从本机课表现算，按活动自己的时间段取对应的画面，不依赖服务端的编号。iOS 26 还在本机预约服务端交来的最近几节。
- iOS 18：全部远程启动。iOS 26 及以上：本地预约最近几节，其余远程启动。iOS 17：只保留预览。

## 客户端

- 上传（`LiveActivityTimeline.timetable`）：自己课表的 `scope`、可选 `schoolID`、节次时间、学期第一周周一、周数、调休（`off` / `swap`）、每门课的来源 ID、星期、起止节次、周次；关心共享课表时加上分享码和本机为这份分享用的 `scope`；显示中那张课表的冲突选择；提前量、对方提前量、分节计时。不含课程名、教师、教室。内容变化时 revision 加一并先存下再发送，响应丢失后重试的是同一份；每次启动至少上传一次；409 时查询服务端的 revision 后接着往上加。
- 渲染（`LiveActivityDisplaySnapshot`）：App 用 `LiveActivityTimeline.build` 算出今天、明天的本地画面帧，存进 App Group。小组件和 App 按活动的 `scheduleScope`、`dateKey` 和时间段（`reminderDate` ～ `reservationEnd`）找出覆盖当前时刻的帧；服务端的提醒比本地早时先显示下一帧的倒计时；本地没有这段时间的课（手机上的分享快照比服务端旧）时，用推送 attributes 里的 `shared` 画对方的课。时间段结束后不再显示。本地更新的 `staleDate` 是下一次画面变化的时刻。
- 本地规则与服务端一致：同一来源连续节次合成一次上课；冲突未选择的日期不提醒；提醒不早于同一张课表前一节课的下课；关心共享课表时两张课表时间重叠的课合成一个活动，自己的课在上时自己占主位，否则对方的课占主位，都没在上课时倒计时到最近的下一节，另一张表的课并排显示；两边各按自己的提前量提醒，合成的活动在最早的提醒时刻出现。
- 认领（iOS 26）：每次同步 `POST /claims`，名额为 4 减去本机仍在等待的预约数。按返回内容用与服务端启动相同的 attributes 预约（频道模式 `.channel(id)`，令牌模式 `.token`）；已有的预约保留，服务端不再交给本机或时刻变了的预约先撤掉。预约不了的（缺频道、名额满、其他错误、不是当前课表）用 `DELETE /claims/{id}` 交还。
- 令牌：订阅每个令牌模式活动的 `pushTokenUpdates`（远程启动或本地预约开始时 App 在后台被拉起），令牌变化时 `PUT /activities/{id}` 只传 `{"token"}`；404 表示服务端已不排这个活动，不重试；活动结束后尽力 `DELETE`。
- 切换课表（scope 变化）时结束旧课表的全部活动，等上传后由服务端重新安排。关闭总开关或撤回许可会结束活动并 `DELETE /devices/{id}`；离线时持久重试，成功前不清除凭据。
- 后台：App 被系统唤醒时更新正在显示的活动，并在最近一个活动结束时刻申请一次后台刷新，用来收起没收到结束推送（离线）的活动。

## HTTP 契约

前缀 `/v2/live-activity`。所有设备写入和状态查询带 `X-Device-Secret`；首次注册可由客户端先生成并保存 secret，首次响应丢失后仍能认证重试。

| 方法 | 路径 | 内容 |
|---|---|---|
| POST | `/devices` | `installationId`（与可选 `deviceID` 相同）、`bundleID`、`environment`、可选 `startToken` |
| PUT | `/devices/{id}/timetable` | 上传课表，见 `server-scheduled-reminders.md` §3；同 revision 同内容幂等，旧 revision 或同 revision 不同内容 409；关注的分享不存在 404。返回 `{revision, pushMode, following, conflicts, omitted, pendingCount}` |
| POST | `/devices/{id}/claims` | `{"slots": n}`（0–16），返回 `{"claims": [{occurrenceId, dateKey, reminder, start, end, pushMode, scheduleScope, scheduleVersion, channel, shared}]}`：新认领的 n 节加上之前认领仍未结束的 |
| DELETE | `/devices/{id}/claims/{occurrenceId}` | 交还一节本地预约不了的课，服务端重新负责 |
| PUT | `/devices/{id}/activities/{occurrenceId}` | `{"token": "…"}`；未知或已结束的活动 404 |
| DELETE | `/devices/{id}/activities/{occurrenceId}` | 停止该活动的刷新 |
| GET | `/devices/{id}` | `pendingCount`、`history`（账本）、`timetableRevision`、`pushMode`、`following` |
| DELETE | `/devices/{id}` | 幂等墓碑，删除课表、令牌和关注关系，保留账本防止重发 |

启动推送的 attributes：`dateKey`、`protocolVersion=2`、`scheduleScope`（关注时为手机上传的分享 scope）、`occurrenceId`、`scheduleVersion`、`reservationStart`、`reservationEnd`、`reminderDate`，频道模式 `broadcastChannel`，令牌模式 `pushMode: "token"`，有对方的课时 `shared`（`{course, first, last, start, end, name, teacher, location}`，超过 3900 字节先去文字再去整个列表）。content-state 只是时间标记。

### 时间编码

- 上传、认领、`shared`、APNs 的 `timestamp` / `stale-date` / `dismissal-date`、ContentState 的时间：Unix 秒。
- attributes 的 `reservationStart`、`reservationEnd`、`reminderDate` 为 Swift Codable Date 的 2001 参考秒，服务端转换为 `unix - 978307200`。
- 服务端排程按 UTC+8 解释日期与节次。

## 服务端

- `live_activity_schedule.py`：引擎，按天从课表（和关注的分享快照）算出活动。occurrence ID 是「设备 + 开场课程 + 日期 + 节次」的 UUIDv5，重算不变。
- `live_activity_v2.py`：今明两天的排程只在内存里（启动、上传、UTC+8 零点、关注的分享变化时重算）；库里是设备、课表、令牌、频道和结果账本 `la_starts`（已有人负责的课：本机预约 `local`，或服务端发过的启动）。发送前先写 `submitting`；408/429/5xx 可重试时删掉这行稍后再试；结果不明记 `submissionUnknown`，不重发；重启时遗留的 `submitting` 转为 `submissionUnknown`。改动后换了编号的课如果和已开始的活动时间重叠，不再发送。
- 令牌模式的刷新在内存里排队：同一活动只发最新到期的一次；可以重试的失败按 10 → 60 秒退避，直到下一次刷新取代它；410 / `BadDeviceToken` / `DeviceTokenNotForTopic` 删除令牌；重启后先补发当前画面再继续。
- 频道：上传的节次与学校当前作息完全一致、且不关注分享时走学校频道（`pushMode: channel`），上下课由公共广播刷新；频道键包含 Bundle ID、环境、学校、作息、版本、最终节次，承诺 8 天广播，夜间任务续期。其余一律令牌模式。
- 迁移第 6 版把旧 `la_start_jobs` 中已经发出或交给本地预约的行搬进账本，删除 `la_start_jobs` 与 `la_token_updates`。
- 单进程：数据库旁的进程锁禁止第二个调度器；网络请求在写事务外，APNs 设备推送与广播各用一条 HTTP/2 连接多路复用。

## 运行

远程令牌用 Fernet 加密，密钥通过 `NAPTABLE_LA_TOKEN_KEY_PATH` 指定，保存在数据库和 release 目录之外。先部署服务端，再发布客户端；这一版客户端只能配合这一版服务端使用。

## 验证

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
bash tests/check-live-activity.sh
bash tests/check-live-activity-service.sh
```

加密集成检查需要安装 `server/requirements.txt`，缺少依赖时该项跳过。另需执行真实 Xcode SDK 构建。

仍需真机验收：用户划掉 App 后本地预约开始时 App 是否仍被拉起、低电量模式、远程启动后拿到令牌的耗时、共享课表更新后不打开 App 也按新课表提醒；以及锁屏、后台、断网恢复和容量压测。APNs 200 只代表接受。

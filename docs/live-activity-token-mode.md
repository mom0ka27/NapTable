# Live Activity 令牌模式（共享课表 + 关心）

> 更新（2026-09-23）：iOS 26 不再用 `.token` 本地预约，改为与 iOS 18 相同的远程启动（`input-push-token`），因为官方文档没有保证 pending 预约会下发更新令牌。下文 §3 的 iOS 26 小节与 §8、§10 中相应条目已被取代，现状以 `live-activity-v2.md` 为准。

基线：`live-activity-v2.md`、`naptable-live-activity-migration.md`。本文是实现规格，交给实现者照做；未写到的行为一律沿用 v2 现状。

## 1. 背景与目标

v2 的活动只订阅一个「作息版本 + 最终节次」广播频道，服务端在该学校每个上下课时刻推一次公共边界，Widget 收到后按本地快照重画。

关心共享课表时，实时活动跟随对方的课表，并把自己同时在上的课作为 `companion` 合并显示（见 `LiveActivityTimeline.attach`）。对方和自己不同校时，自己上下课的时刻不在对方学校的频道边界上，灵动岛要等到对方下一个边界才会出现/去掉合并行。

目标：**关心共享课表时，所有实时活动改用每活动推送令牌（token 模式），服务端在该活动每个需要重画的时刻单独推送；其余情况保持频道广播，行为与成本不变。**

非目标：

- ~~不改变「关心时实时活动只跟随共享课表、自己的课只作 companion」的产品规则；不做两张课表的并集提醒。~~（2026-09-24 已取代：关心时两张课表合在一起提醒，见 `docs/FEATURES.md` 与 `LiveActivityTimeline.build(mergesOwn:)`；令牌模式计划改为按时间放置 item。）
- 不改频道模式的任何协议、表结构或推送节奏。
- 不做 HTTP/2 多路复用或连接池（见 §9 容量）。

## 2. 模式判定

- `pushMode = "token"`：当前提醒快照是共享课表，即 `NativeScheduleSnapshot.sourceLabel != nil`（`ScheduleStore.snapshot()` 只在关心共享课表时设置它）。
- 其余一律 `pushMode = "channel"`。

共享课表与本机课表的 `scheduleScope` 不同，切换关心本身就会换 scope，现有的 `end()` / `invalidatePlan()` 路径会结束旧活动、取消旧计划。因此**模式随 scope 切换，不存在同一 scope 内两种模式并存**。控制器新增只读属性 `pushMode`，由 `currentScheduleMetadata` 推出，不单独持久化。

## 3. 数据流

### iOS 26 及以上：本地预约

1. `reserve()` 与现在相同地逐 occurrence 预约，但 token 模式下：
   - `pushType: .token`，不取 `mapping.channels`；attributes 的 `broadcastChannel` 为 `nil`，`pushMode = "token"`。
   - 仍要求 `mapping`（节次/时区校验与 `createBefore` 等约束不变），仍要求 `handoffConfirmed`。频道缺失不再是 token 模式的失败原因。
2. `request` 返回后立即对该 `Activity` 订阅 `pushTokenUpdates`。每收到一个令牌，经 `LiveActivityPushService` 上传（§4.3）。
3. App 每次 `foreground()` / 冷启动 / 后台刷新时，遍历 `Activity.activities` 中 `pushMode == "token"` 且未结束的实例，重新订阅其 `pushTokenUpdates`（令牌可能轮换，旧订阅随进程消失）。

> 需要真机验证：pending（尚未到 `start:` 时刻）的预约活动是否立即下发令牌。若要等到开始才下发且此时 App 不在运行，就拿不到令牌，见 §6 回落。

### iOS 18：远程启动

1. 计划上传时带 `pushMode: "token"`（§4.1）。服务端为这些 start 任务生成 `"input-push-token": 1` 而不是 `input-push-channel`，attributes 里 `pushMode: "token"`、不含 `broadcastChannel`。
2. App 在 `LiveActivityPushService.activate()` 中订阅 `Activity<ScheduleLiveActivityAttributes>.activityUpdates`：对每个新出现且 `pushMode == "token"` 的活动订阅 `pushTokenUpdates` 并上传。系统远程启动后会短暂唤醒 App 让它取令牌（需真机验证时效）。
3. 同样在前台/冷启动时补订阅（同 iOS 26 第 3 步）。

### iOS 17

不变：只有前台本地提醒，没有令牌模式。

## 4. 协议

### 4.1 计划（`PUT /devices/{id}/plan`）

- 新增**可选**顶层字段 `pushMode`，取值 `"channel"` 或 `"token"`；缺省等同 `"channel"`。
- 客户端只在 token 模式发送该字段（channel 模式的请求体与现在逐字节相同，保证 digest/revision 不因升级而变化）。
- `validate_plan` 的 `allowed` 集合允许该可选键，取值非法返回 400。`pushMode` 参与 digest。
- `_materialize`：token 模式的 start payload
  - `aps` 中写 `"input-push-token": 1`；
  - `attributes` 增加 `"pushMode": "token"`；
  - 不创建/引用频道，`la_start_jobs.channel_key` 写空串。`dispatch_starts` 的查询目前 `JOIN la_channels`，需改为 `LEFT JOIN` 并对 token 任务跳过 `channel_state` 检查、不写 `input-push-channel` / `broadcastChannel`。
  - token 模式不延长 `la_schedule_versions.broadcast_until`（它只服务频道广播承诺）。

### 4.2 Attributes

`ScheduleLiveActivityAttributes` 增加可选 `pushMode: String?`（`nil` 视为 channel，兼容已存在的活动与服务端旧 payload）。`init` 增加对应参数，默认 `nil`。`reserve()` 里用 `==` 比较 attributes 判断「已有同一预约」，构造时必须一致地填入该字段。

### 4.3 活动令牌与刷新时刻

新端点，均需 `X-Device-Secret`：

| 方法 | 路径 | 内容 |
|---|---|---|
| PUT | `/devices/{id}/activities/{occurrenceId}` | 注册/替换该活动的令牌与刷新时刻，幂等 |
| DELETE | `/devices/{id}/activities/{occurrenceId}` | 取消该活动所有未发送更新，幂等 |

PUT 请求体（严格键集合，额外键 400）：

```json
{
  "token": "<hex>",
  "dateKey": "2026-09-22",
  "refreshAt": [1790000000, 1790003000],
  "end": 1790006000
}
```

- `token`：十六进制，长度 16–512；用 `TokenVault.seal` 加密存储，日志与 `health()` 不得出现明文。
- `refreshAt`：Unix 秒、严格递增、去重，最多 64 个，每个须满足 `now - 60 <= t < end`；只含时间，不得有任何课程字段。
- `end`：Unix 秒，`now < end <= now + 8 * 86400`，且 `end - min(refreshAt ∪ {now}) <= 8 * 3600`。
- 设备 `revoked` 返回 409。`mode` 为 local 或 remote 都接受（iOS 26 在 local 模式下使用本端点）。
- 替换语义：同一 `(device, occurrence)` 的 PUT 原子地替换令牌，并把该活动所有未发送的 update/end 任务替换为新列表；已发送的任务保持。
- 响应：`{"occurrenceId": ..., "pending": <未发送任务数>}`。

客户端计算 `refreshAt`（放在 `LiveActivityOccurrence` 上的纯函数，便于测试）：

- 取该 occurrence 所有 frame 的 `from`，去掉第一个 frame 的 `from`（活动开始时已按它渲染），加上所有 frame 之间的空档边界（前一 frame 的 `until` 与后一 frame 的 `from` 不同的情况）；丢弃 `< now - 60` 的值；排序去重。
- `end = occurrence.end`。
- 这组时刻正好是显示会变化的时刻：上课开始、分节课间、`companion` 出现/消失（`attach` 已在自己课程的边界切分 frame）。

何时上传：

- 收到新令牌（含轮换）时。
- `rebuild()` 之后，对仍在进行或 pending 的 token 活动，若其 occurrence 的 `refreshAt` / `end` 变化（例如自己改了课表，companion 边界变了）则重新 PUT；未变则不发请求。上传状态记在 App Group 的小账本里（occurrenceId → 上次上传的 token + refreshAt 摘要），与现有 ledger 分开存。
- 活动被结束/移除、或 occurrence 从 display 中消失时 DELETE（失败可丢弃：服务端任务会随 `end` 过期）。

## 5. 服务端

### 5.1 表

```sql
CREATE TABLE IF NOT EXISTS la_activity_tokens (
 device TEXT NOT NULL, occurrence TEXT NOT NULL, token TEXT NOT NULL,
 day TEXT NOT NULL, end_at REAL NOT NULL, updated_at REAL NOT NULL,
 PRIMARY KEY(device, occurrence)
);
CREATE TABLE IF NOT EXISTS la_token_updates (
 device TEXT NOT NULL, occurrence TEXT NOT NULL, fire_at REAL NOT NULL,
 event TEXT NOT NULL,              -- 'update' | 'end'
 expires_at REAL NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending',  -- pending/sending/sent/superseded/expired/cancelled/failed
 attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0, detail TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(device, occurrence, fire_at)
);
CREATE INDEX IF NOT EXISTS la_token_due ON la_token_updates(state, fire_at, next_attempt);
```

放进 `live_activity_v2.SCHEMA`，按现有迁移方式追加（`la_v2_migrations` 记一个新版本号）。

每个 `refreshAt` 生成一条 `update`，`end` 生成一条 `end`。`expires_at` = 下一条任务的 `fire_at`（最后一条 update 用 `end`；`end` 任务用 `end + 60`）。

### 5.2 发送循环

在 `Service.start()` 的 worker 列表里加 `('token-updates', self.dispatch_token_updates, 1)`。逻辑：

1. 取 `state='pending' AND fire_at<=now AND next_attempt<=now` 的任务，按 `fire_at` 升序，每批最多 200。
2. 同一活动若有多条已到期，只发最新一条，更早的标 `superseded`（和广播「同刻去重、end 优先、不补发更早 update」一致）。
3. `expires_at <= now` 的标 `expired`，不发。
4. 设备 `revoked` 或活动令牌行不存在 → `cancelled`。
5. payload：

   ```json
   {"aps": {"timestamp": <fire_at>, "event": "update",
            "content-state": {"broadcastDateKey": "<day>", "broadcastTimestamp": <fire_at>,
                              "updatedAt": <fire_at>, "startDate": <fire_at>, "endDate": <fire_at>},
            "stale-date": <fire_at + 60>}}
   ```

   `end` 事件把 `"event"` 设为 `"end"`，用 `"dismissal-date": <fire_at>` 取代 `stale-date`。content-state 只含时间标记，和频道广播的 `public_state` 同构但不带节次；Widget 的 v2 路径不读它，只按本地快照渲染。
6. 调用 `client.push(token, payload, push_type="liveactivity", priority=10, expiration=expires_at, collapse_id=occurrence[:64], topic=bundle + ".push-type.liveactivity")`。
7. 结果：200 → `sent`；410，或 400 且 reason 为 `BadDeviceToken` / `DeviceTokenNotForTopic` → 删除该令牌行、该活动未发任务标 `cancelled`；408/429/5xx/`notSent`/`unknown` → 退避重试（`5 * 2**attempts`，上限 60 秒），直到 `expires_at`。update 幂等（内容由本地快照决定），**可以**重发，这点与 start 不同。
8. 每轮顺带清理：`end_at < now - 86400` 的令牌行及其任务。

### 5.3 其他

- `forget()` / `handoff()` 不影响 token 任务的语义：forget 时删除该设备所有令牌行、取消未发任务；handoff 保留（iOS 26 就是在 local 模式下使用）。
- `health()` 增加 token 任务计数（按 state 聚合），不含令牌。
- 路由加在 `live_activity_v2.handle` 的 `devices/{id}/...` 分支：`tail == 'activities/<occurrence>'`，occurrence 用现有 `identifier()` 校验。

## 6. 回落与边界

- **拿不到令牌**：活动收不到任何远程更新，只在 App 前台/后台刷新时由 `reconcile` / `reconcileInBackground` 本地更新。实现一个低成本兜底：token 模式下本地 `activity.update` 时，把 `staleDate` 设为该 occurrence 下一个 `refreshAt`（而不是 `end`），让系统至少在下一个显示变化时刻重画一次。
- **令牌上传失败**：随 `LiveActivityPushService` 现有的串行 worker 与 30 秒重试；不阻塞计划同步。
- **切回不关心 / 取消关心**：scope 变化 → 结束所有活动；为每个 token 活动发 DELETE（尽力而为）。
- **服务端旧版本**：旧服务端会以 400 拒收带 `pushMode` 的计划、404 拒绝 activities 端点。客户端遇到这两种错误时在设置页显示「服务端尚不支持共享课表的实时刷新，暂时只提醒共享课表的课」，并**回落到 channel 模式**（本次会话内），保证至少不比现在差。部署顺序仍应先服务端后客户端。
- **iOS 18 远程启动任务里 token/channel 混杂**：不会发生——模式随 scope 走，换 scope 时旧计划被取消。

## 7. 隐私与文档

token 模式下服务端会知道这台设备某个活动需要在哪些时刻重画（仅时间，不含课程名、教师、地点）。需要同步修改：

- `docs/live-activity-v2.md`：「网络计划和 APNs 不含课程名…」一段补充 token 模式上传的内容与原因；HTTP 契约表加新端点；计划字段加 `pushMode`。
- `docs/FEATURES.md` 实时活动一节：关心共享课表时由服务端逐个推送刷新。
- `server/README.md`：新表、新 worker、容量说明。
- App 内隐私说明（如有列举上传内容的位置，`grep -rn "不含课程" NapTable` 查找）：补一句「关心共享课表时，还会上传实时活动需要刷新的时间点」。遵守 `AGENTS.md` 的 iOS 版本命名规则。

## 8. 测试

Python（`tests/test_live_activity_v2.py` 增补，沿用其中的 fake client 与时钟）：

- 计划 `pushMode` 缺省/`channel`/`token`/非法值；缺省与显式 `channel` 物化结果与现在一致；digest 包含 `pushMode`。
- token 计划的 start payload：有 `input-push-token: 1`，无 `input-push-channel` / `broadcastChannel`，attributes 含 `pushMode`；频道未就绪时 token start 仍会发送。
- activities PUT：鉴权、严格键、令牌格式、`refreshAt` 排序/上限/范围、`end` 范围、8 小时限制、revoked 409、local 模式可用；替换语义只动未发送任务。
- 发送循环：到点发送、同活动多条到期只发最新、end 优先、过期不发、410 删除令牌并取消后续、429/5xx 在有效期内重试、DELETE 后不再发送、forget 后不再发送、payload 不含任何课程字段、日志/health 不含明文令牌。

Swift（`tests/NativeLiveActivityChecks.swift`，扩充 `tests/fixtures/ActivityKit.swift`：`request` 记录 `pushType`，`Activity.pushTokenUpdates` 可由测试注入，`activityUpdates` 可注入）：

- 共享快照（`sourceLabel != nil`）在 iOS 26 路径下以 `.token` 预约、attributes `pushMode == "token"`、`broadcastChannel == nil`；本机快照仍为 `.channel(...)` 且 `pushMode == nil`。
- 注入令牌后发出一次 PUT，`refreshAt` 等于期望的 frame 边界（含 companion 切分点），`end` 正确；相同内容重复 rebuild 不重复 PUT；改自己课表导致 companion 变化时重新 PUT。
- `refreshAt` 纯函数的单元检查（空档、分节模式、companion 切分、丢弃过去时刻）。
- 旧服务端 400/404 时回落 channel 模式。

回归：`tests/` 下全部 `check-*.sh` 与 `python3 -m unittest discover -s tests -p 'test_*.py'`；`xcodebuild -project NapTable.xcodeproj -scheme NapTable -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`。

## 9. 容量（记录，不在本次实现）

（已实现，2026-09-23）逐设备推送与公共广播各用一条 HTTP/2 连接多路复用，同一时刻的一批约一个往返时延，详见 `server/README.md`。以下为原始记录：逐设备推送每环境单连接串行发送，吞吐约为 1 / 往返时延。token 模式推送量 ≈ 关心用户数 × 每天约 12 条，集中在上下课时刻。几百人以内延迟可忽略；到上千人同一时刻需要连接池或提前发送（`stale-date` 设为真实边界）。本次只在 `server/README.md` 记下这条上限。

## 10. 真机验收（实现者无法完成，列给维护者）

1. iOS 26：pending 预约的 token 活动是否立即下发 `pushTokenUpdates`；若否，开始时刻 App 未运行能否拿到。
2. iOS 18：远程启动后 App 是否被唤醒并在数秒内上传令牌。
3. 跨校关心：自己上课开始/结束时灵动岛合并行按时出现/消失。
4. 令牌轮换后更新仍能送达；取消关心后不再收到该设备的推送。

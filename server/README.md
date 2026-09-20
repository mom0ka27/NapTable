# NapTable 服务端

服务端把配置拆成三个明确层级：每所学校的节次时间只配置一次；每个学期只保存第一周周一、总周数和“当前学期”标记；调休表全局统一，对所有学校生效。App 启动和回到前台时会自动拉取学校的当前学期配置，供课表、小组件和实时活动使用。管理员令牌只用于服务端管理，不填写到 App 中。

## 本地启动

需要 Python 3，无第三方依赖。在项目根目录执行：

```sh
export NAPTABLE_ADMIN_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
python3 server/naptable_server.py --host 0.0.0.0 --port 8787 --db naptable.sqlite3
```

请把管理员令牌保存在你的服务部署环境中；更新配置的命令需要使用同一个令牌。SQLite 数据库保存学校配置与分享记录，重启时继续指定同一数据库路径。

健康检查：

```sh
curl --fail http://127.0.0.1:8787/health
```

## 生产部署

仓库的 `deploy/` 目录包含线上运行所需的固定配置：

- `naptable.service`：以独立的 `naptable` 用户运行服务，只监听 `127.0.0.1:8787`；
- `nginx.conf`：为 `naptable.mom0ka27.top` 提供 HTTPS、HTTP 跳转、请求限速和 1 MiB 请求体上限；
- `naptable-backup.service` / `.timer`：每天对 SQLite 做一致性备份，保留最近 14 份；
- `reload-nginx-after-renewal.sh`：Let's Encrypt 证书更新后重新加载 Nginx。

线上代码目录为 `/opt/naptable/current`，数据库为 `/var/lib/naptable/naptable.sqlite3`，备份位于 `/var/backups/naptable`。管理员令牌保存在仅 root 可读的 `/etc/naptable/naptable.env`，不要写入代码仓库或 App。APNs `.p8` 同样只应保存在服务器上，并通过管理页配置其绝对路径。

从开发机一键发布并验证：

```sh
./deploy/deploy.sh nap
```

脚本先运行全部 Python 服务端测试，再创建版本化 release、备份数据库、原子切换 `/opt/naptable/current` 并检查内外网健康接口。启动失败会自动恢复上一 release。设置 `NAPTABLE_SKIP_TESTS=1` 可跳过重复测试，`NAPTABLE_DOMAIN` 可覆盖默认域名。

`.github/workflows/deploy-server.yml` 会在 `main` 分支的 `server/`、`deploy/` 或 Python 服务端测试发生变化时执行相同流程。启用前需要在 GitHub Actions 配置三个 repository secrets：

- `NAP_SSH_TARGET`：例如 `root@naptable.mom0ka27.top`；
- `NAP_SSH_PRIVATE_KEY`：专用于部署的 SSH 私钥；
- `NAP_SSH_KNOWN_HOSTS`：经过核对的目标机 `known_hosts` 记录。

数据库、`/etc/naptable/naptable.env` 与 `/etc/naptable/keys/` 均位于 release 目录之外，连续部署不会覆盖业务数据或 APNs 凭据。

App 的服务地址固定为 `https://naptable.mom0ka27.top`，写死在 `NapTable/Models/SchoolConfiguration.swift` 的 `serverURLString`，设置页只做展示，不可修改。调试本地服务端需要改这一行并重新编译。

分享码只在生成它的服务端有效，双方需要连接同一个服务端。

## 网页管理

启动服务后，浏览器打开 `http://127.0.0.1:8787/admin`。网页与 API 由同一个 Python 进程提供，无需安装 Node.js 或运行前端构建命令。如果服务已在运行，更新代码后需重启服务进程。

1. 在页面输入启动服务时设置的 `NAPTABLE_ADMIN_TOKEN`。
2. 在「学校配置」中填写学校名称并维护该校共用的节次时间。
3. 新增学期，只填写第一周周一、总周数，并将正在使用的学期设为当前学期。
4. 在「统一调休」维护所有学校共用的放假、补班日期。
5. 在「APNs 推送」保存凭据，服务端会自动为每所学校创建 production 和 sandbox 频道。
6. 在「使用统计」查看各学校已注册且启用的去重设备数。

管理员令牌仅在当前页面使用，刷新页面后需要重新输入；不放入网址或浏览器持久存储。学校目录 `/v1/schools` 可公开读取，管理接口必须携带正确令牌。修改学校节次或统一调休时，相关学期版本会递增；已经生成的分享继续保留其原版本快照。

## 实况通知推送（不打开 App 也能启动）

iOS 不允许 App 在后台调用 `Activity.request`，所以课前那一刻如果 App 处于挂起状态，锁屏上不会有任何东西。iOS 17.2 起系统提供 push-to-start 令牌：设备把令牌交给服务端，服务端到点用 APNs 推送启动实时活动，全程不需要打开 App。

分工是固定的：**内容由 App 渲染，服务端只负责定时和转发**。App 把接下来一周的每一帧（提前量、课间常驻、各种文案都已经算好）连同该推送的时刻上传为一份「计划」，服务端存下来、到点转给 APNs。服务端不解析课表，也不改写 `content-state`。

### 准备 APNs 密钥

在 Apple Developer 后台 Certificates → Keys 新建一个启用了 Apple Push Notification service 的密钥，下载 `AuthKey_XXXXXXXXXX.p8`（只能下载一次），记下 Key ID 与 Team ID。App 的 target 需要打开 Push Notifications 能力，`NapTable/NapTable.entitlements` 里已经写了 `aps-environment`。

### 在 WebUI 配置 APNs

```sh
export NAPTABLE_ADMIN_TOKEN="请换成随机管理员令牌"
python3 server/naptable_server.py --host 0.0.0.0 --port 8787 --db naptable.sqlite3
```

打开 `http://服务器地址:8787/admin`，输入管理员令牌，在「APNs 推送」中填写 `.p8` 文件路径、Key ID、Team ID、Bundle ID 和调度间隔并保存。配置保存在 `naptable.sqlite3`，保存后立即生效；四项凭据缺一项会被拒绝，四项都留空则关闭推送。凭据有效时，服务端自动为目录中的每所学校创建 production 和 sandbox 频道，新增学校时也会补建；管理页可查看映射并手动触发重新同步。`/v1/live-activity/health` 的 `pushConfigured` 会反映当前状态。

旧部署仍可用 `NAPTABLE_APNS_KEY_PATH`、`NAPTABLE_APNS_KEY_ID`、`NAPTABLE_APNS_TEAM_ID`、`NAPTABLE_APNS_BUNDLE_ID`、`NAPTABLE_APNS_TICK_SECONDS` 和 `NAPTABLE_APNS_CHANNELS_JSON` 环境变量启动；一旦在 WebUI 保存配置，数据库配置优先。

### 学校级 Broadcast Push（iOS 26+）

iOS 18 的频道只能更新或结束已经存在的 Live Activity，不能在后台广播启动活动；因此 App 的 iOS 18–25 路径仍然使用逐设备 push-to-start。iOS 26+ 使用 Scheduled Live Activity 在设备上安排当天/次日的活动，再订阅学校频道。服务端每个节次边界只发一次广播，推送内容只有日期、节次、阶段和时间戳，Widget 从 App Group 的本地课表决定显示哪门课。

频道由服务端通过 Apple Broadcast Push channel management API 自动创建。每个学校、每个 APNs 环境各维护一个 `LiveActivity` 频道，并保存 APNs 返回的频道 ID。频道不能跨 sandbox/production 复用。

App 注册设备时会上传 `schoolID`、`termID` 和系统环境；服务端返回匹配的频道 ID。没有匹配频道时自动回退到旧的逐设备计划。

广播接口使用 APNs 的 `/4/broadcasts/apps/<bundle-id>` 端点和 `apns-channel-id` 请求头，`apns-expiration` 固定为 `0`，避免过期的上课边界在恢复联网后补发。APNs 的广播能力还需要在 Apple Developer 侧为 App ID 开通，不能通过 Xcode 的 Push Notifications 开关代替。

沙盒与生产由设备上报：开发证书签出来的包发到 `api.sandbox.push.apple.com`，TestFlight 与 App Store 包发到 `api.push.apple.com`。App 读取自己的描述文件判断，不靠编译配置猜。

推送客户端是 `server/apns.py`，同样只用标准库：标准库既没有 HTTP/2 客户端也没有 ECDSA，所以 ES256 签名（RFC 6979 确定性 k）、HPACK 和 HTTP/2 帧层都在这个文件里手写，只覆盖 APNs 实际用到的那一小块。签名对齐 RFC 6979 A.2.5 标准向量，见 `tests/test_apns.py`。

### 客户端流程

App 的「设置 → 实时活动 → 显示实时活动」打开即生效，没有单独的推送开关。之后：

1. 系统下发 push-to-start 令牌，App `POST /v1/live-activity/devices` 注册，服务端返回一次性的 `deviceID` 与 `secret`（之后所有设备接口都用 `X-Device-Secret`）。
2. App 每次课表或实时活动设置变化时 `PUT /v1/live-activity/devices/{id}/plan` 上传计划；内容没变就不重传。
3. 服务端到点推送 `start`；系统启动实时活动并在后台唤起 App，App 把这个活动的更新令牌 `POST` 到 `/activities`，服务端据此继续推送 `update` 和 `end`。
4. 关闭开关会 `DELETE /v1/live-activity/devices/{id}`，服务端删掉该设备的令牌、计划和活动记录。

一条计划项过期（它描述的那一帧已经结束）就直接丢弃而不是迟发，否则会把已经下课的课程重新放回锁屏。`BadDeviceToken` / `Unregistered` 这类回执会让服务端主动清掉对应令牌。

```sh
curl --fail http://127.0.0.1:8787/v1/live-activity/health
```

原有的 `BGTaskScheduler` 路径没有去掉：推送不可用（没配密钥、断网、用户关掉开关）时，行为和以前完全一样。

## 分享课表

一个分享是「一份课程 + 发布时那个学校学期的完整时间配置」的快照。读的人只要分享码，不需要和分享者在同一所学校，也不需要本机有那所学校的配置——节次时间、第一周周一、总周数和调休都随分享一起下发。

| 方法 | 路径 | 凭据 | 说明 |
| --- | --- | --- | --- |
| POST | `/v1/shares` | 无 | 创建。返回一次性的 `writeToken` |
| GET | `/v1/shares/{code}` | 无 | 读取完整课表与时间配置 |
| GET | `/v1/shares/{code}/meta` | 无 | 只读元信息，不含课程；用来判断要不要重新下载 |
| PUT | `/v1/shares/{code}` | `X-Write-Token` | 用新课程覆盖；不写 `schoolID`/`termID` 就留在原学期 |
| POST | `/v1/shares/{code}/resync` | `X-Write-Token` | 按学校当前的学期配置重新固化时间，课程不动 |
| DELETE | `/v1/shares/{code}` | `X-Write-Token` | 撤销 |

### 配置所有权与分享快照

服务端按学校保存节次时间，按 `(学校, 学期)` 保存第一周和总周数，调休表则全局统一。创建或更新分享时，三部分会组合后**固化**进分享本身：

```sh
curl --fail http://127.0.0.1:8787/v1/shares/ABCD1234
```

```json
{
  "id": "ABCD1234", "owner": "张三", "name": "张三 · 东南大学",
  "schoolID": "seu", "termID": "2026-fall", "termVersion": 3,
  "semester_start_monday": "2026-09-07",
  "term_week_count": 20,
  "class_time_list": [{"id": 1, "name": "第1节", "start": "07:50", "end": "08:35"}],
  "calendar_adjustments": [{"date": "2026-10-11", "kind": "swap", "source": "2026-10-09"}],
  "courses": [...]
}
```

固化是有意的：管理员事后修正某个学校的作息，不会让已经发出去的分享里所有人的课悄悄挪位。想要那份修正时，由分享的持有者调用 `resync`（App 里是「同步校历时间」），服务端才按学校当前版本重新固化，课程内容不变。

### 统一调休

`POST /v1/admin/calendar` 的 `adjustments` 按**日期**覆盖课表，对所有学校生效：

```json
"adjustments": [
  {"date": "2026-10-01", "kind": "off",  "note": "国庆节"},
  {"date": "2026-10-11", "kind": "swap", "source": "2026-10-09", "note": "上周四的课"}
]
```

`off` 是这天不上课，`swap` 是这天改上 `source` 那天的课。`swap` 不写 `source`（或日期非法）会被拒绝而不是当成放假。统一调休会注入每个学校的公开学期响应，也会随分享固化下发，以兼容旧客户端并保证历史分享不漂移。

### 限制

课程最多 600 门、序列化后不超过 256 KiB，每门必须有名称；统一调休最多 200 条。`owner` 超长截断到 40 字，留空记为「匿名」。学校名以服务端目录为准，不采信客户端上传的那一份，所以读的人看到的是「南京大学」而不是 `nju`。

## 管理边界

共享服务目录内同时保留 `cpu` 学校，供 CPU iOS 客户端使用同一套设备、计划和 APNs 调度；NapTable App 会在客户端过滤该学校，因此不会提供 CPU 课表导入或分享入口。设备注册携带各 App 的 `bundleID`，服务端按设备 Bundle ID 生成 APNs topic，NapTable 与 CPU 可以共用同一套 APNs 密钥。

学校配置读取不需要管理员令牌，修改需要 `X-Admin-Token` 与服务进程的 `NAPTABLE_ADMIN_TOKEN` 一致。未设置令牌时，学校管理接口保持只读。

创建分享返回的 `writeToken` 是该分享的管理凭据，更新和撤销使用 `X-Write-Token`；查看课表只需分享码。不要把管理员令牌用作分享令牌。

NJU 内置值用于演示，必须根据实际校历和作息核对后再使用，不能视为已核实的官方配置。

## 配置学校、学期与调休

学校节次只提交一次到学校接口：

```json
{
  "name": "南京大学",
  "periods": [
    {"id": 1, "name": "第1节", "start": "08:00", "end": "08:50"},
    {"id": 2, "name": "第2节", "start": "09:00", "end": "09:50"}
  ],
  "note": "经核对的学校作息"
}
```

```sh
curl --fail-with-body -X POST http://127.0.0.1:8787/v1/schools/nju \
  -H "X-Admin-Token: $NAPTABLE_ADMIN_TOKEN" -H 'Content-Type: application/json' \
  --data-binary @nju-school.json
```

每学期只提交第一周、周数和当前标记：

```json
{
  "id": "2026-fall",
  "semesterStartMonday": "2026-09-14",
  "weekCount": 18,
  "timezone": "Asia/Shanghai",
  "current": true,
  "note": "2026 秋季校历"
}
```

```sh
curl --fail-with-body \
  -X POST http://127.0.0.1:8787/v1/admin/schools/nju/terms \
  -H "X-Admin-Token: $NAPTABLE_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @nju-term.json
```

统一调休写入 `/v1/admin/calendar`，统计读取 `/v1/admin/stats`，两者都需要 `X-Admin-Token`。读取公开配置：

```sh
curl --fail http://127.0.0.1:8787/v1/schools
```

同一个学期 `id` 用于更新；新增学期使用新的 `id`。第一周日期必须是周一，时间使用 24 小时制 `HH:mm`，当前时区使用 `Asia/Shanghai`。每所学校始终保留一个当前学期。

App 选择学校导入入口后自动读取配置；没有明确学期时使用服务端的当前学期，并在启动和回到前台时刷新。断网时使用该服务地址的缓存。分享请求只指定学校与学期，服务端把组合后的配置固化到分享快照；客户端也会识别冻结标记，不会用当前学期覆盖已导入的分享。

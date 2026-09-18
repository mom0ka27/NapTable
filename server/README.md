# NapTable 服务端

服务端统一保存学校的学期、第一周周一、总周数和节次时间。App 根据所选的学校导入入口和解析出的学期自动下载配置，供课表、小组件和实时活动使用。管理员令牌只用于服务端管理，不填写到 App 中。

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

App 的「设置 → 学校与分享 → 课表服务与学校配置」中保存服务地址。本机或模拟器使用 `http://127.0.0.1:8787`；同一 Wi-Fi 的 iPhone 使用 Mac 的 `.local` 主机名或局域网地址。真机中的 `127.0.0.1` 指向手机自己。系统询问局域网访问或入站连接时需允许。

分享码只在生成它的服务端有效，双方需要连接同一个服务端。当前命令启动的是本地 HTTP 服务；跨网络使用需自行部署可访问的 HTTPS 服务。

## 网页管理

启动服务后，浏览器打开 `http://127.0.0.1:8787/`。网页与 API 由同一个 Python 进程提供，无需安装 Node.js 或运行前端构建命令。如果服务已在运行，更新代码后需重启服务进程。

1. 在页面输入启动服务时设置的 `NAPTABLE_ADMIN_TOKEN`。
2. 选择学校，或新增学校后填写学校标识和名称。
3. 选择已有学期修改，或新建学期。
4. 填写第一周周一、总周数，逐行编辑各节课的开始与结束时间，可增加和删除节次。
5. 保存配置后，App 下次从对应学校导入课表时自动读取并匹配该学期。

管理员令牌仅在当前页面使用，刷新页面后需要重新输入；不放入网址或浏览器持久存储。未输入正确令牌仍可查看配置，无法保存。每次保存学期由服务端递增版本，已经生成的分享继续保留其原版本快照。

## 实况通知推送（不打开 App 也能启动）

iOS 不允许 App 在后台调用 `Activity.request`，所以课前那一刻如果 App 处于挂起状态，锁屏上不会有任何东西。iOS 17.2 起系统提供 push-to-start 令牌：设备把令牌交给服务端，服务端到点用 APNs 推送启动实时活动，全程不需要打开 App。

分工是固定的：**内容由 App 渲染，服务端只负责定时和转发**。App 把接下来一周的每一帧（提前量、课间常驻、各种文案都已经算好）连同该推送的时刻上传为一份「计划」，服务端存下来、到点转给 APNs。服务端不解析课表，也不改写 `content-state`。

### 准备 APNs 密钥

在 Apple Developer 后台 Certificates → Keys 新建一个启用了 Apple Push Notification service 的密钥，下载 `AuthKey_XXXXXXXXXX.p8`（只能下载一次），记下 Key ID 与 Team ID。App 的 target 需要打开 Push Notifications 能力，`NapTable/NapTable.entitlements` 里已经写了 `aps-environment`。

### 启动服务

```sh
export NAPTABLE_APNS_KEY_PATH="$HOME/secrets/AuthKey_ABCD123456.p8"
export NAPTABLE_APNS_KEY_ID="ABCD123456"
export NAPTABLE_APNS_TEAM_ID="XYZ9876543"
export NAPTABLE_APNS_BUNDLE_ID="me.mom0ka27.naptable"
python3 server/naptable_server.py --host 0.0.0.0 --port 8787 --db naptable.sqlite3
```

四个变量缺一个就视为未配置：服务照常接受注册和计划，但不会发推送，`/v1/live-activity/health` 里的 `pushConfigured` 为 `false`，App 的设置页也会直接说「服务端还没有配置 APNs 推送密钥」。`NAPTABLE_APNS_TICK_SECONDS` 可调调度间隔，默认 5 秒。

沙盒与生产由设备上报：开发证书签出来的包发到 `api.sandbox.push.apple.com`，TestFlight 与 App Store 包发到 `api.push.apple.com`。App 读取自己的描述文件判断，不靠编译配置猜。

推送客户端是 `server/apns.py`，同样只用标准库：标准库既没有 HTTP/2 客户端也没有 ECDSA，所以 ES256 签名（RFC 6979 确定性 k）、HPACK 和 HTTP/2 帧层都在这个文件里手写，只覆盖 APNs 实际用到的那一小块。签名对齐 RFC 6979 A.2.5 标准向量，见 `tests/test_apns.py`。

### 客户端流程

在 App 的「设置 → 实时活动 → 由服务端推送启动」里打开。之后：

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

### 每所学校的时间安排各走各的

服务端按 `(学校, 学期)` 保存节次时间、第一周周一、总周数和调休表。创建或更新分享时，这一份配置会被**固化**进分享本身：

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

### 调休

学期配置里的 `adjustments` 按**日期**覆盖课表，用来表达每年单独公布的调休：

```json
"adjustments": [
  {"date": "2026-10-01", "kind": "off",  "note": "国庆节"},
  {"date": "2026-10-11", "kind": "swap", "source": "2026-10-09", "note": "上周四的课"}
]
```

`off` 是这天不上课，`swap` 是这天改上 `source` 那天的课。`swap` 不写 `source`（或日期非法）会被拒绝而不是当成放假——那会让客户端安静地删掉一天的课。调休和节次时间一样按学校、按学期走，也一样随分享固化下发。

### 限制

课程最多 600 门、序列化后不超过 256 KiB，每门必须有名称；调休一个学期最多 200 条。`owner` 超长截断到 40 字，留空记为「匿名」。学校名以服务端目录为准，不采信客户端上传的那一份，所以读的人看到的是「南京大学」而不是 `nju`。

## 管理边界

学校配置读取不需要管理员令牌，修改需要 `X-Admin-Token` 与服务进程的 `NAPTABLE_ADMIN_TOKEN` 一致。未设置令牌时，学校管理接口保持只读。

创建分享返回的 `writeToken` 是该分享的管理凭据，更新和撤销使用 `X-Write-Token`；查看课表只需分享码。不要把管理员令牌用作分享令牌。

NJU 内置值用于演示，必须根据实际校历和作息核对后再使用，不能视为已核实的官方配置。

## 在服务端配置学期与节次

在有管理员令牌的终端准备 JSON 文件，例如 `nju-term.json`。以下是接口格式示例，只有两节示范课；请替换日期、周数并补齐实际全部节次后提交：

```json
{
  "id": "2026-fall",
  "semesterStartMonday": "2026-09-14",
  "weekCount": 18,
  "timezone": "Asia/Shanghai",
  "note": "请替换为经核对的校历与作息",
  "periods": [
    {"id": 1, "name": "第1节", "start": "08:00", "end": "08:50"},
    {"id": 2, "name": "第2节", "start": "09:00", "end": "09:50"}
  ]
}
```

提交到 NJU 的学期管理接口：

```sh
curl --fail-with-body \
  -X POST http://127.0.0.1:8787/v1/admin/schools/nju/terms \
  -H "X-Admin-Token: $NAPTABLE_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @nju-term.json
```

读取配置，确认学期与节次：

```sh
curl --fail http://127.0.0.1:8787/v1/schools
```

同一个 `id` 用于更新该学期；新增学期使用新的 `id`。第一周日期填写周一，时间使用 24 小时制 `HH:mm`。当前首期支持 NJU，时区使用 `Asia/Shanghai`。

App 选择学校导入入口后自动读取配置，优先匹配课表的学年学期；课表没有学期信息时匹配当前学期或最近的即将开始学期。断网时使用该服务地址的缓存，无匹配或匹配不唯一时提示管理员补充配置，不会随意套用其他学校或学期。无需单独同步模板，也不需要填写开学日期和各节课时间。分享请求只指定学校与学期，服务端把对应配置固化到分享快照，防止后续修改学校配置使旧分享的时间悄悄变化。

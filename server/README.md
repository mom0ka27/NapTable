# NapTable 服务端

服务端把配置拆成三个明确层级：每所学校的节次时间只配置一次；每个学期只保存第一周周一、总周数和“当前学期”标记；调休表全局统一，对所有学校生效。App 启动和回到前台时会自动拉取学校的当前学期配置，供课表、小组件和实时活动使用。管理员令牌只用于服务端管理，不填写到 App 中。

## 本地启动

课表/分享服务需要 Python 3；启用 v2 远程实时活动还需安装 `server/requirements.txt` 中的 token 加密依赖。在项目根目录执行：

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

生产环境使用 Python 3.14 和其配套 SQLite（至少 3.35），不替换系统 Python/SQLite。首次准备运行环境（root）：

```sh
curl -LsSf https://astral.sh/uv/install.sh -o /tmp/naptable-uv-install.sh
UV_INSTALL_DIR=/opt/naptable/tools UV_NO_MODIFY_PATH=1 sh /tmp/naptable-uv-install.sh
UV_PYTHON_INSTALL_DIR=/opt/naptable/python-managed /opt/naptable/tools/uv python install 3.14 --no-bin
runtime=$(UV_PYTHON_INSTALL_DIR=/opt/naptable/python-managed /opt/naptable/tools/uv python find --managed-python 3.14)
ln -s "$(dirname "$(dirname "$runtime")")" /opt/naptable/python
/opt/naptable/python/bin/python3.14 -c 'import sqlite3, sys; print(sys.version); print(sqlite3.sqlite_version)'
```

部署脚本验证 Python/SQLite 版本，服务和数据库备份均使用 release 内的虚拟环境。

从开发机一键发布并验证：

```sh
./deploy/deploy.sh nap
```

脚本先运行全部 Python 服务端测试，再创建版本化 release 和独立虚拟环境，安装加密依赖，配置并备份 token 密钥，在数据库副本上预检迁移，停旧调度并最终备份数据库，然后原子切换 `/opt/naptable/current` 并检查内外网健康接口。v2 版本之间启动失败会恢复上一 release；首次 v1 → v2 迁移失败会停止服务并保留现场，不自动重启可能重新产生旧启动任务的 v1。设置 `NAPTABLE_SKIP_TESTS=1` 可跳过重复测试，`NAPTABLE_DOMAIN` 可覆盖默认域名。

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
2. 在「学校配置」点击「新增学校」即可创建并保存，随后维护该校共用的节次时间；「删除学校」会同时删除学期配置，已有分享快照保留。
3. 新增学期，只填写第一周周一、总周数，并将正在使用的学期设为当前学期。
4. 在「统一调休」维护所有学校共用的放假、补班日期；「导入国务院安排」可直接拉取当年的官方放假安排，补班日需要自己选定上哪天的课。
5. 在「APNs 推送」保存凭据，服务端会按客户端签发的作息映射自动维护版本和最终节次频道。
6. 在「使用统计」查看近 30 天各学校的使用设备数，并选择学校查看系统版本、设备型号分布。基础统计独立于实时通知注册，只有同意基础隐私协议的新版客户端才会上报。

管理员令牌仅在当前页面使用，刷新页面后需要重新输入；不放入网址或浏览器持久存储。学校目录 `/v1/schools` 可公开读取，管理接口必须携带正确令牌。修改学校节次或统一调休时，相关学期版本会递增；已经生成的分享继续保留其原版本快照。

## 课程实时活动 v2

完整协议、迁移、测试与已知边界见 [Live Activity v2](../docs/live-activity-v2.md)。

App 保存个人展示内容；服务器只接收课程实例 ID、实际日期和节次，使用不可变学校作息还原启动时间。iOS 18 使用逐设备 push-to-start 并直接订阅最终节次频道；iOS 26 完成远程模式交接后本地预约未来 168 小时，不使用远程兜底。iOS 17 只保留前台本地能力。

在管理页配置 APNs `.p8` 绝对路径、Key ID、Team ID 和 NapTable Bundle ID（`me.mom0ka27.naptable`）。API 仅允许该配置中的 App；频道不跨 App 或 sandbox/production。管理页展示频道健康和失败原因，后台自动创建与回收，无需填写 Apple channel ID。

远程 token 使用 Fernet 认证加密：在运行服务的虚拟环境中安装依赖，把独立 Fernet key 保存在 release/数据库目录之外，通过 `NAPTABLE_LA_TOKEN_KEY_PATH` 指定。文件仅供服务账号读取，并独立备份。未配置该密钥时远程 token 注册返回 503，本地预约设备不受此 token 存储要求影响。

```sh
python3 -m pip install -r server/requirements.txt
# 在安全的配置目录中创建一次；不要把生成的密钥输出到日志或提交到仓库。
python3 -c 'from cryptography.fernet import Fernet; from pathlib import Path; p=Path("/etc/naptable/live-activity-token.key"); p.touch(mode=0o600, exist_ok=False); p.write_bytes(Fernet.generate_key())'
export NAPTABLE_LA_TOKEN_KEY_PATH=/etc/naptable/live-activity-token.key
```

使用 `deploy/deploy.sh` 时会自动配置 `/etc/naptable/keys/live-activity-token.key`，并在 `/etc/naptable/key-backups/` 保存独立的 root-only 备份。已配置的密钥只校验，不覆盖。

新接口前缀 `/v2/live-activity`。旧接口返回 426 提示升级，保留认证撤销及旧日期频道的短期排空。关闭功能采用墓碑并保留提交历史；APNs 响应丢失不会自动重发 start。部署前必须备份数据库，回退不得直接恢复旧 pending 队列。

APNs HTTP/2/JWT 连接实现仍在 `server/apns.py`；缺失 HTTP 状态视为结果不明。单进程调度，独立任务循环、短 SQLite 写事务和进程排他锁；不要通过多 worker 启动同一数据库提升吞吐。

关心共享课表时客户端改用令牌模式：`PUT/DELETE /v2/live-activity/devices/{id}/activities/{occurrenceId}` 上传每个活动的推送令牌与刷新时间点（仅时间），存入 `la_activity_tokens`（令牌以 Fernet 加密，iOS 26 本地预约设备此时同样需要 `NAPTABLE_LA_TOKEN_KEY_PATH`）和 `la_token_updates`；`token-updates` 工作循环每秒按时逐个推送 update/end，管理页健康数据里的 `tokenUpdates` 按状态计数，不含令牌。容量上限：推送客户端每环境单连接串行发送，吞吐约为 1 / 往返时延；令牌模式推送量约为关心用户数 × 每天 12 条，集中在上下课时刻。几百人以内延迟可忽略，上千人同一时刻需要连接池或提前发送。需先部署服务端再发布客户端；旧服务端会让客户端回落到公共广播。

## 分享课表

一个分享是「一份课程 + 发布时那个学校学期的完整时间配置」的快照。读的人只要分享码，不需要和分享者在同一所学校，也不需要本机有那所学校的配置——节次时间、第一周周一、总周数和调休都随分享一起下发。

| 方法 | 路径 | 凭据 | 说明 |
| --- | --- | --- | --- |
| POST | `/v1/shares` | 无 | 首次创建。返回一次性的 `writeToken` |
| POST | `/v1/shares/{code}/replace` | `X-Write-Token` | 有变更时生成新码，同一事务撤销旧码；无变更返回 400 |
| GET | `/v1/shares/{code}` | 无 | 读取完整课表与时间配置 |
| GET | `/v1/shares/{code}/meta` | 无 | 只读元信息，不含课程；用来判断要不要重新下载 |
| PUT | `/v1/shares/{code}` | `X-Write-Token` | 用新课程覆盖；不写 `schoolID`/`termID` 就留在原学期 |
| POST | `/v1/shares/{code}/resync` | `X-Write-Token` | 按学校当前的学期配置重新固化时间，课程不动 |
| DELETE | `/v1/shares/{code}` | `X-Write-Token` | 撤销 |

新客户端按本地课表保存分享凭据，后续生成使用 `replace`，请求体与首次创建相同。课程或实际校历没有变化时禁止重新生成；课程行顺序、本地 ID 和版本计数不视为内容变化。成功后旧码及其 `/meta` 返回 404，失败则保留旧码。升级前同一课表的多条分享可通过 `previousShares: [{code, token}]` 一并撤销，每条均校验写入凭据。服务端需先部署此接口，再发布新版客户端。

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

固化是有意的：管理员事后修正某个学校的作息，不会让已经发出去的分享里所有人的课悄悄挪位。想要那份修正时，由分享的持有者调用兼容接口 `resync`，服务端才按学校当前版本重新固化，课程内容不变。

### 统一调休

`POST /v1/admin/calendar` 的 `adjustments` 按**日期**覆盖课表，对所有学校生效：

```json
"adjustments": [
  {"date": "2026-10-01", "kind": "off",  "note": "国庆节"},
  {"date": "2026-10-11", "kind": "swap", "source": "2026-10-09", "note": "上周四的课"}
]
```

`off` 是这天不上课，`swap` 是这天改上 `source` 那天的课。App 会在月历、周视图表头、小组件和实时活动上标出这一天，补课日的锁屏活动会写明上的是哪天的课。`swap` 不写 `source`（或日期非法）会被拒绝而不是当成放假。统一调休会注入每个学校的公开学期响应，也会随分享固化下发，以兼容旧客户端并保证历史分享不漂移。

### 从国务院安排导入

管理页「统一调休」里的「导入国务院安排」调用 `POST /v1/admin/calendar/import`，采用 CPU-Web 的公开假期来源：优先读取 jiejiariapi，失败或格式异常时回退到 [holiday-cn](https://github.com/NateScarlet/holiday-cn) 和 CDN。管理页按学年读取当年 9 月至次年 7 月（`{"academicYear": 2026}`）；缺失年份显示提示，可稍后重试补齐。旧的 `years` 参数仍可使用：

```sh
curl --fail-with-body -X POST http://127.0.0.1:8787/v1/admin/calendar/import \
  -H "X-Admin-Token: $NAPTABLE_ADMIN_TOKEN" -H 'Content-Type: application/json' -d '{"years":[2026]}'
```

保存后通过学校学期响应的 `adjustments` 下发，并递增学期版本。客户端同步规则后按日期处理放假和跨周补课，原始课程保持原样。

这个接口**只返回预览，不写库**。放假日直接给出 `off` 行；补班日只能给出 `swap` 行和 `source` 为空的 `needsSource` 标记，因为公告只说某个周末要上班，不说上哪一天的课——那是各校自己的通知。`candidates` 是同一个假期里被调休掉的工作日，管理页把它们做成可点选的建议，选定后再点「保存调休」写入。已经配置过的日期原样保留，不会被覆盖。

### 限制

课程最多 600 门、序列化后不超过 256 KiB，每门必须有名称；统一调休最多 200 条。`owner` 超长截断到 40 字，留空记为「匿名」。学校名以服务端目录为准，不采信客户端上传的那一份，所以读的人看到的是「南京大学」而不是 `nju`。

## 管理边界

首次初始化只提供南京大学模板；升级时移除旧版自动内置的中国药科大学配置，管理员自行维护的配置保留。学校删除后重启不会自动恢复。NapTable App 暂时仅显示南京大学，其他导入器保留供后续启用。v2 推送首版仅服务配置中的 NapTable Bundle ID，不将其他 App 的频道、凭据或调度混用。

学校配置读取不需要管理员令牌，修改需要 `X-Admin-Token` 与服务进程的 `NAPTABLE_ADMIN_TOKEN` 一致。未设置令牌时，学校管理接口保持只读。

创建分享返回的 `writeToken` 是该分享的管理凭据，更新和撤销使用 `X-Write-Token`；查看课表只需分享码。不要把管理员令牌用作分享令牌。

NJU 内置值用于演示，必须根据实际校历和作息核对后再使用，不能视为已核实的官方配置。

## 配置学校、学期与调休

`DELETE /v1/schools/{id}` 删除学校及全部学期，需要管理员认证；学校不存在时返回 404。

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

统一调休写入 `/v1/admin/calendar`，从国务院安排预览走 `/v1/admin/calendar/import`，统计读取 `/v1/admin/stats`，都需要 `X-Admin-Token`。读取公开配置：

```sh
curl --fail http://127.0.0.1:8787/v1/schools
```

同一个学期 `id` 用于更新；新增学期使用新的 `id`。第一周日期必须是周一，时间使用 24 小时制 `HH:mm`，当前时区使用 `Asia/Shanghai`。每所学校始终保留一个当前学期。

App 选择学校导入入口后自动读取配置；没有明确学期时使用服务端的当前学期，并在启动和回到前台时刷新。断网时使用该服务地址的缓存。分享请求只指定学校与学期，服务端把组合后的配置固化到分享快照；客户端也会识别冻结标记，不会用当前学期覆盖已导入的分享。

## 基础使用统计与隐私许可

`POST /v1/usage/devices/{installationUUID}` 使用客户端生成的随机 `X-Device-Secret` 作为该安装的写入凭据，首次请求创建记录，之后校验凭据并覆盖设备属性与当前学校。该凭据与实况通知凭据独立，服务端仅存储摘要。

请求仅允许 `consentVersion: 1`、`schoolID`（可为空）、`systemName`、`systemVersion`、`deviceModel`、`appVersion`。不接受课程、姓名等额外字段。服务端记录首次与最近上报时间；客户端同意基础协议后于启动、回前台、学校变化时自动上报，相同属性在同一进程内最多每小时成功上报一次。失败不阻止导入，下次前台或属性变化时重试。

`GET /v1/admin/stats` 仍需管理员认证，返回近 30 天按安装去重的 `totalUsers`、各学校 `users`、`unassignedUsers`，以及全局和各学校的 `systemVersions` / `deviceModels` 分布。学校以当前选中的课表为准，单台安装仅归属一个学校；重装可能重复计数，所以界面同时标注设备数。原始记录在最后上报超过 90 天后，于下一次写入或统计查询时清理；备份保留最近 14 份。不会从旧版实时通知设备记录推断用户已同意隐私协议。

客户端首次进入需明确同意基础统计协议，第二项实时通知上传许可为可选，均默认不勾选。未同意基础协议不挂载主界面或发送统计；同意后需成功导入至少一门课程才完成首次引导，取消或空导入不能跳过。已有课程的升级用户只需补充隐私选择，无需重新导入。实时通知许可同时保护 ActivityKit 控制器和网络协调器；可在设置的「隐私与数据」中撤回，撤回后的网络仅执行旧设备清除，离线时重试。iOS 26+ 本地预约不上传远程课表计划，仍独立参与基础使用统计。

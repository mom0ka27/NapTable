# 共享课表合并提醒服务端发布记录

- 时间：2026-09-24 09:52（Asia/Taipei）
- SSH 目标：`nap`
- Release：`20260924T015235Z-f567cd12-dirty-60115`
- 上一 release：`20260923T150717Z-10b8a036-dirty-20331`
- 来源：分支 `live-activity-v2` 的提交 `f567cd12` 加上未提交改动；没有推送，也没有发布 iOS App。与线上相比，服务端只变了 `live_activity_v2.py` 和 `live_activity_timeline.py`，其余服务端文件与静态资源逐一核对一致。
- 服务地址：https://naptable.mom0ka27.top

内容：

- 令牌模式计划的 item 可以用 `start`/`end`（Unix 秒）代替节次，用来放置读者自己学校作息下的课；频道模式不变。
- `PUT /v2/live-activity/devices/{id}/activities/{occurrenceId}` 新增可选 `alertAt`（`refreshAt` 的子集，最多 16 个）；对应的 update 推送附带与 start 相同的「课程提醒 / 即将上课」提醒。
- 迁移版本 4：`la_token_updates` 新增 `alert` 列（默认 0）。回退到上一 release 安全：旧代码写入时不带该列，取默认值。

部署前 194 项 Python 测试通过（跳过 1 项）。线上 Python 3.14.7、SQLite 3.53.1、cryptography 46.0.7；token 密钥校验并备份；数据库副本迁移预检通过，未发送 APNs 请求。

发布验证：

- systemd：active/running，NRestarts=0，ExecMainStatus=0；最近 10 分钟日志无 worker 报错。
- 数据库：`la_token_updates.alert` 已存在，`la_v2_migrations` 为 2、3、4。
- 公网 `/health`：200 `{"ok": true}`（本机 curl/LibreSSL 仍有 TLS 错误，Python 客户端验证成功）。
- `/v1/live-activity/health`：426。
- `/broadcast-config` 缺 `deviceID`：400；伪造 `deviceID`：403。
- `activities` PUT 无凭据：403。
- 没有创建测试设备或发送人工测试推送；合并提醒与中途提醒的实际效果需新客户端上线后在真机确认（包括远程启动与刷新提醒是否有声音）。

本地与服务器文件 SHA-256 一致：

| 文件 | SHA-256 |
|---|---|
| server/apns.py | 13986c09298b2fa786a68082b6959c45e7df3eed7899c15ae12c4d3cfb3efb23 |
| server/live_activity_v2.py | f67080a27c116d6152c285bbad8ceabe22cf7788bbc8c9b495751c6e046b16f0 |
| server/live_activity_timeline.py | 7b52737545b069aa546838e896d8d4f591ee18c4102147ec84f194dd5b167707 |

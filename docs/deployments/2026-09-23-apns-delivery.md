# APNs 送达加固服务端发布记录

- 时间：2026-09-23 23:07（Asia/Taipei）
- SSH 目标：`nap`
- Release：`20260923T150717Z-10b8a036-dirty-20331`
- 来源：分支 `live-activity-v2` 的提交 `10b8a036` 加上未提交的 HTTP/2 多路复用改动；没有推送，也没有发布 iOS App。
- 服务地址：https://naptable.mom0ka27.top

内容：

- iOS 26 关心共享课表时改走远程启动；新增 `POST /v2/live-activity/devices/{id}/remote-resume`。
- APNs 连接：发送前识别空闲期间被关闭的连接并换新；空闲超过 10 分钟重连；GOAWAY 之后的流、REFUSED_STREAM、未写完的请求归为未发送并重试一次。
- start 的 `apns-expiration` 为课程结束时刻。
- `/broadcast-config` 需要已注册安装的 `deviceID` 与 `X-Device-Secret`。
- 广播边界每分钟物化；start、令牌 update、广播按环境整批以 HTTP/2 多路复用并发发送，广播使用独立连接。

部署前 190 项 Python 测试通过（跳过 1 项）。线上 Python 3.14.7、SQLite 3.53.1、cryptography 46.0.7；token 密钥校验并备份；数据库副本迁移预检通过，未发送 APNs 请求。

发布验证：

- systemd：active/running，NRestarts=0，ExecMainStatus=0。
- 公网 `/health`：200 `{"ok": true}`（本机 curl/LibreSSL 仍有 TLS 错误，Python 客户端验证成功）。
- `/v1/live-activity/health`：426。
- `/broadcast-config` 缺 `deviceID`：400；伪造 `deviceID`：403。
- `remote-resume` 无凭据：403。
- 没有创建测试设备或发送人工测试推送；真实 APNs 的并发上限与上下课时刻延迟需上线后观察。

本地与服务器文件 SHA-256 一致：

| 文件 | SHA-256 |
|---|---|
| server/apns.py | 13986c09298b2fa786a68082b6959c45e7df3eed7899c15ae12c4d3cfb3efb23 |
| server/live_activity_v2.py | 8e8e901ce8a32d930f1527f5932c8ef396ed19a80e5eec7269a5be1cb659e882 |

# Live Activity v2 服务端发布记录

- 时间：2026-09-23 00:15（Asia/Taipei）
- SSH 目标：`nap`
- Release：`20260922T161525Z-8c7a4fbe-dirty-95201`
- 来源：当前未提交的服务端工作区；没有 git 提交或推送，也没有发布 iOS App。
- 服务地址：https://naptable.mom0ka27.top

部署前完整运行 163 项 Python 测试，全部通过。部署脚本新增 v2 模块打包、每个 release 独立虚拟环境和加密依赖安装、独立 token 密钥及备份、数据库副本迁移预检。首次 v1 → v2 失败时禁止自动恢复旧调度器，避免重发已提交的启动。

线上 Python 3.11.13，cryptography 46.0.7。已有 APNs 配置保留。密钥未输出到日志，服务账号读取检查通过；备份保存在 `/etc/naptable/key-backups/`，不受 release/数据库备份清理影响。

发布验证：

- systemd：active/running，NRestarts=0，ExecMainStatus=0；数据库备份 timer active。
- 公网 `/health`：服务器及本机 Python HTTPS 客户端均返回 200、`{"ok":true}`。本机 curl/LibreSSL 出现 TLS 连接错误，Python 独立验证成功。
- `/v1/live-activity/health`：426，提示升级。
- 无凭据访问 `/v2/live-activity/devices/deployment-check`：403。
- SQLite quick_check=ok；v2 migration=2；旧 pending start=0。
- 发布后数据库备份：`naptable-20260922T161536Z.sqlite3`；发布前另有停旧调度后的最终备份。
- 没有创建测试设备或发送人工测试推送；既有广播排空按服务逻辑运行。App 真机送达/锁屏和容量验收不在这次部署验证范围内。

本地与服务器文件 SHA-256 一致：

| 文件 | SHA-256 |
|---|---|
| server/live_activity_v2.py | 403d755f38067d67cf9f3821bb23add1575e200a16233d26078c5df2073bc664 |
| server/live_activity_timeline.py | 118377c15c83301db31e962057ea5a778a5fe5628f0812b925af5898393a856b |
| server/apns.py | 4624f831ba01e290d56e20da4301939e1b4b3396bb0d177d97f9108d1bd7217e |
| server/naptable_server.py | 56cb9148f7eb1fb3d1deeabb31d15ae59e9d4a62fd5773dc68343313fe5904b6 |

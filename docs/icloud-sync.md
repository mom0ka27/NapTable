# iCloud 课表同步

在「设置 → iCloud 同步」开启；默认关闭。新设备可在首次引导的导入页选择「从 iCloud 同步已有课表」，同步完成后点「完成」进入课表。在同一 Apple 账号的各设备上分别开启后，同步自己的课表（含隐藏课程）、学期/节次/调休设置、已保存的共享课表及备注、分享管理凭证。分享给其他人仍使用原有分享码服务，iCloud 不负责跨账号协作。

当前选中的课表、关心对象、通知许可、显示偏好与背景图片不参与同步。管理凭证存放在用户的 CloudKit 私有数据库，不进入公共数据库或使用统计。通过同步拿到凭证的设备可以管理既有分享。

## Apple 开发者配置

代码已经声明 `iCloud.com.niyiwei.naptable` 容器与 CloudKit entitlement。发布前仍需在 Apple Developer / Xcode 中完成以下操作（本地代码无法代替开发者后台配置）：

1. 为 `com.niyiwei.naptable` 启用 iCloud / CloudKit，将容器 `iCloud.com.niyiwei.naptable` 关联到该 App ID；所有平台使用同一个容器。
2. 更新签名描述文件。在登录测试 iCloud 账号的签名开发构建上开启同步，创建 Development schema：记录类型 `ScheduleLibrary`，字段 `payload`（Asset）。记录 `schedule-library-v1` 在用户的 private database 默认 zone 中。无需 public 权限或查询索引。
3. 在 CloudKit Console 将 schema 部署到 Production，再验证 TestFlight / 发布构建。开发环境与生产环境数据隔离。
4. 在两台真机上验证首次合并、修改、删除、共享备注、分享更新与撤销；确认网络断开后修改保留，重连并打开 App 后同步；验证退出 iCloud / 切换账号时暂停。

本版在前台启动、内容修改后及前台每 60 秒同步，可手动立即同步；未接入 CloudKit 静默推送，不保证 App 关闭后的即时同步。不会为了 iCloud 同步启动课程实时通知或请求通知权限。

## 数据与冲突

- 本地课表使用持久 UUID；数字 table/course ID 在导入另一设备时重新分配。手动恢复备份产生新的 UUID，避免覆盖原课表。
- 同步文档按课表、已保存的共享课表、管理凭证分别记录修改时间与删除标记。首次同步合并不同实体，不使用“整机备份覆盖”策略。删除标记保留，防止离线设备重新带回旧数据。
- 同一实体的并发修改按修改时间选择较新者，相同时间按写入设备 ID 确定顺序。课表是合并单位，**不进行同一课表内课程字段的并发合并**。收到未来时间戳后，后续本机修改使用更晚时间，避免永久无法更新。
- 覆盖本地内容前在 Application Support 保存恢复副本，仅保留最近 5 份。用户可从同步设置的「恢复同步前的课表」将自己的课表追加恢复成新课表。恢复不会重新启用已移除的分享凭证。
- 云端使用 CKAsset 保存文档（客户端限制 25 MiB），通过 `ifServerRecordUnchanged` 条件写入；发生并发写入时重新读取合并，最多尝试 3 次。应用云端结果前再次捕获等待期间产生的本机修改。本地保存失败时停止上传。
- 同步日志与课表写入同一个原子 JSON 存档，旧版存档缺少新增可选字段仍可读取。共享缓存沿用 UserDefaults，下一次保存会捕获与同步日志之间的差异。
- 关闭开关保留云端数据。保持同步开启并删除内容可传播删除；删除标记不包含课程或凭证正文。设备绑定首次成功识别的 iCloud 用户，账号变化会停用同步，避免将旧账号的数据自动上传到新账号。切回原账号后可重新开启。

## 验证

`bash tests/check-icloud-sync.sh` 使用内存传输层覆盖迁移、首次合并、同名课表收敛、ID/课程分组映射、隐藏课程、删除传播、恢复副本、共享备注与管理凭证、条件写冲突、上传期间编辑、账号隔离及保存失败。`bash tests/check-sharing.sh` 和 `bash tests/check-share-rotation.sh` 检查原分享行为。

模型检查和未签名构建不验证真实 iCloud 权限、schema、配额或跨真机通信，发布前必须完成上述真机验收。

实现依据：[Apple CloudKit 条件写入策略](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/savepolicy)、[批量保存结果](https://developer.apple.com/documentation/cloudkit/ckdatabase/modifyrecords(saving:deleting:savepolicy:atomically:))。

# 数据目录与备份

## 运行环境和用户数据是两类东西

Windows 原生安装通常在 `%LOCALAPPDATA%\\hermes` 下同时保存运行环境和用户数据。常见目录包括：

```text
%LOCALAPPDATA%\\hermes\\hermes-agent\\   运行时仓库与虚拟环境
%LOCALAPPDATA%\\hermes\\git\\            PortableGit
%LOCALAPPDATA%\\hermes\\node\\           Portable Node.js
%LOCALAPPDATA%\\hermes\\bin\\            启动器和 uv
%LOCALAPPDATA%\\hermes\\                  配置、认证、会话和日志
```

具体目录以当前官方版本为准。配置、认证元数据、会话和日志可能包含敏感信息，备份前应由用户确认必要性和保存位置。

## 推荐备份

1. 关闭 Desktop，确认没有写入中的任务。
2. 将需要保留的 `%LOCALAPPDATA%\\hermes` 内容复制到你控制的加密或受保护位置。
3. 记录备份日期、Hermes 版本和恢复用途；不要把备份上传给 XQ。
4. 定期验证备份可读，但不要在生产目录上直接做恢复试验。

不要把 `.env`、Key、Token、Cookie、认证文件或聊天正文贴入工单。XQ 诊断不会读取 `.env` 内容。

## 空间和隐私

运行环境更新可能占用磁盘；会话和日志也可能增长。按官方说明检查空间，先备份再清理。仅为排错提供必要的脱敏摘要。

## 安全默认

本套件不会复制 Key 到 Windows 环境变量，不会修改配置，也不会递归删除 Hermes 根目录。对 `security.allow_lazy_installs` 只说明当前值、建议值和影响；如需调整，应由用户先确认并按官方文档操作。

## 来源（需要联网，用户主动点击）

- [官方 Windows 数据说明（需要联网）](https://hermes-agent.nousresearch.com/docs/user-guide/windows-native)
- [官方安全说明（需要联网）](https://hermes-agent.nousresearch.com/docs/user-guide/security/)

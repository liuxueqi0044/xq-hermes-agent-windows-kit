# 开始这里

> 这是 XQ 整理的中文使用说明。Hermes Agent 由 Nous Research 发布；XQ 不是其官方或授权代理。本页面可以断网阅读，但安装、登录和模型请求需要联网。

## 先看结论

本套件只面向 Windows 11 x64 的普通本地桌面使用。官方 Desktop 安装器是一个薄安装器：首次启动会准备运行环境，因此断网时只能阅读本套件，不能完成首次安装。模型账号、订阅费和 API 费用由用户自行承担。

## 五步完成基础配置

1. **确认条件。** 使用 Windows 11 x64，保留足够磁盘空间，并在安装时连接可靠网络。不要在生产账号或生产数据环境中首次试用。
2. **核对来源。** 打开本包的来源清单，确认官方页面、安装器文件名、SHA-256 和签名状态与安装器一致。安全软件提示时保留保护功能，先核对证据再由你决定是否继续。
3. **运行官方安装器。** 在 `01-Hermes官方安装器` 中运行原始文件，不修改文件名或内容。安装器显示的网络下载和权限提示由你本人确认。
4. **选择模型路线。** 选择 Nous Portal OAuth，或选择你已有的模型服务。登录、验证码、密码和 Key 只能由你在自己的电脑上输入，不能发给 XQ。
5. **完成一次对话并检查。** 在 Desktop 中完成一次普通文本对话，然后按后续页面运行 `hermes --version`、`hermes doctor` 和 XQ 诊断工具。

## 两条模型路线

### 路线 A：Nous Portal OAuth

在 Hermes 官方登录流程中打开官方页面并完成授权。这可能需要 Nous Portal 账号或订阅；账号、授权码、付款和服务可用性都由用户与 Nous Research 处理。XQ 不代注册、不代持账号、不接收授权码。

### 路线 B：自备模型服务

在 Hermes 官方配置流程中选择你已有的服务商，并由你在本机输入 Key。不要把完整 Key 粘贴到聊天、工单或截图；截图前遮挡 Key、Token、邮箱和余额。模型服务的计费、限额和响应质量由服务商负责。

## 成功标准

基础配置完成应同时满足：Desktop 能打开；`hermes --version` 返回版本；你的模型服务连接成功；能完成普通文本问答；`hermes doctor` 没有阻断运行的错误。任何一个条件不满足，都可以先保存脱敏诊断报告，再联系对应责任方。

## 来源（需要联网，用户主动点击）

[Hermes 官方 Windows 说明（需要联网）](https://hermes-agent.nousresearch.com/docs/user-guide/windows-native)

[Hermes 官方 Desktop 说明（需要联网）](https://hermes-agent.nousresearch.com/docs/user-guide/desktop)

[Hermes 官方安全说明（需要联网）](https://hermes-agent.nousresearch.com/docs/user-guide/security/)

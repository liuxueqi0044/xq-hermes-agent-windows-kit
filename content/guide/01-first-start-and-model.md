# 首次启动与模型配置

## 启动前的边界

Hermes Desktop 是官方桌面外壳，不是 XQ 自行编译的程序。它是薄安装器，首次启动通常需要联网准备 Python、Node.js、Git 等运行环境；首次登录和调用模型也需要网络。页面和本包本身可离线阅读，不代表安装流程离线。

先关闭其他可能正在使用 Hermes 的窗口，并准备好你自己的账号或模型服务。任何密码、验证码、授权码、API Key 都只在本机官方界面输入。

## 第一次启动

1. 双击本包中的官方原始安装器。
2. 阅读 Windows 和安全软件的提示，核对来源清单中的 SHA-256 与签名状态。不要为了安装而关闭 Defender、SmartScreen、防火墙或 UAC，也不要添加排除项。
3. 允许安装器在可见窗口中完成官方依赖准备。若网络中断，记录提示并稍后重试，不要从网盘或论坛寻找替代文件。
4. Desktop 打开后，按其官方配置入口选择模型路线。

## OAuth 路线

选择 Nous Portal OAuth 后，在官方登录页面完成登录和授权。账号或订阅是否可用、费用以及额度由 Nous Portal 负责。XQ 不会看到或保存你的凭据；若需要求助，请只提供遮挡后的错误信息。

## 自备模型服务路线

选择官方支持的你已有的模型服务，按页面提示在本机填写 Key。Key 不应写入公共文档、截图、邮件或聊天。不要使用来源不明的共享账号，不要将 Key 发给客服代填。

## 推荐的官方命令

在普通 PowerShell 窗口中按需执行：

```powershell
hermes --version
hermes setup
hermes model
```

命令名称和提示以当前官方版本为准。XQ 不提供会写入凭据的批处理文件，也不会修改你的 PowerShell Execution Policy。

## 安全提示的处理方式

如果 `uv.exe` 或其他官方组件被安全软件提示，先暂停并核对本包记录的官方来源、SHA-256、签名状态和官方说明，再由你决定是否继续。不要把“提示”直接解释为安全或不安全的结论；XQ 也不会要求关闭保护措施。

## 需要联网的官方页面

- [Desktop 官方文档（需要联网）](https://hermes-agent.nousresearch.com/docs/user-guide/desktop)
- [Windows 官方文档（需要联网）](https://hermes-agent.nousresearch.com/docs/user-guide/windows-native)

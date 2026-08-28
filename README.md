# XQ Hermes Agent Windows Kit

面向 Windows 11 x64 新用户的 Hermes Agent 官方 Desktop 配置与诊断套件。

本仓库不修改、不重签、不冒充 Hermes 官方二进制。它只负责：

- 锁定并验证官方来源、版本、SHA-256 与签名；
- 生成断网可读的中文配置指南；
- 提供只读、脱敏、不上传的本地诊断脚本；
- 通过显式 allowlist 组装最终 ZIP。

## 当前实施范围

当前只实现架构模块 M1-M5：

1. 版本锁定与来源证明；
2. 官方制品获取与真实性验证；
3. 离线中文内容系统；
4. 只读诊断工具；
5. 确定性组包。

Gateway、Cron、消息渠道、Skills 自动安装、Computer Use、云端部署和公网 Dashboard 不在范围内。

## 开发环境

- Windows 11 x64；
- PowerShell 7.4+（构建）；
- Windows PowerShell 5.1 / PowerShell 7（诊断脚本兼容目标）；
- Pester 5.x（测试）。

正式构建必须使用完整的锁定 manifest，不能使用 `main`、`latest`、短 commit 或未验证 hash。仓库、日志、测试 fixture 和构建产物中均不得放置真实 API Key、Token、SSH、生产服务器或用户会话数据。

## M1-M5 工作流

以下命令均从仓库根目录执行。构建链使用 PowerShell 7；诊断工具同时兼容 Windows PowerShell 5.1。

```powershell
# M1：只读发现候选版本和官方 Desktop 资产；输出不是正式锁。
.\build\Resolve-OfficialRelease.ps1

# M2：仅在人工补齐并审核 formal manifest 后才允许下载和验证。
.\build\Resolve-OfficialRelease.ps1 -ManifestPath .\manifest\product-manifest.json
.\build\Fetch-OfficialRelease.ps1 `
  -ManifestPath .\manifest\product-manifest.json `
  -CacheDirectory .\cache
.\build\Verify-Artifact.ps1 `
  -ManifestPath .\manifest\product-manifest.json `
  -ArtifactPath .\cache\Hermes-Setup.exe `
  -SignatureReportPath .\evidence\signature-report.json

# M3：生成完全离线可读的中文内容目录。
.\build\Render-OfflineContent.ps1 `
  -ManifestPath .\manifest\product-manifest.json `
  -OutputRoot .\staging\content

# M4：生成只读、脱敏、不上传的本地诊断报告。
.\tools\Hermes-XQ-Diagnose.ps1 -OutputDirectory .\diagnostics

# M5：仅接受 formal manifest、已验证安装包和精确内容 allowlist。
.\build\Build-Package.ps1 `
  -ManifestPath .\manifest\product-manifest.json `
  -VerifiedArtifactPath .\cache\Hermes-Setup.exe `
  -RenderedContentPath .\staging\content `
  -DiagnoseToolPath .\tools\Hermes-XQ-Diagnose.ps1 `
  -HermesLicensePath .\LICENSES\Hermes-MIT-LICENSE.txt `
  -OutputDirectory .\artifacts
```

仓库中的 `product-manifest.json` 故意保持 `draft`，零值 hash/commit 与 `DRAFT-NOT-FOR-BUILD` waiver 会被正式构建拒绝。发布负责人必须先锁定完整 commit、实测安装包 SHA-256、锁定 commit 对应 LICENSE 的 SHA-256、Authenticode 状态与签名主体；程序不会根据下载结果反向填充或自动信任这些字段。带 `-ManifestPath` 的发现命令会再次核对 tag/version/commit、产品页资产链接和官方 LICENSE 内容。

## 测试与质量门禁

```powershell
# 需要 Pester 5.x；可选输出 NUnit XML。
.\tests\Run-All.ps1 -ResultPath .\TestResults\pester-results.xml

# 可选静态分析（需要 PSScriptAnalyzer）。
Invoke-ScriptAnalyzer -Path .\build -Recurse -Severity Error,Warning
Invoke-ScriptAnalyzer -Path .\tools -Recurse -Severity Error,Warning
```

符号链接拒绝测试在未启用 Windows Developer Mode、且当前进程无创建符号链接权限时会被条件跳过；发布验收环境必须具备该能力并确保此项实际执行。

## 安全边界

- 所有网络 URL 必须通过 `manifest/trusted-sources.json` 中的 HTTPS host/path/query allowlist；每次重定向都重新校验。
- 下载先写随机 `.partial`，再验证 PE、SHA-256 和签名策略；失败文件进入隔离目录，不覆盖正式缓存。
- 离线内容禁止远程 CSS、`@import`、脚本和路径逃逸。
- 诊断工具不修复、不提权、不上传；`doctor` 只在一次性隔离 Home 中运行，报告写入前再次脱敏。
- ZIP 只复制显式清单中的文件，拒绝 reparse point、备用数据流、额外页面和覆盖已有发行物。
- 不要绕过组织的 PowerShell 执行策略；必要时应为正式发布物配置代码签名。

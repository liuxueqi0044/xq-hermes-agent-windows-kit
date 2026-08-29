# XQ Hermes Agent Windows Kit

面向 Windows 11 x64 新用户的 Hermes Agent 官方 Desktop 配置、离线说明、诊断与可审计发布套件。

本仓库不修改、不重签、不冒充 Hermes 官方二进制。它负责锁定官方来源与版本、验证 SHA-256 和签名、生成离线中文内容、提供只读诊断、按 allowlist 组包，并在真实虚拟机验收完成前阻止发布。

## 当前状态

M1–M10 的代码、Schema、测试和 CI 编排已经实现。当前仓库仍然是**开发基线，不是可发布成品**：

- `manifest/product-manifest.json` 故意保持 `draft`，占位 commit/hash 不能用于正式构建；
- `governance/support-matrix.json` 保持 `PENDING_REAL_VM`；
- M9 必须在全新、隔离的中英文 Windows 11 x64 虚拟机上分别执行；
- M10 最多批准创建 GitHub **Draft Release**，不会自动发布，也不会覆盖旧制品。

| 模块 | 能力 | 实施状态 |
| --- | --- | --- |
| M1 | 版本锁定与来源证明 | 已实现 |
| M2 | 官方制品获取与真实性验证 | 已实现 |
| M3 | 离线中文内容系统 | 已实现 |
| M4 | 只读、脱敏诊断工具 | 已实现 |
| M5 | 确定性 allowlist 组包 | 已实现 |
| M6 | 源码、staging、ZIP、证据四段安全门禁 | 已实现 |
| M7 | Pester 契约、集成、安全和覆盖率报告 | 已实现 |
| M8 | PR/Push 验证与人工批准 Draft Release 流水线 | 已实现 |
| M9 | VM 基线、差异、13 步双语验收与权威 JSON 校验 | 工具已实现，等待真实 VM 执行 |
| M10 | 支持范围、商业承诺、发布 manifest 与不可变发布门禁 | 已实现，受 M9 阻断 |

Gateway、Cron、消息渠道、Skills 自动安装、Computer Use、云端部署和公网 Dashboard 不在首版范围内。

## 开发与验证环境

- Windows 11 x64；
- PowerShell 7.4+（构建、测试和发布门禁）；
- Windows PowerShell 5.1 / PowerShell 7（诊断脚本兼容目标）；
- 锁定的 Pester 5.7.1 和 PSScriptAnalyzer 1.25.0。

正式构建只能使用完整 formal manifest，不能使用 `main`、`latest`、短 commit 或未验证 hash。仓库、日志、fixture、证据和构建产物中不得放置真实 API Key、Token、SSH、生产服务器或用户会话数据。

## 本地质量门禁

以下命令从仓库根目录执行：

```powershell
# 按版本、字节数和 SHA-256 下载并安装审计锁定的测试工具。
.\ci\Install-LockedTools.ps1 -ModuleRoot .\work\locked-modules
$env:PSModulePath = "$PWD\work\locked-modules;$env:PSModulePath"

# 离线执行 M1–M10 的全部自动化测试，并生成 NUnit 与 JaCoCo 报告。
.\tests\Run-All.ps1 `
  -ResultPath .\TestResults\pester-results.xml `
  -SummaryJsonPath .\TestResults\summary.json `
  -SummaryTextPath .\TestResults\summary.txt `
  -CoveragePath .\TestResults\coverage.xml

# 检查工作流权限、触发器、固定 action commit 和发布证据引用。
.\ci\Validate-CI.ps1

# 静态分析生产脚本。
foreach ($area in 'build','tools','security','ci','acceptance','governance') {
  Invoke-ScriptAnalyzer -Path ".\$area" -Recurse `
    -Settings .\ci\PSScriptAnalyzerSettings.psd1
}
```

测试入口本身保持离线；只有显式的锁定工具安装和正式上游获取步骤会访问网络。JaCoCo 报告用于保存可审计的行/命令覆盖证据；当前不宣称 PowerShell 分支覆盖率。

## M1–M6 构建链

```powershell
# M1：只读发现候选版本；输出不是正式锁。
.\build\Resolve-OfficialRelease.ps1

# M2：仅在人工补齐并审核 formal manifest 后获取与验证。
.\build\Fetch-OfficialRelease.ps1 `
  -ManifestPath .\manifest\product-manifest.json `
  -CacheDirectory .\cache
.\build\Verify-Artifact.ps1 `
  -ManifestPath .\manifest\product-manifest.json `
  -ArtifactPath .\cache\Hermes-Setup.exe `
  -SignatureReportPath .\evidence\signature-report.json

# M3/M4：离线内容与本地诊断。
.\build\Render-OfflineContent.ps1 `
  -ManifestPath .\manifest\product-manifest.json `
  -OutputRoot .\staging\content
.\tools\Hermes-XQ-Diagnose.ps1 -OutputDirectory .\diagnostics

# M5：确定性组包。
.\build\Build-Package.ps1 `
  -ManifestPath .\manifest\product-manifest.json `
  -VerifiedArtifactPath .\cache\Hermes-Setup.exe `
  -RenderedContentPath .\staging\content `
  -DiagnoseToolPath .\tools\Hermes-XQ-Diagnose.ps1 `
  -HermesLicensePath .\LICENSES\Hermes-MIT-LICENSE.txt `
  -OutputDirectory .\artifacts

# M6：正式流水线依次对 Source、Staging、Zip、Evidence 执行；
# Defender 跳过、签名过旧、秘密命中或 LICENSE 锁不一致均不能通过。
.\security\Invoke-SecurityGate.ps1 -TargetType Source -Path . `
  -RepositoryRoot . -ManifestPath .\manifest\product-manifest.json `
  -LicensePath .\LICENSES\Hermes-MIT-LICENSE.txt
```

仓库中的 draft manifest 零值 hash/commit 与 `DRAFT-NOT-FOR-BUILD` waiver 会被正式构建拒绝。发布负责人必须人工锁定完整 commit、安装包 SHA-256、对应 LICENSE SHA-256、Authenticode 状态和签名主体；程序不会根据下载结果反向填充或自动信任这些字段。

## M9/M10 验收与发布

```powershell
# 在每台隔离 VM 的安装前后分别采集；具体证据要求见 acceptance/README.md。
.\acceptance\New-VmBaseline.ps1 -OutputPath .\evidence\baseline-before.json
.\acceptance\New-VmBaseline.ps1 -OutputPath .\evidence\baseline-after.json
.\acceptance\Compare-VmBaseline.ps1 `
  -BeforePath .\evidence\baseline-before.json `
  -AfterPath .\evidence\baseline-after.json `
  -OutputPath .\evidence\baseline-diff.json

# JSON 是机器权威；Markdown 只作展示并必须有同名 JSON sidecar。
.\acceptance\Validate-VmAcceptance.ps1 `
  -AcceptancePath .\evidence\vm-acceptance.json `
  -ManifestPath .\manifest\product-manifest.json

# 发布门禁还会检查候选 ZIP、支持矩阵、支持范围、商业承诺、tag/commit 和不可变目标。
.\governance\Invoke-ReleaseGate.ps1 `
  -ManifestPath .\manifest\product-manifest.json `
  -AcceptancePath .\evidence\vm-acceptance.json `
  -CandidateArtifactPath .\artifacts\candidate.zip `
  -ReleaseDestinationPath .\releases\candidate.zip `
  -ReleaseManifestPath .\evidence\release-manifest.json
```

只有 13 个固定步骤全部各出现一次且为 `PASS`、中英文 VM 证据完整、支持矩阵为 `VALIDATED`、所有 hash/版本/范围相互绑定时，门禁才返回 `APPROVED_FOR_DRAFT_RELEASE`。最终发布仍需 GitHub 受保护环境中的人工批准。

## 安全边界

- 网络 URL 必须通过 `manifest/trusted-sources.json` 的 HTTPS host/path/query allowlist；每次重定向都重新校验。
- 下载先写随机 `.partial`，再验证 PE、SHA-256 和签名策略；失败文件进入隔离目录，不覆盖正式缓存。
- 离线内容禁止远程 CSS、`@import`、脚本和路径逃逸。
- 诊断工具不修复、不提权、不上传；`doctor` 只在一次性隔离 Home 中运行，报告写入前再次脱敏。
- ZIP 只复制显式清单文件，拒绝 reparse point、备用数据流、额外页面和覆盖已有发行物。
- 安全扫描结果不回显秘密；私有 denylist 不得进入 Git、日志、ZIP 或证据包。
- 不要绕过组织的 PowerShell 执行策略；正式发布物应按组织策略配置代码签名。

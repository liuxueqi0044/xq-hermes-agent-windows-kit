Describe 'Build-Package' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:BuildScript = Join-Path $script:RepositoryRoot 'build\Build-Package.ps1'
    }

    BeforeEach {
        $script:CaseRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $script:ContentRoot = Join-Path $script:CaseRoot 'content'
        $script:OutputRoot = Join-Path $script:CaseRoot 'output'
        New-Item -ItemType Directory -Path $script:ContentRoot -Force | Out-Null

        $required = @(
            '00-开始这里.html',
            '02-配置指南\01-首次启动与模型配置.html',
            '02-配置指南\02-跑通第一次对话.html',
            '02-配置指南\03-数据目录与备份.html',
            '02-配置指南\04-更新重装与卸载.html',
            '02-配置指南\05-常见问题.html',
            '03-诊断工具\诊断工具使用说明.html',
            '05-售后说明\自助版服务范围.html',
            '05-售后说明\远程版服务范围.html',
            '05-售后说明\提交问题前请准备.html',
            'README.txt'
        )
        foreach ($relative in $required) {
            $path = Join-Path $script:ContentRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Set-Content -LiteralPath $path -Value "content for $relative" -Encoding utf8NoBOM
        }

        $script:Artifact = Join-Path $script:CaseRoot 'Hermes-Setup.exe'
        [IO.File]::WriteAllBytes($script:Artifact, [byte[]](0x4d, 0x5a, 0x01, 0x02, 0x03))
        $hash = (Get-FileHash -LiteralPath $script:Artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = [ordered]@{
            schemaVersion          = '1.0'
            buildMode             = 'formal'
            productVersion         = '1.0.0'
            releaseChannel         = 'stable'
            hermesReleaseTag       = 'v2026.8.27'
            hermesVersion          = '0.20.6'
            upstreamCommit         = ('a' * 40)
            desktopBuildCommit     = ('a' * 40)
            runtimeInstallPin      = @{ type = 'commit'; value = ('a' * 40) }
            sourcePageUrl          = 'https://hermes-agent.nousresearch.com/'
            officialAssetUrl       = 'https://hermes-assets.nousresearch.com/Hermes-Setup.exe?build=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            officialAssetName      = 'Hermes-Setup.exe'
            officialSha256         = $hash
            licenseUrl             = 'https://raw.githubusercontent.com/NousResearch/hermes-agent/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/LICENSE'
            licenseSha256          = ('0' * 64)
            signatureStatus        = 'Valid'
            signature              = @{
                policy = 'valid-or-explicit-waiver'
                status = 'Valid'
                signerSubject = 'CN=Package Fixture'
                signerThumbprint = ('A' * 40)
                timestampStatus = 'Unavailable'
            }
            supportedOs            = @('Windows 11 x64')
            buildDate              = '2026-08-28T08:00:00Z'
            upstreamLicense        = 'MIT'
            xqTelemetry            = $false
            runtimeInternetRequired = $true
        }
        $script:Manifest = Join-Path $script:CaseRoot 'product-manifest.json'
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:Manifest -Encoding utf8NoBOM
        $script:Diagnose = Join-Path $script:CaseRoot 'Hermes-XQ-Diagnose.ps1'
        Set-Content -LiteralPath $script:Diagnose -Value '# test diagnostic' -Encoding utf8NoBOM
        $script:License = Join-Path $script:CaseRoot 'LICENSE'
        Set-Content -LiteralPath $script:License -Value 'MIT test fixture' -Encoding utf8NoBOM
        $manifest.licenseSha256 = (Get-FileHash -LiteralPath $script:License -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:Manifest -Encoding utf8NoBOM
    }

    It 'builds the exact package contract and receipts' {
        $result = & $script:BuildScript -ManifestPath $script:Manifest -VerifiedArtifactPath $script:Artifact `
            -RenderedContentPath $script:ContentRoot -DiagnoseToolPath $script:Diagnose `
            -HermesLicensePath $script:License -OutputDirectory $script:OutputRoot

        $result.PackagePath | Should -Exist
        $result.HashReceipt | Should -Exist
        $result.InventoryPath | Should -Exist
        $result.PackageSha256 | Should -Be (Get-FileHash -LiteralPath $result.PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($result.PackagePath)
        try {
            @($zip.Entries.FullName) | Should -Contain 'XQ-Hermes-Agent-Windows-v1.0.0/01-Hermes官方安装器/Hermes-Setup.exe'
            @($zip.Entries.FullName) | Should -Contain 'XQ-Hermes-Agent-Windows-v1.0.0/04-许可与来源/SHA256SUMS.txt'
            @($zip.Entries.FullName) | Should -Contain 'XQ-Hermes-Agent-Windows-v1.0.0/04-许可与来源/THIRD-PARTY-NOTICES/'
        }
        finally { $zip.Dispose() }
    }

    It 'produces an identical ZIP for identical locked inputs' {
        $firstOutput = Join-Path $script:CaseRoot 'output-a'
        $secondOutput = Join-Path $script:CaseRoot 'output-b'
        $first = & $script:BuildScript -ManifestPath $script:Manifest -VerifiedArtifactPath $script:Artifact `
            -RenderedContentPath $script:ContentRoot -DiagnoseToolPath $script:Diagnose `
            -HermesLicensePath $script:License -OutputDirectory $firstOutput
        $second = & $script:BuildScript -ManifestPath $script:Manifest -VerifiedArtifactPath $script:Artifact `
            -RenderedContentPath $script:ContentRoot -DiagnoseToolPath $script:Diagnose `
            -HermesLicensePath $script:License -OutputDirectory $secondOutput

        $first.PackageSha256 | Should -BeExactly $second.PackageSha256
    }

    It 'refuses a mismatched artifact hash' {
        $manifest = Get-Content -LiteralPath $script:Manifest -Raw | ConvertFrom-Json
        $manifest.officialSha256 = ('f' * 64)
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:Manifest -Encoding utf8NoBOM

        { & $script:BuildScript -ManifestPath $script:Manifest -VerifiedArtifactPath $script:Artifact `
                -RenderedContentPath $script:ContentRoot -DiagnoseToolPath $script:Diagnose `
                -HermesLicensePath $script:License -OutputDirectory $script:OutputRoot } | Should -Throw '*hash mismatch*'
    }

    It 'refuses a LICENSE whose hash differs from the formal lock' {
        Set-Content -LiteralPath $script:License -Value 'tampered license' -Encoding utf8NoBOM
        { & $script:BuildScript -ManifestPath $script:Manifest -VerifiedArtifactPath $script:Artifact `
                -RenderedContentPath $script:ContentRoot -DiagnoseToolPath $script:Diagnose `
                -HermesLicensePath $script:License -OutputDirectory $script:OutputRoot } | Should -Throw '*LICENSE hash mismatch*'
    }

    It 'refuses a floating or incomplete runtime lock' {
        $manifest = Get-Content -LiteralPath $script:Manifest -Raw | ConvertFrom-Json
        $manifest.hermesReleaseTag = 'latest'
        $manifest.runtimeInstallPin.value = 'abc1234'
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:Manifest -Encoding utf8NoBOM

        { & $script:BuildScript -ManifestPath $script:Manifest -VerifiedArtifactPath $script:Artifact `
                -RenderedContentPath $script:ContentRoot -DiagnoseToolPath $script:Diagnose `
                -HermesLicensePath $script:License -OutputDirectory $script:OutputRoot } | Should -Throw '*runtimeInstallPin*'
    }

    It 'refuses unexpected rendered content' {
        Set-Content -LiteralPath (Join-Path $script:ContentRoot 'unexpected.txt') -Value 'no' -Encoding utf8NoBOM
        { & $script:BuildScript -ManifestPath $script:Manifest -VerifiedArtifactPath $script:Artifact `
                -RenderedContentPath $script:ContentRoot -DiagnoseToolPath $script:Diagnose `
                -HermesLicensePath $script:License -OutputDirectory $script:OutputRoot } | Should -Throw '*content contract mismatch*'
    }

    It 'refuses to overwrite an existing release' {
        & $script:BuildScript -ManifestPath $script:Manifest -VerifiedArtifactPath $script:Artifact `
            -RenderedContentPath $script:ContentRoot -DiagnoseToolPath $script:Diagnose `
            -HermesLicensePath $script:License -OutputDirectory $script:OutputRoot | Out-Null

        { & $script:BuildScript -ManifestPath $script:Manifest -VerifiedArtifactPath $script:Artifact `
                -RenderedContentPath $script:ContentRoot -DiagnoseToolPath $script:Diagnose `
                -HermesLicensePath $script:License -OutputDirectory $script:OutputRoot } | Should -Throw '*overwrite*'
    }
}

Describe 'M1-M5 offline integration' {
    BeforeAll {
        $script:ProjectRoot = Split-Path -Parent $PSScriptRoot
        $script:Renderer = Join-Path $script:ProjectRoot 'build\Render-OfflineContent.ps1'
        $script:Packager = Join-Path $script:ProjectRoot 'build\Build-Package.ps1'
        $script:Diagnose = Join-Path $script:ProjectRoot 'tools\Hermes-XQ-Diagnose.ps1'
        $script:Shell = (Get-Command pwsh -ErrorAction Stop).Source
    }

    It 'renders locked content and assembles a deterministic candidate without network access' {
        $caseRoot = Join-Path $TestDrive 'integration'
        $rendered = Join-Path $caseRoot 'rendered'
        $outputA = Join-Path $caseRoot 'output-a'
        $outputB = Join-Path $caseRoot 'output-b'
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $artifact = Join-Path $caseRoot 'Hermes-Setup.exe'
        [IO.File]::WriteAllBytes($artifact, [byte[]](0x4d, 0x5a, 0x50, 0x45, 0, 0, 1, 2, 3, 4))
        $artifactHash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        $commit = 'abcdef0123456789abcdef0123456789abcdef01'
        $licenseText = "MIT fixture only`n"
        $licenseBytes = [Text.UTF8Encoding]::new($false).GetBytes($licenseText)
        $licenseHasher = [Security.Cryptography.SHA256]::Create()
        try { $licenseHash = (($licenseHasher.ComputeHash($licenseBytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
        finally { $licenseHasher.Dispose() }
        $manifestObject = [ordered]@{
            schemaVersion           = '1.0'
            buildMode              = 'formal'
            productVersion          = '1.0.0'
            releaseChannel          = 'stable'
            hermesReleaseTag        = 'v2026.8.27'
            hermesVersion           = '0.20.6'
            upstreamCommit          = $commit
            desktopBuildCommit      = $commit
            runtimeInstallPin       = @{ type = 'commit'; value = $commit }
            sourcePageUrl           = 'https://hermes-agent.nousresearch.com/'
            officialAssetUrl        = "https://hermes-assets.nousresearch.com/Hermes-Setup.exe?build=$commit"
            officialAssetName       = 'Hermes-Setup.exe'
            officialSha256          = $artifactHash
            licenseUrl              = "https://raw.githubusercontent.com/NousResearch/hermes-agent/$commit/LICENSE"
            licenseSha256           = $licenseHash
            signatureStatus         = 'Valid'
            signature               = @{
                policy = 'valid-or-explicit-waiver'; status = 'Valid';
                signerSubject = 'CN=Integration Fixture'; signerThumbprint = ('A' * 40);
                timestampStatus = 'Unavailable'
            }
            supportedOs             = @('Windows 11 x64')
            buildDate               = '2026-08-28T08:00:00Z'
            upstreamLicense         = 'MIT'
            xqTelemetry             = $false
            runtimeInternetRequired = $true
        }
        $manifest = Join-Path $caseRoot 'product-manifest.json'
        [IO.File]::WriteAllText($manifest, (($manifestObject | ConvertTo-Json -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))

        & $script:Shell -NoProfile -File $script:Renderer -ProjectRoot $script:ProjectRoot -ManifestPath $manifest -OutputRoot $rendered
        $LASTEXITCODE | Should -Be 0

        $license = Join-Path $caseRoot 'LICENSE'
        [IO.File]::WriteAllBytes($license, $licenseBytes)
        $first = & $script:Packager -ManifestPath $manifest -VerifiedArtifactPath $artifact `
            -RenderedContentPath $rendered -DiagnoseToolPath $script:Diagnose `
            -HermesLicensePath $license -OutputDirectory $outputA
        $second = & $script:Packager -ManifestPath $manifest -VerifiedArtifactPath $artifact `
            -RenderedContentPath $rendered -DiagnoseToolPath $script:Diagnose `
            -HermesLicensePath $license -OutputDirectory $outputB

        $first.PackageSha256 | Should -BeExactly $second.PackageSha256
        $first.PackagePath | Should -Exist
        $first.FileCount | Should -BeGreaterOrEqual 15

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($first.PackagePath)
        try {
            $installerEntry = $zip.GetEntry('XQ-Hermes-Agent-Windows-v1.0.0/01-Hermes官方安装器/Hermes-Setup.exe')
            $installerEntry | Should -Not -BeNullOrEmpty
            $stream = $installerEntry.Open()
            try {
                $memory = [IO.MemoryStream]::new()
                try {
                    $stream.CopyTo($memory)
                    $recovered = Join-Path $caseRoot 'recovered.exe'
                    [IO.File]::WriteAllBytes($recovered, $memory.ToArray())
                }
                finally { $memory.Dispose() }
            }
            finally { $stream.Dispose() }
            (Get-FileHash -LiteralPath $recovered -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $artifactHash
        }
        finally { $zip.Dispose() }
    }
}

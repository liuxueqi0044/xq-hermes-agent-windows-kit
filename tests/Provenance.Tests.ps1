$ErrorActionPreference = 'Stop'
$global:XqProvenanceTestRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $global:XqProvenanceTestRoot 'build\Common.psm1') -Force

Describe 'M1 source locking' {
    BeforeAll {
        $trusted = Get-XqTrustedSources -Path (Join-Path $global:XqProvenanceTestRoot 'manifest\trusted-sources.json')
        function New-TestPeBytes {
            $bytes = [byte[]]::new(2048)
            $bytes[0] = 0x4d; $bytes[1] = 0x5a; $bytes[0x3c] = 0x80; $bytes[0x80] = 0x50; $bytes[0x81] = 0x45
            return $bytes
        }
        function New-TestManifest {
            param([Parameter(Mandatory)][byte[]]$Bytes)
            $path = Join-Path $global:XqProvenanceTestRoot 'tests\fixtures\provenance\formal-manifest.json'
            $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 16 -DateKind String
            $hasher = [Security.Cryptography.SHA256]::Create()
            try { $manifest.officialSha256 = (($hasher.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
            finally { $hasher.Dispose() }
            return $manifest
        }
    }

    It 'accepts a complete formal manifest with an exact pinned asset URL' {
        $manifest = New-TestManifest -Bytes (New-TestPeBytes)
        (Test-XqManifest -Manifest $manifest -TrustedSources $trusted -Formal).IsValid | Should -BeTrue
    }

    It 'accepts a current 12-character asset build prefix only when it pins desktopBuildCommit' {
        $manifest = New-TestManifest -Bytes (New-TestPeBytes)
        $manifest.officialAssetUrl = 'https://hermes-assets.nousresearch.com/Hermes-Setup.exe?build=aaaaaaaaaaaa'
        (Test-XqManifest -Manifest $manifest -TrustedSources $trusted -Formal).IsValid | Should -BeTrue
        $manifest.officialAssetUrl = 'https://hermes-assets.nousresearch.com/Hermes-Setup.exe?build=bbbbbbbbbbbb'
        (Test-XqManifest -Manifest $manifest -TrustedSources $trusted -Formal).IsValid | Should -BeFalse
    }

    It 'binds the formal tag, version, commit, and Desktop asset to one discovery result' {
        $manifest = New-TestManifest -Bytes (New-TestPeBytes)
        $candidate = [pscustomobject]@{
            tag = $manifest.hermesReleaseTag
            hermesVersion = $manifest.hermesVersion
            releaseCommit = $manifest.upstreamCommit
        }
        $asset = [pscustomobject]@{ url = $manifest.officialAssetUrl }
        (Assert-XqDiscoveredManifestBinding -Manifest $manifest -Candidates @($candidate) -DesktopAssets @($asset)) | Should -BeTrue

        $candidate.releaseCommit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        { Assert-XqDiscoveredManifestBinding -Manifest $manifest -Candidates @($candidate) -DesktopAssets @($asset) } | Should -Throw
        $candidate.releaseCommit = $manifest.upstreamCommit
        $candidate.hermesVersion = '9.9.9'
        { Assert-XqDiscoveredManifestBinding -Manifest $manifest -Candidates @($candidate) -DesktopAssets @($asset) } | Should -Throw
        $candidate.hermesVersion = $manifest.hermesVersion
        { Assert-XqDiscoveredManifestBinding -Manifest $manifest -Candidates @($candidate) -DesktopAssets @([pscustomobject]@{ url = 'https://hermes-assets.nousresearch.com/Hermes-Setup.exe?build=bbbbbbbbbbbb' }) } | Should -Throw
    }

    It 'verifies the exact upstream MIT LICENSE URL and locked hash' {
        $manifest = New-TestManifest -Bytes (New-TestPeBytes)
        $licenseBytes = [Text.Encoding]::UTF8.GetBytes("MIT License`n`nPermission is hereby granted, free of charge, to any person obtaining a copy.`n")
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $manifest.licenseSha256 = (($hasher.ComputeHash($licenseBytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
        finally { $hasher.Dispose() }
        $network = { param($request) [pscustomobject]@{ StatusCode=200; Headers=@{}; ContentBytes=$licenseBytes } }
        $proof = Test-XqLicenseSourceProof -Manifest $manifest -TrustedSources $trusted -NetworkInvoker $network
        $proof.Sha256 | Should -BeExactly $manifest.licenseSha256

        $manifest.licenseSha256 = ('3' * 64)
        { Test-XqLicenseSourceProof -Manifest $manifest -TrustedSources $trusted -NetworkInvoker $network } | Should -Throw
    }

    It 'rejects floating refs, short commits, and placeholder hashes in formal mode' {
        $manifest = New-TestManifest -Bytes (New-TestPeBytes)
        $manifest.upstreamCommit = 'main'
        $manifest.runtimeInstallPin.value = 'abcdef0'
        $manifest.officialSha256 = 'placeholder'
        $manifest.licenseSha256 = 'placeholder'
        $result = Test-XqManifest -Manifest $manifest -TrustedSources $trusted -Formal
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'upstreamCommit|runtimeInstallPin|officialSha256|licenseSha256'
    }

    It 'requires UTC buildDate, one supported OS, and matching signature status' {
        $manifest = New-TestManifest -Bytes (New-TestPeBytes)
        $manifest.buildDate = '2026-08-28T08:00:00+08:00'
        $manifest.supportedOs = @('Windows 11 x64', 'Windows 10 x64')
        $manifest.signature.status = 'Unavailable'
        $result = Test-XqManifest -Manifest $manifest -TrustedSources $trusted -Formal
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'UTC|exactly Windows 11 x64|must match'
    }

    It 'rejects untrusted, IP-literal, non-HTTPS, non-standard-port, and query-injected URLs' {
        foreach ($url in @(
            'http://hermes-agent.nousresearch.com/docs',
            'https://127.0.0.1/installer.exe',
            'https://hermes-agent.nousresearch.com:444/docs',
            'https://evil.example/Hermes-Setup.exe',
            'https://hermes-assets.nousresearch.com/Hermes-Setup.exe',
            'https://hermes-assets.nousresearch.com/Hermes-Setup.exe?build=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&x=1',
            'https://hermes-assets.nousresearch.com/main/Hermes-Setup.exe?build=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        )) {
            (Test-XqTrustedUri -Uri $url -TrustedSources $trusted -Purpose 'official-asset').IsAllowed | Should -BeFalse
        }
    }
}

Describe 'M2 acquisition and artifact verification' {
    BeforeAll {
        $trusted = Get-XqTrustedSources -Path (Join-Path $global:XqProvenanceTestRoot 'manifest\trusted-sources.json')
        function New-TestPeBytes {
            $bytes = [byte[]]::new(2048)
            $bytes[0] = 0x4d; $bytes[1] = 0x5a; $bytes[0x3c] = 0x80; $bytes[0x80] = 0x50; $bytes[0x81] = 0x45
            return $bytes
        }
        function New-TestManifest {
            param([Parameter(Mandatory)][byte[]]$Bytes)
            $path = Join-Path $global:XqProvenanceTestRoot 'tests\fixtures\provenance\formal-manifest.json'
            $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 16 -DateKind String
            $hasher = [Security.Cryptography.SHA256]::Create()
            try { $manifest.officialSha256 = (($hasher.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
            finally { $hasher.Dispose() }
            return $manifest
        }
        function New-TestCacheDirectory {
            $path = Join-Path ([IO.Path]::GetTempPath()) ("xq-provenance-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $path | Out-Null
            return $path
        }
    }

    It 'downloads only after verifying the source page, hashes it before atomic move, and writes a receipt' {
        $bytes = New-TestPeBytes
        $manifest = New-TestManifest -Bytes $bytes
        $cache = New-TestCacheDirectory
        try {
            $script:requestCount = 0
            $network = {
                param($request)
                $script:requestCount++
                if ($request.Uri -eq $manifest.sourcePageUrl) {
                    return [pscustomobject]@{ StatusCode = 200; Headers = @{}; ContentText = (Get-Content -LiteralPath (Join-Path $global:XqProvenanceTestRoot 'tests\fixtures\provenance\source-page.html') -Raw) }
                }
                return [pscustomobject]@{ StatusCode = 200; Headers = @{ ETag = '"synthetic"'; 'Last-Modified' = 'Thu, 28 Aug 2026 00:00:00 GMT' }; ContentBytes = $bytes }
            }
            $receiptPath = Join-Path $cache 'download-receipt.json'
            $receipt = Invoke-XqValidatedDownload -Manifest $manifest -TrustedSources $trusted -CacheDirectory $cache -NetworkInvoker $network -ReceiptPath $receiptPath
            $receipt.status | Should -Be 'DOWNLOADED'
            (Test-Path -LiteralPath (Join-Path $cache $manifest.officialAssetName)) | Should -BeTrue
            (Test-Path -LiteralPath $receiptPath) | Should -BeTrue
            $again = Invoke-XqValidatedDownload -Manifest $manifest -TrustedSources $trusted -CacheDirectory $cache -NetworkInvoker $network
            $again.status | Should -Be 'REUSED'
            $script:requestCount | Should -Be 3
        } finally { Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects an untrusted redirect before writing an artifact' {
        $bytes = New-TestPeBytes
        $manifest = New-TestManifest -Bytes $bytes
        $cache = New-TestCacheDirectory
        try {
            $network = {
                param($request)
                if ($request.Uri -eq $manifest.sourcePageUrl) { return [pscustomobject]@{ StatusCode=200; Headers=@{}; ContentText=(Get-Content -LiteralPath (Join-Path $global:XqProvenanceTestRoot 'tests\fixtures\provenance\source-page.html') -Raw) } }
                return [pscustomobject]@{ StatusCode=302; Headers=@{ Location='https://evil.example/installer.exe' } }
            }
            { Invoke-XqValidatedDownload -Manifest $manifest -TrustedSources $trusted -CacheDirectory $cache -NetworkInvoker $network } | Should -Throw
            (Test-Path -LiteralPath (Join-Path $cache $manifest.officialAssetName)) | Should -BeFalse
        } finally { Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects a trusted-host redirect that changes the file name or locked build query' {
        $bytes = New-TestPeBytes
        foreach ($redirectTarget in @(
            'https://hermes-assets.nousresearch.com/Other-Setup.exe?build=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'https://hermes-assets.nousresearch.com/Hermes-Setup.exe?build=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        )) {
            $manifest = New-TestManifest -Bytes $bytes
            $cache = New-TestCacheDirectory
            try {
                $network = {
                    param($request)
                    if ($request.Uri -eq $manifest.sourcePageUrl) {
                        return [pscustomobject]@{ StatusCode=200; Headers=@{}; ContentText=(Get-Content -LiteralPath (Join-Path $global:XqProvenanceTestRoot 'tests\fixtures\provenance\source-page.html') -Raw) }
                    }
                    if ($request.Uri -eq $manifest.officialAssetUrl) {
                        return [pscustomobject]@{ StatusCode=302; Headers=@{ Location=$redirectTarget } }
                    }
                    return [pscustomobject]@{ StatusCode=200; Headers=@{}; ContentBytes=$bytes }
                }
                { Invoke-XqValidatedDownload -Manifest $manifest -TrustedSources $trusted -CacheDirectory $cache -NetworkInvoker $network } | Should -Throw
                (Test-Path -LiteralPath (Join-Path $cache $manifest.officialAssetName)) | Should -BeFalse
            } finally { Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'quarantines a hash mismatch and never backfills the manifest hash' {
        $manifest = New-TestManifest -Bytes (New-TestPeBytes)
        $cache = New-TestCacheDirectory
        try {
            $network = {
                param($request)
                if ($request.Uri -eq $manifest.sourcePageUrl) { return [pscustomobject]@{ StatusCode=200; Headers=@{}; ContentText=(Get-Content -LiteralPath (Join-Path $global:XqProvenanceTestRoot 'tests\fixtures\provenance\source-page.html') -Raw) } }
                return [pscustomobject]@{ StatusCode=200; Headers=@{}; ContentBytes=([byte[]](1,2,3,4)) }
            }
            $lockedHash = $manifest.officialSha256
            { Invoke-XqValidatedDownload -Manifest $manifest -TrustedSources $trusted -CacheDirectory $cache -NetworkInvoker $network } | Should -Throw
            $manifest.officialSha256 | Should -Be $lockedHash
            @(Get-ChildItem -LiteralPath (Join-Path $cache 'quarantine') -File).Count | Should -Be 1
        } finally { Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects an HTML response even when its SHA-256 was maliciously pre-locked' {
        $htmlBytes = [Text.Encoding]::UTF8.GetBytes('<html><body>error</body></html>')
        $manifest = New-TestManifest -Bytes $htmlBytes
        $cache = New-TestCacheDirectory
        try {
            $network = {
                param($request)
                if ($request.Uri -eq $manifest.sourcePageUrl) { return [pscustomobject]@{ StatusCode=200; Headers=@{}; ContentText=(Get-Content -LiteralPath (Join-Path $global:XqProvenanceTestRoot 'tests\fixtures\provenance\source-page.html') -Raw) } }
                return [pscustomobject]@{ StatusCode=200; Headers=@{}; ContentBytes=$htmlBytes }
            }
            { Invoke-XqValidatedDownload -Manifest $manifest -TrustedSources $trusted -CacheDirectory $cache -NetworkInvoker $network } | Should -Throw
            (Test-Path -LiteralPath (Join-Path $cache $manifest.officialAssetName)) | Should -BeFalse
            @(Get-ChildItem -LiteralPath (Join-Path $cache 'quarantine') -File).Count | Should -Be 1
        } finally { Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails an invalid Authenticode status and signer mismatch' {
        $manifest = New-TestManifest -Bytes (New-TestPeBytes)
        $invalid = [pscustomobject]@{ status='Invalid'; signerSubject='CN=XQ Test Signer'; signerThumbprint='1111111111111111111111111111111111111111' }
        { Assert-XqSignaturePolicy -Report $invalid -Manifest $manifest } | Should -Throw
        $wrongSigner = [pscustomobject]@{ status='Valid'; signerSubject='CN=Other'; signerThumbprint='1111111111111111111111111111111111111111' }
        { Assert-XqSignaturePolicy -Report $wrongSigner -Manifest $manifest } | Should -Throw
    }
}

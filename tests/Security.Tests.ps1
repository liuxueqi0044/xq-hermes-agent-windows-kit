$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:securityRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:securityRoot 'security\Invoke-SecurityGate.ps1')

Describe 'M6 security gate' {
    BeforeAll {
        $script:securityRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $script:securityRoot 'security\Invoke-SecurityGate.ps1')
        if ($null -eq (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($env:XQ_PSSCRIPTANALYZER_MODULE_PATH)) { throw 'PSScriptAnalyzer must be available or XQ_PSSCRIPTANALYZER_MODULE_PATH must be supplied by CI.' }
            Import-Module -Name $env:XQ_PSSCRIPTANALYZER_MODULE_PATH -Force
        }
        function New-SecurityFixtureRoot {
            $path = Join-Path ([IO.Path]::GetTempPath()) ('xq-security-test-' + [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($path) | Out-Null
            return $path
        }
        function New-PassingDefenderProvider {
            return { param($target) [pscustomobject]@{ ran=$true; succeeded=$true; engineVersion='1.1.1.1'; signatureVersion='1.2.3.4'; signatureUpdated=[DateTimeOffset]::UtcNow } }
        }
        function Write-TestFile { param([string]$Root, [string]$Name, [string]$Content) $path = Join-Path $Root $Name; [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null; Set-Content -LiteralPath $path -Value $Content -Encoding utf8NoBOM; return $path }
    }
    It 'passes a clean staging directory with a simulated current Defender scan' {
        $root = New-SecurityFixtureRoot
        try {
            Write-TestFile $root 'safe.txt' 'https://example.com synthetic offline content' | Out-Null
            $result = Invoke-XqSecurityGate -TargetType Staging -Path $root -RepositoryRoot $script:securityRoot -DefenderProvider (New-PassingDefenderProvider)
            $result.status | Should -Be 'PASS'
            $result.findingCount | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'passes the complete current source tree with a simulated current Defender scan' {
        $result = Invoke-XqSecurityGate -TargetType Source -Path $script:securityRoot -RepositoryRoot $script:securityRoot -DefenderProvider (New-PassingDefenderProvider)
        $result.status | Should -Be 'PASS'
        $result.findingCount | Should -Be 0
    }
    It 'passes source and executes the explicit formal license lock check' {
        $root = New-SecurityFixtureRoot
        try {
            $licensePath = Write-TestFile $root 'HERMES-LICENSE.txt' ("MIT License`n`nPermission is hereby granted, free of charge.")
            $hash = (Get-FileHash -LiteralPath $licensePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            $manifestPath = Write-TestFile $root 'formal-manifest.json' ([ordered]@{ licenseUrl=("https://example.com/{0}/LICENSE" -f $commit); licenseSha256=$hash; upstreamLicense='MIT'; upstreamCommit=$commit } | ConvertTo-Json)
            $result = Invoke-XqSecurityGate -TargetType Source -Path $script:securityRoot -RepositoryRoot $script:securityRoot -ManifestPath $manifestPath -LicensePath $licensePath -DefenderProvider (New-PassingDefenderProvider)
            $result.status | Should -Be 'PASS'
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'rejects forbidden credential-shaped file names' {
        $root = New-SecurityFixtureRoot
        try {
            $path = Write-TestFile $root '.env' 'synthetic=true'
            (Test-XqSecurityFileNamePolicy (Get-Item $path) $root).rule | Should -Be 'forbidden-file-name'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'detects a synthetic private key without returning its body' {
        $root = New-SecurityFixtureRoot
        try {
            $header = '-----BEGIN ' + 'PRIVATE ' + 'KEY-----'
            $body = 'SYNTHETIC' + '-ONLY'
            $path = Write-TestFile $root 'readme.txt' ("{0}`n{1}" -f $header, $body)
            $findings = Test-XqSecurityContent (Get-Item $path) $root
            ($findings.rule) | Should -Contain 'private-key-header'
            ($findings | ConvertTo-Json -Compress) | Should -Not -Match $body
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'detects a synthetic token assignment without echoing it' {
        $root = New-SecurityFixtureRoot
        try {
            $token = 'syntheticTokenOnly_' + '1234567890ABCDEF='
            $keyName = 'api' + '_key'
            $path = Write-TestFile $root 'settings.txt' ("{0}={1}" -f $keyName, $token)
            $findings = Test-XqSecurityContent (Get-Item $path) $root
            ($findings.rule) | Should -Contain 'token-assignment'
            ($findings | ConvertTo-Json -Compress) | Should -Not -Match $token
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'detects an unlabelled mixed-case high-entropy synthetic token without padding' {
        $root = New-SecurityFixtureRoot
        try {
            $token = 'Q7mZ' + '1vR8' + 'pL3x' + 'N6kT' + '2aW9' + 'cD4y' + 'H5sJ' + '0bF7' + 'uE'
            $path = Write-TestFile $root 'data.txt' $token
            (Test-XqSecurityContent (Get-Item $path) $root).rule | Should -Contain 'high-entropy-token'
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'detects a synthetic production identifier pattern' {
        $root = New-SecurityFixtureRoot
        try {
            $path = Write-TestFile $root 'settings.txt' (('hermes' + '-production synthetic marker'))
            (Test-XqSecurityContent (Get-Item $path) $root).rule | Should -Contain 'synthetic-production-identifier'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'does not misclassify a large binary installer as oversized text' {
        $root = New-SecurityFixtureRoot
        try {
            $path = Join-Path $root 'Hermes-Setup.exe'
            $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $stream.SetLength(17MB)
                $stream.Position = 0
                $stream.Write([byte[]](0x4D, 0x5A, 0x00, 0x00), 0, 4)
            } finally { $stream.Dispose() }
            @(Test-XqSecurityContent (Get-Item $path) $root).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'accepts an external read-only denylist and masks its matching value' {
        $root = New-SecurityFixtureRoot; $deny = Join-Path ([IO.Path]::GetTempPath()) ('xq-private-' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            Write-TestFile $root 'safe.txt' 'FAKE-DENYLIST-FINGERPRINT-ONLY' | Out-Null
            Set-Content -LiteralPath $deny -Value 'FAKE-DENYLIST-FINGERPRINT-ONLY' -Encoding utf8NoBOM
            (Get-Item $deny).Attributes = (Get-Item $deny).Attributes -bor [IO.FileAttributes]::ReadOnly
            $result = Invoke-XqSecurityGate -TargetType Staging -Path $root -RepositoryRoot $script:securityRoot -PrivateDenylistPath $deny -DefenderProvider (New-PassingDefenderProvider)
            ($result.findings.rule) | Should -Contain 'private-denylist-match'
            ($result | ConvertTo-Json -Depth 12) | Should -Not -Match 'FAKE-DENYLIST-FINGERPRINT'
        } finally { if (Test-Path $deny) { (Get-Item $deny).Attributes = [IO.FileAttributes]::Normal; Remove-Item $deny -Force }; Remove-Item $root -Recurse -Force }
    }
    It 'rejects a denylist inside the repository boundary' {
        $root = New-SecurityFixtureRoot; $deny = Join-Path $script:securityRoot 'tests\fixtures\security\temporary-denylist.txt'
        try {
            Set-Content -LiteralPath $deny -Value 'synthetic' -Encoding utf8NoBOM; (Get-Item $deny).Attributes = (Get-Item $deny).Attributes -bor [IO.FileAttributes]::ReadOnly
            { Get-XqSecurityPrivateDenylist $deny $script:securityRoot $root } | Should -Throw
        } finally { if (Test-Path $deny) { (Get-Item $deny).Attributes = [IO.FileAttributes]::Normal; Remove-Item $deny -Force }; Remove-Item $root -Recurse -Force }
    }
    It 'blocks execution-policy bypass using PowerShell AST commands' {
        $root = New-SecurityFixtureRoot
        try {
            $path = Write-TestFile $root 'bad.ps1' 'pwsh -ExecutionPolicy Bypass -File test.ps1'
            (Test-XqSecurityPowerShellAst (Get-Item $path) $root).rule | Should -Contain 'ps-execution-policy-bypass'
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'blocks Defender tampering, firewall disablement, task creation, registry writes and uploads' {
        $root = New-SecurityFixtureRoot
        try {
            $path = Write-TestFile $root 'bad.ps1' "Add-MpPreference -ExclusionPath C:\\temp`nSet-NetFirewallProfile -Enabled `$false`nRegister-ScheduledTask -TaskName fake`nSet-ItemProperty HKLM:\\Software\\X -Name y -Value z`nInvoke-WebRequest https://example.com -Method Post -InFile safe.txt"
            $rules = (Test-XqSecurityPowerShellAst (Get-Item $path) $root).rule
            foreach ($rule in @('ps-defender-tamper','ps-firewall-disable','ps-scheduled-task','ps-registry-write','ps-network-upload')) { $rules | Should -Contain $rule }
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'permits the boundary-validating owned temporary cleanup helper' {
        $root = New-SecurityFixtureRoot
        try {
            $code = "function Remove-XqTemporaryDirectory { param(`$full) `$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()); `$item=Get-Item -LiteralPath `$full; if (`$full.StartsWith(`$tempRoot) -and `$full -match 'xq-hermes-build-' -and ((`$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) { Remove-Item -LiteralPath `$full -Recurse -Force } }"
            $path = Write-TestFile $root 'cleanup.ps1' $code
            $rules = foreach ($finding in @(Test-XqSecurityPowerShellAst (Get-Item $path) $root)) { $finding.rule }
            $rules | Should -Not -Contain 'ps-recursive-delete'
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'blocks a same-named cleanup helper without boundary proof' {
        $root = New-SecurityFixtureRoot
        try {
            $path = Write-TestFile $root 'cleanup.ps1' "function Remove-XqTemporaryDirectory { param(`$full) Remove-Item -LiteralPath `$full -Recurse -Force }"
            (Test-XqSecurityPowerShellAst (Get-Item $path) $root).rule | Should -Contain 'ps-recursive-delete'
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'quarantines ZIP traversal instead of extracting it' {
        $root = New-SecurityFixtureRoot; $zip = Join-Path $root 'bad.zip'
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
            try { $entry = $archive.CreateEntry('../escape.txt'); $writer = [IO.StreamWriter]::new($entry.Open()); try { $writer.Write('synthetic') } finally { $writer.Dispose() } } finally { $archive.Dispose() }
            (Invoke-XqSecurityGate -TargetType Zip -Path $zip -RepositoryRoot $script:securityRoot -DefenderProvider (New-PassingDefenderProvider)).status | Should -Be 'QUARANTINED'
            (Test-Path (Join-Path $root 'escape.txt')) | Should -BeFalse
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'quarantines duplicate ZIP entries' {
        $root = New-SecurityFixtureRoot; $zip = Join-Path $root 'duplicate.zip'
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
            try { foreach ($i in 1..2) { $entry = $archive.CreateEntry('same.txt'); $writer = [IO.StreamWriter]::new($entry.Open()); try { $writer.Write('synthetic') } finally { $writer.Dispose() } } } finally { $archive.Dispose() }
            (Invoke-XqSecurityGate -TargetType Zip -Path $zip -RepositoryRoot $script:securityRoot -DefenderProvider (New-PassingDefenderProvider)).status | Should -Be 'QUARANTINED'
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'does not skip a nested artifacts directory in staging' {
        $root = New-SecurityFixtureRoot
        try {
            Write-TestFile $root 'artifacts/.env' 'synthetic=true' | Out-Null
            (Invoke-XqSecurityGate -TargetType Staging -Path $root -RepositoryRoot $script:securityRoot -DefenderProvider (New-PassingDefenderProvider)).status | Should -Be 'QUARANTINED'
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'does not skip a nested artifacts directory in ZIP input' {
        $root = New-SecurityFixtureRoot; $zip = Join-Path $root 'nested.zip'
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
            try { $entry = $archive.CreateEntry('artifacts/.env'); $writer = [IO.StreamWriter]::new($entry.Open()); try { $writer.Write('synthetic=true') } finally { $writer.Dispose() } } finally { $archive.Dispose() }
            (Invoke-XqSecurityGate -TargetType Zip -Path $zip -RepositoryRoot $script:securityRoot -DefenderProvider (New-PassingDefenderProvider)).status | Should -Be 'QUARANTINED'
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'records separate Defender scans for the ZIP and its unpacked tree' {
        $root = New-SecurityFixtureRoot; $zip = Join-Path $root 'safe.zip'
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
            try { $entry = $archive.CreateEntry('safe.txt'); $writer = [IO.StreamWriter]::new($entry.Open()); try { $writer.Write('safe') } finally { $writer.Dispose() } } finally { $archive.Dispose() }
            $result = Invoke-XqSecurityGate -TargetType Zip -Path $zip -RepositoryRoot $script:securityRoot -DefenderProvider (New-PassingDefenderProvider)
            $result.status | Should -Be 'PASS'
            @($result.defender.scans).target | Should -Be @('zip', 'unpacked-zip')
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'does not pass when Defender never ran' {
        $root = New-SecurityFixtureRoot
        try {
            Write-TestFile $root 'safe.txt' 'safe' | Out-Null
            $provider = { param($target) [pscustomobject]@{ ran=$false; succeeded=$false; engineVersion=''; signatureVersion=''; signatureUpdated=[DateTimeOffset]::UtcNow } }
            (Invoke-XqSecurityGate -TargetType Staging -Path $root -RepositoryRoot $script:securityRoot -DefenderProvider $provider).status | Should -Be 'QUARANTINED'
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'does not pass when Defender signatures are stale' {
        $provider = { param($target) [pscustomobject]@{ ran=$true; succeeded=$true; engineVersion='1'; signatureVersion='1'; signatureUpdated=[DateTimeOffset]::UtcNow.AddDays(-8) } }
        (Invoke-XqSecurityDefender 'C:\\synthetic' $provider).status | Should -Be 'FAIL'
    }
    It 'does not pass when Defender reports a detection' {
        $provider = { param($target) [pscustomobject]@{ ran=$true; succeeded=$true; threatCount=1; engineVersion='1'; signatureVersion='1'; signatureUpdated=[DateTimeOffset]::UtcNow } }
        (Invoke-XqSecurityDefender 'C:\\synthetic' $provider).status | Should -Be 'FAIL'
    }
    It 'accepts a locked local MIT LICENSE with matching source version and hash' {
        $root = New-SecurityFixtureRoot
        try {
            $license = "MIT License`n`nPermission is hereby granted, free of charge, to any person obtaining a copy."
            Write-TestFile $root 'LICENSE' $license | Out-Null
            $hash = (Get-FileHash -LiteralPath (Join-Path $root 'LICENSE') -Algorithm SHA256).Hash.ToLowerInvariant()
            $commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            $manifest = [ordered]@{ licenseUrl=("https://example.com/upstream/{0}/LICENSE" -f $commit); licenseSha256=$hash; upstreamLicense='MIT'; upstreamCommit=$commit } | ConvertTo-Json
            $manifestPath = Write-TestFile $root 'product-manifest.json' $manifest
            @(Test-XqSecurityLicensePolicy -Root $root -ManifestPath $manifestPath -LicensePath (Join-Path $root 'LICENSE')).Count | Should -Be 0
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'rejects missing or hash-mismatched locked LICENSE inputs' {
        $root = New-SecurityFixtureRoot
        try {
            $commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            $manifest = [ordered]@{ licenseUrl=("https://example.com/upstream/{0}/LICENSE" -f $commit); licenseSha256=('0' * 64); upstreamLicense='MIT'; upstreamCommit=$commit } | ConvertTo-Json
            $manifestPath = Write-TestFile $root 'product-manifest.json' $manifest
            (Test-XqSecurityLicensePolicy -Root $root -ManifestPath $manifestPath -LicensePath (Join-Path $root 'HERMES-LICENSE.txt')).rule | Should -Contain 'license-file-missing'
        } finally { Remove-Item $root -Recurse -Force }
    }
    It 'writes quarantine evidence only into a caller-owned candidate directory' {
        $root = New-SecurityFixtureRoot; $candidate = Join-Path $root 'candidate'; [IO.Directory]::CreateDirectory($candidate) | Out-Null
        try {
            Write-TestFile $root '.env' 'synthetic=true' | Out-Null
            $owner = { param($path) [pscustomobject]@{ verified=$true } }
            $result = Invoke-XqSecurityGate -TargetType Evidence -Path $root -RepositoryRoot $script:securityRoot -CandidateOutputDirectory $candidate -DefenderProvider (New-PassingDefenderProvider) -OwnershipProvider $owner
            $result.status | Should -Be 'QUARANTINED'
            $result.quarantineEvidence | Should -Be (Join-Path $candidate 'security-gate-status.json')
        } finally { Remove-Item $root -Recurse -Force }
    }
}

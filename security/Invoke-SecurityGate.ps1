<#
.SYNOPSIS
  Offline security gate for XQ Hermes Agent Windows Kit release candidates.
.DESCRIPTION
  This file is both a PowerShell 7 entry point and a small, dependency-free library.
  Dot-source it in tests; invoke it normally to emit a JSON summary.  Findings never
  contain the matched secret.  The private denylist is deliberately represented only
  by a rule identifier, relative path, and match count only.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The gate only writes a caller-provided, ownership-verified quarantine status file.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'These helpers intentionally return collections or inspect multiple streams.')]
[CmdletBinding()]
param(
    [ValidateSet('Source', 'Staging', 'Zip', 'Evidence')][string]$TargetType,
    [string]$Path,
    [string]$RepositoryRoot,
    [string]$ManifestPath,
    [string]$LicensePath,
    [string]$PrivateDenylistPath,
    [string]$CandidateOutputDirectory,
    [string]$JsonPath,
    [scriptblock]$DefenderProvider,
    [scriptblock]$OwnershipProvider,
    [ValidateRange(1, 100000)][int]$MaximumZipEntries = 10000,
    [ValidateRange(1048576, 2147483647)][long]$MaximumZipBytes = 536870912,
    [switch]$SkipDefender
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-XqSecurityFullPath {
    param([Parameter(Mandatory)][string]$InputPath)
    return [IO.Path]::GetFullPath($InputPath)
}

function Test-XqSecurityChildPath {
    param([Parameter(Mandatory)][string]$Child, [Parameter(Mandatory)][string]$Parent)
    $childFull = Get-XqSecurityFullPath $Child
    $parentFull = (Get-XqSecurityFullPath $Parent).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return $childFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-XqSecurityDirectory {
    param([Parameter(Mandatory)][string]$Directory)
    $full = Get-XqSecurityFullPath $Directory
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Scan root does not exist or is not a directory: $full" }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Scan root must not be a reparse point.' }
    return $full
}

function Test-XqSecurityAlternateDataStreams {
    param([Parameter(Mandatory)][IO.FileInfo]$Item)
    # NTFS exposes ADS through the Stream parameter. Unsupported filesystems simply
    # return no alternate streams; any provider error is treated as a gate failure.
    try {
        $streams = @(Get-Item -LiteralPath $Item.FullName -Stream * -ErrorAction Stop | Where-Object { $_.Stream -notin @(':$DATA', '::$DATA') })
        return $streams.Count -eq 0
    } catch {
        if ($_.Exception.Message -match 'parameter.*Stream|not supported') { return $true }
        throw "Unable to inspect alternate data streams for '$($Item.Name)'."
    }
}

function Get-XqSecurityFiles {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][ValidateSet('Source', 'Staging', 'Zip', 'Evidence')][string]$TargetType)
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    $stack = [Collections.Generic.Stack[string]]::new(); $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if ($TargetType -eq 'Source' -and $directory -eq $Root -and $item.PSIsContainer -and $item.Name -in @('.git', 'TestResults', 'artifacts', 'evidence')) { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point is forbidden in scan tree: $($item.Name)" }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
            elseif ($item -is [IO.FileInfo]) {
                if (-not (Test-XqSecurityAlternateDataStreams -Item $item)) { throw "Alternate data stream is forbidden: $($item.Name)" }
                $files.Add($item)
            }
        }
    }
    return @($files)
}

function New-XqSecurityFinding {
    param([string]$Rule, [string]$RelativePath, [string]$Summary = 'policy violation', [string]$Severity = 'high')
    return [pscustomobject][ordered]@{ rule = $Rule; path = $RelativePath; summary = $Summary; severity = $Severity }
}

function Get-XqSecurityRelativePath {
    param([string]$Root, [string]$FullName)
    return [IO.Path]::GetRelativePath($Root, $FullName).Replace('\', '/')
}

function Test-XqSecurityFileNamePolicy {
    param([Parameter(Mandatory)][IO.FileInfo]$File, [Parameter(Mandatory)][string]$Root)
    $name = $File.Name
    $relative = Get-XqSecurityRelativePath $Root $File.FullName
    $bad = $name -match '(?i)(^\.env($|\.)|(^|[._-])\.ssh($|[._-])|id_(rsa|dsa|ecdsa|ed25519)|\.(pem|pfx|p12|key|kdbx)$|(^|[._-])(cookies?|sessions?|credentials?|secrets?|passwords?)([._-]|$)|\.(sqlite|db|mdb)$|(?:^|[._-])(backup|bak|dump|export)\.(zip|7z|tar|gz|sql|json|csv)$|\.log($|\.))'
    if ($bad) { return New-XqSecurityFinding -Rule 'forbidden-file-name' -RelativePath $relative -Summary 'sensitive or operational file name' }
    return $null
}

function Get-XqSecurityEntropy {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value.Length -eq 0) { return 0.0 }
    $counts = @{}
    foreach ($char in $Value.ToCharArray()) { $counts[$char] = 1 + [int]$counts[$char] }
    $entropy = 0.0
    foreach ($count in $counts.Values) { $p = $count / [double]$Value.Length; $entropy -= $p * [Math]::Log($p, 2) }
    return $entropy
}

function Test-XqSecurityContent {
    param([Parameter(Mandatory)][IO.FileInfo]$File, [Parameter(Mandatory)][string]$Root, [string[]]$PrivateFingerprints = @())
    # Binary inputs are not decoded. Probe a bounded prefix before applying the
    # text size limit so a normal signed installer is not misclassified merely
    # because it is larger than 16 MiB.
    $probeLength = [int][Math]::Min([long]8192, $File.Length)
    if ($probeLength -gt 0) {
        $probe = [byte[]]::new($probeLength)
        $stream = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { $read = $stream.Read($probe, 0, $probeLength) } finally { $stream.Dispose() }
        if ($read -gt 0 -and @($probe[0..($read - 1)] | Where-Object { $_ -eq 0 }).Count -gt 0) { return @() }
    }
    if ($File.Length -gt 16777216) { return @(New-XqSecurityFinding 'content-too-large' (Get-XqSecurityRelativePath $Root $File.FullName) 'text candidate exceeds 16 MiB') }
    $bytes = [IO.File]::ReadAllBytes($File.FullName)
    if ($bytes -contains 0) { return @() }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $relative = Get-XqSecurityRelativePath $Root $File.FullName
    $findings = [Collections.Generic.List[object]]::new()
    $patterns = [ordered]@{
        'private-key-header' = '(?m)^-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
        'authorization-secret' = '(?i)\bAuthorization\s*:\s*(?:Bearer|Basic|Token)\s+[^\s"'']{8,}'
        'token-assignment' = '(?i)\b(?:api[_-]?key|access[_-]?token|secret|password)\s*[:=]\s*["'']?(?!sk-test-|test-token-|must-not-be-read)[A-Za-z0-9_\-]{16,}'
        'synthetic-production-identifier' = '(?i)\b(?:hermes[-_.]?(?:prod|production)|prod[-_.]?hermes)\b'
    }
    foreach ($rule in $patterns.Keys) { if ($text -match $patterns[$rule]) { $findings.Add((New-XqSecurityFinding $rule $relative 'masked content pattern')) } }
    foreach ($token in [regex]::Matches($text, '(?<![A-Za-z0-9])[A-Za-z0-9+/]{32,}(?![A-Za-z0-9])')) {
        $looksLikeLockHash = $token.Value -match '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'
        $isIdentifier = $token.Value -match '^[A-Za-z]+$|^[A-Z][a-z]+(?:[A-Z][a-z]+)*$'
        $hasClasses = $token.Value -match '[A-Z]' -and $token.Value -match '[a-z]' -and $token.Value -match '\d'
        $prefixStart = [Math]::Max(0, $token.Index - 16)
        $prefix = $text.Substring($prefixStart, $token.Index - $prefixStart)
        $isUrlPath = $token.Value.StartsWith('/') -or $prefix -match '(?i)(https?://|/)'
        if (-not $looksLikeLockHash -and -not $isIdentifier -and -not $isUrlPath -and $hasClasses -and (Get-XqSecurityEntropy $token.Value) -ge 4.0) { $findings.Add((New-XqSecurityFinding 'high-entropy-token' $relative 'masked high entropy token')); break }
    }
    foreach ($fingerprint in $PrivateFingerprints) {
        if (-not [string]::IsNullOrWhiteSpace($fingerprint) -and $text.Contains($fingerprint, [StringComparison]::Ordinal)) {
            $findings.Add((New-XqSecurityFinding 'private-denylist-match' $relative 'private denylist rule matched'))
        }
    }
    return @($findings)
}

function Get-XqSecurityContainingFunctionName {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node)
    $parent = $Node.Parent
    while ($null -ne $parent) {
        if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { return $parent.Name }
        $parent = $parent.Parent
    }
    return ''
}

function Test-XqSecurityOwnedCleanup {
    param([Parameter(Mandatory)][Management.Automation.Language.CommandAst]$Command)
    $functionAst = $Command.Parent
    while ($null -ne $functionAst -and $functionAst -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $functionAst = $functionAst.Parent }
    if ($null -eq $functionAst) { return $false }
    $body = $functionAst.Extent.Text
    $provesTempRoot = $body -match '(?i)Get(?:-Xq(?:Security)?)?FullPath' -and $body -match '(?i)GetTempPath' -and $body -match '(?i)StartsWith'
    $provesOwnedPrefix = $body -match '(?i)xq-(?:hermes-(?:build|doctor)|security|tool-download)-'
    $provesNoReparse = $body -match '(?i)ReparsePoint'
    if ($provesTempRoot -and $provesOwnedPrefix -and $provesNoReparse) { return $true }
    # M4's older helper is additionally accepted only for its exact, fixed build
    # prefix and validated full/temp-root comparison. It cannot be reproduced by a
    # same-named function without those assertions.
    if ($functionAst.Name -eq 'Remove-XqTemporaryDirectory' -and $provesTempRoot -and $body -match "(?i)leaf\.StartsWith\('xq-hermes-build-'" -and $body -match '(?i)Refusing to recursively remove') { return $true }
    return $false
}

function Test-XqSecurityPowerShellAst {
    param([Parameter(Mandatory)][IO.FileInfo]$File, [Parameter(Mandatory)][string]$Root)
    if ($File.Extension -notin @('.ps1', '.psm1', '.psd1')) { return @() }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($File.FullName, [ref]$tokens, [ref]$errors)
    $relative = Get-XqSecurityRelativePath $Root $File.FullName
    $findings = [Collections.Generic.List[object]]::new()
    if (@($errors).Count -gt 0) { $findings.Add((New-XqSecurityFinding 'powershell-parse-error' $relative 'PowerShell parser rejected script')); return @($findings) }
    foreach ($command in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
        $name = $command.GetCommandName(); if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $text = $command.Extent.Text
        $rule = $null
        if ($name -match '^(Start-Process|Invoke-Expression)$' -and $text -match '(?i)(runas|\-verb\s+runas)') { $rule = 'ps-elevation' }
        elseif ($name -match '^(pwsh|powershell(?:\.exe)?|Set-ExecutionPolicy)$' -and $text -match '(?i)(\-ExecutionPolicy\s+(Bypass|Unrestricted)|Set-ExecutionPolicy\s+(Bypass|Unrestricted))') { $rule = 'ps-execution-policy-bypass' }
        elseif ($name -match '^(Add|Set|Remove)-MpPreference$' -and $text -match '(?i)(Exclusion|Disable)') { $rule = 'ps-defender-tamper' }
        elseif ($name -eq 'Set-NetFirewallProfile' -and $text -match '(?i)\-Enabled\s+(false|\$false)') { $rule = 'ps-firewall-disable' }
        elseif ($name -match '^(Register-ScheduledTask|New-ScheduledTask|schtasks(?:\.exe)?)$' -or ($name -eq 'Start-Process' -and $text -match '(?i)\bschtasks(?:\.exe)?\b')) { $rule = 'ps-scheduled-task' }
        elseif ($name -match '^(Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Set-Item|New-Item)$' -and $text -match '(?i)(HKLM:|HKCU:|Registry::)') { $rule = 'ps-registry-write' }
        elseif ($name -eq 'Remove-Item' -and $text -match '(?i)(\-Recurse|\-r)') {
            if (-not (Test-XqSecurityOwnedCleanup -Command $command)) { $rule = 'ps-recursive-delete' }
        }
        elseif ($name -match '^(Invoke-WebRequest|Invoke-RestMethod|curl(?:\.exe)?|wget(?:\.exe)?|Start-BitsTransfer)$' -and $text -match '(?i)(\-Method\s+(Post|Put|Patch)|\-T\s|\-UploadFile|\-InFile|\-d\s|\-\-data|\-\-form|\-TransferType\s+Upload)') { $rule = 'ps-network-upload' }
        if ($null -ne $rule) { $findings.Add((New-XqSecurityFinding $rule $relative 'dangerous PowerShell command')) }
    }
    return @($findings)
}

function Test-XqSecurityPSScriptAnalyzer {
    param([Parameter(Mandatory)][IO.FileInfo[]]$Files, [Parameter(Mandatory)][string]$Root)
    $scripts = @($Files | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') -and (Get-XqSecurityRelativePath $Root $_.FullName) -match '^(build|tools|security|ci|acceptance|governance)/' })
    if ($scripts.Count -eq 0) { return @() }
    $command = Get-Command -Name Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue
    if ($null -eq $command) { return @(New-XqSecurityFinding 'psscriptanalyzer-unavailable' '.' 'PSScriptAnalyzer is required for release scanning') }
    $findings = [Collections.Generic.List[object]]::new()
    $settingsPath = Join-Path $Root 'ci\PSScriptAnalyzerSettings.psd1'
    foreach ($file in $scripts) {
        $analyzerParameters = @{ Path = $file.FullName; Severity = @('Error', 'Warning'); ErrorAction = 'Stop' }
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) { $analyzerParameters.Remove('Severity'); $analyzerParameters.Settings = $settingsPath }
        foreach ($diagnostic in @(Invoke-ScriptAnalyzer @analyzerParameters)) {
            $findings.Add((New-XqSecurityFinding 'psscriptanalyzer-error' (Get-XqSecurityRelativePath $Root $file.FullName) ([string]$diagnostic.RuleName)))
        }
    }
    return @($findings)
}

function Get-XqSecurityPrivateDenylist {
    param([string]$DenylistPath, [string]$RepositoryRoot, [string]$ScanRoot)
    if ([string]::IsNullOrWhiteSpace($DenylistPath)) { return @() }
    $full = Get-XqSecurityFullPath $DenylistPath
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'Private denylist must be an existing file.' }
    if ((Test-XqSecurityChildPath $full $RepositoryRoot) -or (Test-XqSecurityChildPath $full $ScanRoot)) { throw 'Private denylist must be outside both repository and scan root.' }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) { throw 'Private denylist must be marked read-only.' }
    return @(Get-Content -LiteralPath $full -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith('#') })
}

function Test-XqSecurityLicensePolicy {
    param([Parameter(Mandatory)][string]$Root, [string]$ManifestPath, [string]$LicensePath)
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) { return @() }
    $manifestFile = Get-XqSecurityFullPath $ManifestPath
    if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) { return @(New-XqSecurityFinding 'license-manifest-missing' '.' 'manifest is unavailable') }
    try { $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16 } catch { return @(New-XqSecurityFinding 'license-manifest-invalid' '.' 'manifest is invalid JSON') }
    $findings = [Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace([string]$manifest.licenseUrl) -or [string]::IsNullOrWhiteSpace([string]$manifest.licenseSha256)) { $findings.Add((New-XqSecurityFinding 'license-lock-missing' '.' 'license URL or hash missing')); return @($findings) }
    if ([string]::IsNullOrWhiteSpace($LicensePath)) { return @(New-XqSecurityFinding 'license-path-missing' '.' 'explicit locked license path is required') }
    $license = Get-XqSecurityFullPath $LicensePath
    if (-not (Test-Path -LiteralPath $license -PathType Leaf)) { $findings.Add((New-XqSecurityFinding 'license-file-missing' '.' 'explicit locked license absent')) }
    else {
        $hash = (Get-FileHash -LiteralPath $license -Algorithm SHA256).Hash.ToLowerInvariant()
        $licenseRelative = if (Test-XqSecurityChildPath -Child $license -Parent $Root) { Get-XqSecurityRelativePath $Root $license } else { '<external-locked-license>' }
        if ($hash -cne [string]$manifest.licenseSha256) { $findings.Add((New-XqSecurityFinding 'license-hash-mismatch' $licenseRelative 'LICENSE hash does not match lock')) }
        $licenseText = Get-Content -LiteralPath $license -Raw -Encoding UTF8
        if ($licenseText -notmatch '(?im)^MIT License\s*$' -or $licenseText -notmatch 'Permission is hereby granted') { $findings.Add((New-XqSecurityFinding 'license-not-mit' $licenseRelative 'MIT markers missing')) }
    }
    if ([string]$manifest.upstreamLicense -ne 'MIT') { $findings.Add((New-XqSecurityFinding 'license-declaration-mismatch' '.' 'manifest must declare MIT')) }
    if ([string]$manifest.licenseUrl -notmatch [regex]::Escape([string]$manifest.upstreamCommit)) { $findings.Add((New-XqSecurityFinding 'license-source-version-mismatch' '.' 'license URL does not pin upstream commit')) }
    foreach ($notice in @(Get-ChildItem -LiteralPath (Join-Path $Root 'LICENSES') -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'README.md' })) {
        $noticeText = Get-Content -LiteralPath $notice.FullName -Raw -Encoding UTF8
        if ($noticeText -notmatch '(?im)^Source:\s*https?://' -or $noticeText -notmatch '(?im)^Version:\s*\S+') { $findings.Add((New-XqSecurityFinding 'third-party-notice-unproven' (Get-XqSecurityRelativePath $Root $notice.FullName) 'notice lacks source and version index')) }
    }
    return @($findings)
}

function Invoke-XqSecurityDefender {
    param([Parameter(Mandatory)][string]$ScanPath, [scriptblock]$Provider, [int]$MaximumSignatureAgeDays = 7)
    try {
        if ($null -eq $Provider) {
            $Provider = {
                param($target)
                $status = Get-MpComputerStatus -ErrorAction Stop
                $scanStarted = [DateTimeOffset]::UtcNow
                if (Get-Command -Name Start-MpScan -ErrorAction SilentlyContinue) {
                    Start-MpScan -ScanPath $target -ScanType CustomScan -ErrorAction Stop
                } else {
                    $mpCmd = Join-Path ${env:ProgramFiles} 'Windows Defender\MpCmdRun.exe'
                    if (-not (Test-Path -LiteralPath $mpCmd -PathType Leaf)) { throw 'Neither Start-MpScan nor MpCmdRun is available.' }
                    & $mpCmd -Scan -ScanType 3 -File $target
                    if ($LASTEXITCODE -ne 0) { throw 'MpCmdRun returned a failure exit code.' }
                }
                $targetFull = [IO.Path]::GetFullPath($target)
                $newThreats = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object {
                    $detectedAt = try { [DateTimeOffset]$_.InitialDetectionTime } catch { [DateTimeOffset]::MinValue }
                    $resources = @($_.Resources | ForEach-Object { [string]$_ })
                    $detectedAt -ge $scanStarted.AddMinutes(-1) -and @($resources | Where-Object { $_.Contains($targetFull, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
                })
                [pscustomobject]@{ ran=$true; succeeded=($newThreats.Count -eq 0); threatCount=$newThreats.Count; engineVersion=$status.AMEngineVersion; signatureVersion=$status.AntivirusSignatureVersion; signatureUpdated=$status.AntivirusSignatureLastUpdated }
            }
        }
        $result = & $Provider $ScanPath
        if ($null -eq $result -or -not [bool]$result.ran -or -not [bool]$result.succeeded) { return [pscustomobject]@{ status='FAIL'; reason='Defender did not complete'; engineVersion=$null; signatureVersion=$null; scannedAtUtc=[DateTimeOffset]::UtcNow.ToString('o') } }
        $threatCount = if ($result.PSObject.Properties.Name -contains 'threatCount') { [int]$result.threatCount } else { 0 }
        if ($threatCount -gt 0) { return [pscustomobject]@{ status='FAIL'; reason='Defender detected a threat'; engineVersion=[string]$result.engineVersion; signatureVersion=[string]$result.signatureVersion; scannedAtUtc=[DateTimeOffset]::UtcNow.ToString('o') } }
        if ([string]::IsNullOrWhiteSpace([string]$result.engineVersion) -or [string]::IsNullOrWhiteSpace([string]$result.signatureVersion)) { return [pscustomobject]@{ status='FAIL'; reason='Defender version evidence is missing'; engineVersion=[string]$result.engineVersion; signatureVersion=[string]$result.signatureVersion; scannedAtUtc=[DateTimeOffset]::UtcNow.ToString('o') } }
        $updated = [DateTimeOffset]$result.signatureUpdated
        if ($updated -lt [DateTimeOffset]::UtcNow.AddDays(-$MaximumSignatureAgeDays)) { return [pscustomobject]@{ status='FAIL'; reason='Defender signatures are too old'; engineVersion=[string]$result.engineVersion; signatureVersion=[string]$result.signatureVersion; scannedAtUtc=[DateTimeOffset]::UtcNow.ToString('o') } }
        return [pscustomobject]@{ status='PASS'; reason='completed'; engineVersion=[string]$result.engineVersion; signatureVersion=[string]$result.signatureVersion; scannedAtUtc=[DateTimeOffset]::UtcNow.ToString('o') }
    } catch { return [pscustomobject]@{ status='FAIL'; reason='Defender provider exception'; engineVersion=$null; signatureVersion=$null; scannedAtUtc=[DateTimeOffset]::UtcNow.ToString('o') } }
}

function Remove-XqSecurityTemporaryDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $full = Get-XqSecurityFullPath $Path
    $tempRoot = (Get-XqSecurityFullPath ([IO.Path]::GetTempPath())).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $full
    if (-not $full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or -not $leaf.StartsWith('xq-security-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove an unverified security temporary directory.' }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Security temporary directory is a reparse point.' }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

function Expand-XqSecurityZip {
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$Destination, [int]$MaximumEntries, [long]$MaximumBytes)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($archive.Entries.Count -gt $MaximumEntries) { throw 'ZIP has too many entries.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); $total = 0L
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\\', '/')
            if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name -match ':' -or $name.Split('/') -contains '..' -or -not $seen.Add($name)) { throw 'ZIP contains an unsafe, absolute, alternate-stream, traversal, or duplicate entry.' }
            $total += $entry.Length; if ($total -gt $MaximumBytes) { throw 'ZIP expanded size exceeds limit.' }
        }
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith('/')) { continue }
            $target = Join-Path $Destination $entry.FullName
            $targetFull = Get-XqSecurityFullPath $target
            if (-not (Test-XqSecurityChildPath $targetFull $Destination)) { throw 'ZIP entry escapes extraction root.' }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $targetFull)) | Out-Null
            $in = $entry.Open(); $out = [IO.File]::Open($targetFull, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
        }
    } finally { $archive.Dispose() }
}

function Write-XqSecurityQuarantineEvidence {
    param([Parameter(Mandatory)]$Report, [string]$CandidateOutputDirectory, [scriptblock]$OwnershipProvider)
    if ([string]::IsNullOrWhiteSpace($CandidateOutputDirectory)) { return $null }
    $candidate = Get-XqSecurityFullPath $CandidateOutputDirectory
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { throw 'Candidate output directory must already exist.' }
    if ($candidate -match '^[A-Za-z]:\\?$') { throw 'Candidate output directory cannot be a volume root.' }
    $item = Get-Item -LiteralPath $candidate -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Candidate output directory must not be a reparse point.' }
    if ($null -eq $OwnershipProvider) {
        try {
            $owner = (Get-Acl -LiteralPath $candidate -ErrorAction Stop).Owner
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        } catch { throw 'Candidate output directory ownership could not be verified.' }
        if ([string]::IsNullOrWhiteSpace($owner) -or $owner -ine $identity) { throw 'Candidate output directory is not owned by the invoking identity.' }
    } else {
        $ownership = & $OwnershipProvider $candidate
        if ($null -eq $ownership -or -not [bool]$ownership.verified) { throw 'Candidate output directory is not owned by the invoking identity.' }
    }
    $path = Join-Path $candidate 'security-gate-status.json'
    $Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

function Invoke-XqSecurityGate {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('Source', 'Staging', 'Zip', 'Evidence')][string]$TargetType,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$ManifestPath,
        [string]$LicensePath,
        [string]$PrivateDenylistPath,
        [string]$CandidateOutputDirectory,
        [scriptblock]$DefenderProvider,
        [scriptblock]$OwnershipProvider,
        [int]$MaximumZipEntries = 10000,
        [long]$MaximumZipBytes = 536870912,
        [switch]$SkipDefender
    )
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Security gate requires PowerShell 7 or later.' }
    $repo = Assert-XqSecurityDirectory $RepositoryRoot
    $temporary = $null
    try {
        if ($TargetType -eq 'Zip' -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $temporary = Join-Path ([IO.Path]::GetTempPath()) ('xq-security-' + [guid]::NewGuid().ToString('N')); [IO.Directory]::CreateDirectory($temporary) | Out-Null
            Expand-XqSecurityZip -ZipPath (Get-XqSecurityFullPath $Path) -Destination $temporary -MaximumEntries $MaximumZipEntries -MaximumBytes $MaximumZipBytes
            $root = Assert-XqSecurityDirectory $temporary
        } else { $root = Assert-XqSecurityDirectory $Path }
        $private = Get-XqSecurityPrivateDenylist -DenylistPath $PrivateDenylistPath -RepositoryRoot $repo -ScanRoot $root
        $findings = [Collections.Generic.List[object]]::new()
        $files = @(Get-XqSecurityFiles -Root $root -TargetType $TargetType)
        foreach ($file in $files) {
            $nameFinding = Test-XqSecurityFileNamePolicy -File $file -Root $root; if ($null -ne $nameFinding) { $findings.Add($nameFinding) }
            foreach ($finding in Test-XqSecurityContent -File $file -Root $root -PrivateFingerprints $private) { $findings.Add($finding) }
            $relativeFile = Get-XqSecurityRelativePath $root $file.FullName
            if (-not ($TargetType -eq 'Source' -and $relativeFile -notmatch '^(build|tools|security|ci|acceptance|governance)/')) { foreach ($finding in Test-XqSecurityPowerShellAst -File $file -Root $root) { $findings.Add($finding) } }
        }
        foreach ($finding in Test-XqSecurityPSScriptAnalyzer -Files $files -Root $root) { $findings.Add($finding) }
        if ($TargetType -eq 'Source') { foreach ($finding in Test-XqSecurityLicensePolicy -Root $root -ManifestPath $ManifestPath -LicensePath $LicensePath) { $findings.Add($finding) } }
        $defenderScans = [Collections.Generic.List[object]]::new()
        $defenderTargets = if ($TargetType -eq 'Zip' -and $null -ne $temporary) { @([pscustomobject]@{ kind='zip'; path=(Get-XqSecurityFullPath $Path) }, [pscustomobject]@{ kind='unpacked-zip'; path=$root }) } else { @([pscustomobject]@{ kind='directory'; path=$root }) }
        foreach ($target in $defenderTargets) {
            $scan = if ($SkipDefender) { [pscustomobject]@{ status='SKIPPED'; reason='explicitly skipped'; engineVersion=$null; signatureVersion=$null; scannedAtUtc=[DateTimeOffset]::UtcNow.ToString('o') } } else { Invoke-XqSecurityDefender -ScanPath $target.path -Provider $DefenderProvider }
            $defenderScans.Add([pscustomobject]@{ target=$target.kind; status=$scan.status; reason=$scan.reason; engineVersion=$scan.engineVersion; signatureVersion=$scan.signatureVersion; scannedAtUtc=$scan.scannedAtUtc })
        }
        $defenderStatus = if (@($defenderScans | Where-Object { $_.status -ne 'PASS' }).Count -eq 0) { 'PASS' } elseif (@($defenderScans | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0) { 'FAIL' } else { 'SKIPPED' }
        $defender = [pscustomobject]@{ status=$defenderStatus; scans=@($defenderScans); scannedAtUtc=[DateTimeOffset]::UtcNow.ToString('o') }
        if ($defender.status -ne 'PASS' -and $defender.status -ne 'SKIPPED') { $findings.Add((New-XqSecurityFinding 'defender-scan-failed' '.' $defender.reason)) }
        $status = if ($findings.Count -eq 0 -and $defender.status -eq 'PASS') { 'PASS' } else { 'QUARANTINED' }
        $report = [pscustomobject][ordered]@{ schemaVersion='1.0'; targetType=$TargetType; status=$status; scannedAtUtc=[DateTimeOffset]::UtcNow.ToString('o'); ruleVersion='m6-1'; findingCount=$findings.Count; findings=@($findings); defender=$defender; quarantineEvidence=$null }
        if ($status -eq 'QUARANTINED') { $report.quarantineEvidence = Write-XqSecurityQuarantineEvidence -Report $report -CandidateOutputDirectory $CandidateOutputDirectory -OwnershipProvider $OwnershipProvider }
        return $report
    } catch {
        $report = [pscustomobject][ordered]@{ schemaVersion='1.0'; targetType=$TargetType; status='QUARANTINED'; scannedAtUtc=[DateTimeOffset]::UtcNow.ToString('o'); ruleVersion='m6-1'; findingCount=1; findings=@((New-XqSecurityFinding 'security-gate-exception' '.' 'gate rejected target')); defender=$null; quarantineEvidence=$null }
        if (-not [string]::IsNullOrWhiteSpace($CandidateOutputDirectory)) { $report.quarantineEvidence = Write-XqSecurityQuarantineEvidence -Report $report -CandidateOutputDirectory $CandidateOutputDirectory -OwnershipProvider $OwnershipProvider }
        return $report
    } finally { if ($null -ne $temporary -and (Test-Path -LiteralPath $temporary)) { Remove-XqSecurityTemporaryDirectory -Path $temporary } }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($TargetType) -or [string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($RepositoryRoot)) { throw 'TargetType, Path, and RepositoryRoot are required when invoking the security gate.' }
    $gateParameters = @{
        TargetType = $TargetType; Path = $Path; RepositoryRoot = $RepositoryRoot
        ManifestPath = $ManifestPath; LicensePath = $LicensePath; PrivateDenylistPath = $PrivateDenylistPath
        CandidateOutputDirectory = $CandidateOutputDirectory; DefenderProvider = $DefenderProvider; OwnershipProvider = $OwnershipProvider
        MaximumZipEntries = $MaximumZipEntries; MaximumZipBytes = $MaximumZipBytes; SkipDefender = $SkipDefender
    }
    $report = Invoke-XqSecurityGate @gateParameters
    $json = $report | ConvertTo-Json -Depth 12
    if (-not [string]::IsNullOrWhiteSpace($JsonPath)) { $json | Set-Content -LiteralPath $JsonPath -Encoding utf8NoBOM }
    $json
    if ($report.status -ne 'PASS') { exit 1 }
}

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository PowerShell sources use UTF-8 without BOM for cross-tool consistency.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal helpers operate only on validated staging/output paths owned by this invocation.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ManifestPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$VerifiedArtifactPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$RenderedContentPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$DiagnoseToolPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$HermesLicensePath,

    [Parameter()]
    [string]$ThirdPartyNoticesPath,

    [Parameter()]
    [string]$TrustedSourcesPath = (Join-Path $PSScriptRoot '..\manifest\trusted-sources.json'),

    [Parameter(Mandatory)]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Assert-XqPowerShell7

function Get-XqFullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Test-XqReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Assert-XqSafeSourceFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required source file is missing: $Path"
    }
    if (Test-XqReparsePoint -Path $Path) {
        throw "Reparse points are not accepted as package inputs: $Path"
    }

    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        $streams = @(Get-Item -LiteralPath $Path -Stream * -ErrorAction SilentlyContinue |
            Where-Object { $_.Stream -notin @(':$DATA', '$DATA') })
        if ($streams.Count -gt 0) {
            throw "Alternate data streams are not accepted as package inputs: $Path"
        }
    }
}

function Copy-XqPackageFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$StagingRoot
    )

    Assert-XqSafeSourceFile -Path $Source
    $root = (Get-XqFullPath -Path $StagingRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $destinationFull = Get-XqFullPath -Path $Destination
    if (-not $destinationFull.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package destination escapes staging root: $Destination"
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destinationFull)) | Out-Null
    [IO.File]::Copy((Get-XqFullPath -Path $Source), $destinationFull, $false)
}

function Get-XqSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-XqSortedRelativeFile {
    param([Parameter(Mandatory)][string]$Root)

    $rootFull = Get-XqFullPath -Path $Root
    $relativeFiles = [Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force)) {
        $relativeFiles.Add([IO.Path]::GetRelativePath($rootFull, $file.FullName).Replace('\', '/'))
    }
    $result = $relativeFiles.ToArray()
    [Array]::Sort($result, [StringComparer]::Ordinal)
    return $result
}

function Remove-XqTemporaryDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $full = Get-XqFullPath -Path $Path
    $tempRoot = (Get-XqFullPath -Path ([IO.Path]::GetTempPath())).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $leaf = Split-Path -Leaf $full
    if (-not $full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $leaf.StartsWith('xq-hermes-build-', [StringComparison]::Ordinal)) {
        throw "Refusing to recursively remove an unverified temporary path: $full"
    }
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

function New-XqDeterministicZip {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationZip,
        [Parameter(Mandatory)][DateTimeOffset]$Timestamp
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $sourceFull = (Get-XqFullPath -Path $SourceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $destinationFull = Get-XqFullPath -Path $DestinationZip
    $stream = [IO.File]::Open($destinationFull, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
        try {
            foreach ($relative in @(Get-XqSortedRelativeFile -Root $sourceFull)) {
                $filePath = Join-Path $sourceFull $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
                $file = Get-Item -LiteralPath $filePath -Force
                if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Reparse point found in staging: $($file.FullName)"
                }
                if ($relative.StartsWith('../', [StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relative)) {
                    throw "Unsafe ZIP entry path: $relative"
                }
                $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $Timestamp
                $entry.ExternalAttributes = 0
                $sourceStream = [IO.File]::OpenRead($file.FullName)
                try {
                    $output = $entry.Open()
                    try { $sourceStream.CopyTo($output) } finally { $output.Dispose() }
                }
                finally { $sourceStream.Dispose() }
            }

            $emptyDirectories = [Collections.Generic.List[string]]::new()
            foreach ($directory in @(Get-ChildItem -LiteralPath $sourceFull -Directory -Recurse -Force)) {
                if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Reparse point found in staging: $($directory.FullName)"
                }
                if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
                    $emptyDirectories.Add(([IO.Path]::GetRelativePath($sourceFull, $directory.FullName).Replace('\', '/') + '/'))
                }
            }
            $emptyDirectoryArray = $emptyDirectories.ToArray()
            [Array]::Sort($emptyDirectoryArray, [StringComparer]::Ordinal)
            foreach ($relativeDirectory in $emptyDirectoryArray) {
                $directoryEntry = $archive.CreateEntry($relativeDirectory)
                $directoryEntry.LastWriteTime = $Timestamp
                $directoryEntry.ExternalAttributes = 0
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

$manifestFull = Get-XqFullPath -Path $ManifestPath
$artifactFull = Get-XqFullPath -Path $VerifiedArtifactPath
$contentFull = Get-XqFullPath -Path $RenderedContentPath
$diagnoseFull = Get-XqFullPath -Path $DiagnoseToolPath
$licenseFull = Get-XqFullPath -Path $HermesLicensePath
$outputFull = Get-XqFullPath -Path $OutputDirectory

$manifest = Get-Content -LiteralPath $manifestFull -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 20 -DateKind String
$trustedSources = Get-XqTrustedSources -Path $TrustedSourcesPath
Assert-XqManifest -Manifest $manifest -TrustedSources $trustedSources -Formal | Out-Null
foreach ($field in @(
        'schemaVersion', 'buildMode', 'productVersion', 'releaseChannel', 'hermesReleaseTag', 'hermesVersion',
        'upstreamCommit', 'desktopBuildCommit', 'runtimeInstallPin', 'sourcePageUrl', 'officialAssetUrl',
        'officialAssetName', 'officialSha256', 'licenseUrl', 'licenseSha256', 'signatureStatus', 'supportedOs', 'buildDate',
        'upstreamLicense', 'xqTelemetry', 'runtimeInternetRequired')) {
    if (-not $manifest.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$manifest.$field)) {
        throw "Manifest is missing required field: $field"
    }
}
if ([string]$manifest.buildMode -ne 'formal') {
    throw 'Only a formally locked manifest can be packaged.'
}
if ([string]$manifest.releaseChannel -ne 'stable') {
    throw 'Only the stable release channel can be packaged.'
}
if ([string]$manifest.productVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw 'Manifest productVersion must be a semantic version.'
}
if ([string]$manifest.hermesVersion -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw 'Manifest hermesVersion must be a concrete version.'
}
foreach ($commitField in @('upstreamCommit', 'desktopBuildCommit')) {
    if ([string]$manifest.$commitField -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Manifest $commitField must be a complete 40-character commit."
    }
}
if ([string]$manifest.runtimeInstallPin.type -ne 'commit' -or
    [string]$manifest.runtimeInstallPin.value -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'Manifest runtimeInstallPin must lock a complete commit.'
}
if ([string]$manifest.hermesReleaseTag -notmatch '^v\d{4}\.\d{1,2}\.\d{1,2}$') {
    throw 'Manifest hermesReleaseTag must be a concrete stable tag.'
}
$signatureStatus = [string]$manifest.signatureStatus
if ($signatureStatus -notin @('Valid', 'Unavailable')) {
    throw 'An invalid or unknown signature status cannot be packaged.'
}
if ([string]$manifest.signature.status -ne $signatureStatus) {
    throw 'Manifest signature status fields do not agree.'
}
if ($signatureStatus -eq 'Unavailable' -and [string]::IsNullOrWhiteSpace([string]$manifest.signature.waiverId)) {
    throw 'An unavailable signature requires an explicit waiver.'
}
if ([bool]$manifest.xqTelemetry) {
    throw 'xqTelemetry must remain false.'
}
if (-not [bool]$manifest.runtimeInternetRequired) {
    throw 'The first release must disclose that runtime Internet access is required.'
}
$supportedOs = @($manifest.supportedOs)
if ($supportedOs.Count -ne 1 -or [string]$supportedOs[0] -ne 'Windows 11 x64') {
    throw 'The first release supports only Windows 11 x64.'
}
if ([string]$manifest.upstreamLicense -ne 'MIT') {
    throw 'Only the locked Hermes MIT license is accepted for this package.'
}
if ([string]$manifest.officialAssetName -ne [IO.Path]::GetFileName($artifactFull)) {
    throw 'Verified artifact filename does not match manifest officialAssetName.'
}
$expectedHash = ([string]$manifest.officialSha256).ToLowerInvariant()
if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
    throw 'Manifest officialSha256 must be a complete SHA-256 value.'
}
$actualHash = Get-XqSha256 -Path $artifactFull
if ($actualHash -cne $expectedHash) {
    throw "Verified artifact hash mismatch. Expected $expectedHash but received $actualHash."
}
$expectedLicenseHash = ([string]$manifest.licenseSha256).ToLowerInvariant()
if ($expectedLicenseHash -notmatch '^[0-9a-f]{64}$') {
    throw 'Manifest licenseSha256 must be a complete SHA-256 value.'
}
Assert-XqSafeSourceFile -Path $licenseFull
$actualLicenseHash = Get-XqSha256 -Path $licenseFull
if ($actualLicenseHash -cne $expectedLicenseHash) {
    throw "Locked Hermes LICENSE hash mismatch. Expected $expectedLicenseHash but received $actualLicenseHash."
}

if ($manifest.buildDate -is [DateTime]) {
    if ($manifest.buildDate.Kind -ne [DateTimeKind]::Utc) {
        throw 'Manifest buildDate must be expressed in UTC.'
    }
    $buildTime = [DateTimeOffset]::new([DateTime]$manifest.buildDate)
}
elseif ($manifest.buildDate -is [DateTimeOffset]) {
    if ($manifest.buildDate.Offset -ne [TimeSpan]::Zero) {
        throw 'Manifest buildDate must be expressed in UTC.'
    }
    $buildTime = [DateTimeOffset]$manifest.buildDate
}
else {
    $buildDateText = [string]$manifest.buildDate
    if ($buildDateText -notmatch 'Z$') {
        throw 'Manifest buildDate must be expressed in UTC.'
    }
    $buildTime = [DateTimeOffset]::Parse($buildDateText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
}
if ($buildTime.Year -lt 1980 -or $buildTime.Year -gt 2107) {
    throw 'Manifest buildDate is outside the ZIP timestamp range.'
}
$zipTicks = [TimeSpan]::TicksPerSecond * 2
$buildTime = $buildTime.AddTicks(-($buildTime.Ticks % $zipTicks))

$safeProductVersion = ([string]$manifest.productVersion) -replace '[^0-9A-Za-z._-]', '_'
$safeHermesVersion = ([string]$manifest.hermesVersion) -replace '[^0-9A-Za-z._-]', '_'
$packageBaseName = "XQ-Hermes-Agent-Windows-v$safeProductVersion-Hermes-$safeHermesVersion"
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
$zipPath = Join-Path $outputFull "$packageBaseName.zip"
$zipHashPath = Join-Path $outputFull "$packageBaseName.sha256.txt"
$inventoryPath = Join-Path $outputFull "$packageBaseName.inventory.json"
foreach ($target in @($zipPath, $zipHashPath, $inventoryPath)) {
    if (Test-Path -LiteralPath $target) {
        throw "Refusing to overwrite an existing package output: $target"
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("xq-hermes-build-" + [Guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $tempRoot "XQ-Hermes-Agent-Windows-v$safeProductVersion"
$temporarySuffix = ".tmp-$([Guid]::NewGuid().ToString('N'))"
$temporaryZip = "$zipPath$temporarySuffix"
$temporaryHashReceipt = "$zipHashPath$temporarySuffix"
$temporaryInventory = "$inventoryPath$temporarySuffix"
$publishedOutputs = [Collections.Generic.List[string]]::new()

$requiredContent = @(
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

try {
    [IO.Directory]::CreateDirectory($packageRoot) | Out-Null

    $actualContent = @(Get-ChildItem -LiteralPath $contentFull -File -Recurse -Force | ForEach-Object {
            [IO.Path]::GetRelativePath($contentFull, $_.FullName).Replace('/', '\')
        } | Sort-Object)
    $expectedContent = @($requiredContent | Sort-Object)
    $unexpected = @($actualContent | Where-Object { $_ -notin $expectedContent })
    $missing = @($expectedContent | Where-Object { $_ -notin $actualContent })
    if ($unexpected.Count -gt 0 -or $missing.Count -gt 0) {
        throw "Rendered content contract mismatch. Missing=[$($missing -join ', ')] Unexpected=[$($unexpected -join ', ')]"
    }

    foreach ($relative in $requiredContent) {
        Copy-XqPackageFile -Source (Join-Path $contentFull $relative) -Destination (Join-Path $packageRoot $relative) -StagingRoot $packageRoot
    }

    Copy-XqPackageFile -Source $artifactFull -Destination (Join-Path $packageRoot "01-Hermes官方安装器\$($manifest.officialAssetName)") -StagingRoot $packageRoot
    Copy-XqPackageFile -Source $diagnoseFull -Destination (Join-Path $packageRoot '03-诊断工具\Hermes-XQ-Diagnose.ps1') -StagingRoot $packageRoot
    Copy-XqPackageFile -Source $licenseFull -Destination (Join-Path $packageRoot '04-许可与来源\HERMES-LICENSE.txt') -StagingRoot $packageRoot

    $noticesDestination = Join-Path $packageRoot '04-许可与来源\THIRD-PARTY-NOTICES'
    [IO.Directory]::CreateDirectory($noticesDestination) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($ThirdPartyNoticesPath)) {
        $noticesFull = Get-XqFullPath -Path $ThirdPartyNoticesPath
        if (-not (Test-Path -LiteralPath $noticesFull -PathType Container)) {
            throw "Third-party notices directory does not exist: $noticesFull"
        }
        if (Test-XqReparsePoint -Path $noticesFull) {
            throw 'Third-party notices directory cannot be a reparse point.'
        }
        foreach ($notice in @(Get-ChildItem -LiteralPath $noticesFull -File -Recurse -Force)) {
            $relative = [IO.Path]::GetRelativePath($noticesFull, $notice.FullName)
            Copy-XqPackageFile -Source $notice.FullName -Destination (Join-Path $noticesDestination $relative) -StagingRoot $packageRoot
        }
    }

    $publicManifest = [ordered]@{}
    foreach ($name in @(
            'schemaVersion', 'productVersion', 'releaseChannel', 'hermesReleaseTag', 'hermesVersion',
            'upstreamCommit', 'desktopBuildCommit', 'runtimeInstallPin', 'sourcePageUrl',
            'officialAssetUrl', 'officialAssetName', 'officialSha256', 'signatureStatus', 'signature',
            'supportedOs', 'buildDate', 'upstreamLicense', 'xqTelemetry', 'runtimeInternetRequired')) {
        if ($manifest.PSObject.Properties[$name]) { $publicManifest[$name] = $manifest.$name }
    }
    $sourceVersionPath = Join-Path $packageRoot '04-许可与来源\SOURCE-AND-VERSION.json'
    [IO.File]::WriteAllText($sourceVersionPath, (($publicManifest | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))

    $hashLines = [Collections.Generic.List[string]]::new()
    foreach ($relative in @(Get-XqSortedRelativeFile -Root $packageRoot)) {
        $filePath = Join-Path $packageRoot $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $hashLines.Add("$(Get-XqSha256 -Path $filePath) *$relative")
    }
    $sumsPath = Join-Path $packageRoot '04-许可与来源\SHA256SUMS.txt'
    [IO.File]::WriteAllText($sumsPath, (($hashLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

    $inventory = @()
    foreach ($relative in @(Get-XqSortedRelativeFile -Root $packageRoot)) {
        $filePath = Join-Path $packageRoot $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $file = Get-Item -LiteralPath $filePath
        $inventory += [ordered]@{
            path   = $relative
            bytes  = $file.Length
            sha256 = Get-XqSha256 -Path $file.FullName
        }
    }

    New-XqDeterministicZip -SourceRoot $tempRoot -DestinationZip $temporaryZip -Timestamp $buildTime
    $zipHash = Get-XqSha256 -Path $temporaryZip
    [IO.File]::WriteAllText($temporaryHashReceipt, "$zipHash *$([IO.Path]::GetFileName($zipPath))`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($temporaryInventory, (($inventory | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))

    [IO.File]::Move($temporaryZip, $zipPath)
    $publishedOutputs.Add($zipPath)
    [IO.File]::Move($temporaryHashReceipt, $zipHashPath)
    $publishedOutputs.Add($zipHashPath)
    [IO.File]::Move($temporaryInventory, $inventoryPath)
    $publishedOutputs.Add($inventoryPath)

    [pscustomobject]@{
        PackagePath   = $zipPath
        PackageSha256 = $zipHash
        HashReceipt   = $zipHashPath
        InventoryPath = $inventoryPath
        FileCount     = $inventory.Count
    }
}
catch {
    foreach ($publishedPath in $publishedOutputs) {
        if (Test-Path -LiteralPath $publishedPath -PathType Leaf) {
            Remove-Item -LiteralPath $publishedPath -Force
        }
    }
    throw
}
finally {
    foreach ($temporaryPath in @($temporaryZip, $temporaryHashReceipt, $temporaryInventory)) {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
    Remove-XqTemporaryDirectory -Path $tempRoot
}

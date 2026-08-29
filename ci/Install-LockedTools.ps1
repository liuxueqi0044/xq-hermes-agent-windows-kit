[CmdletBinding()]
param(
    [string]$LockPath = (Join-Path $PSScriptRoot 'tool-versions.json'),
    [string]$ModuleRoot = (Join-Path ([IO.Path]::GetTempPath()) ('xq-locked-modules-' + [Guid]::NewGuid().ToString('N')))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lock = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
[IO.Directory]::CreateDirectory($ModuleRoot) | Out-Null
$integrity = [Collections.Generic.List[object]]::new()
function Remove-XqLockedToolDownload {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $separator = [IO.Path]::DirectorySeparatorChar
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd($separator) + $separator
    $leaf = Split-Path -Leaf $full
    if (-not $full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or -not $leaf.StartsWith('xq-tool-download-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove an unverified tool download directory.' }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Tool download directory is a reparse point.' }
        if ($PSCmdlet.ShouldProcess($full, 'Remove verified XQ tool download directory')) {
            Remove-Item -LiteralPath $full -Recurse -Force
        }
    }
}
foreach ($tool in @('Pester', 'PSScriptAnalyzer')) {
    $entry = $lock.tools.$tool
    if ($null -eq $entry -or [string]$entry.packageSha256 -notmatch '^[a-f0-9]{64}$' -or [int64]$entry.packageBytes -lt 1) { throw "Tool lock is missing an audited package digest: $tool" }
    $downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ('xq-tool-download-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($downloadRoot) | Out-Null
    $archive = Join-Path $downloadRoot ($tool + '-' + [string]$entry.version + '.nupkg')
    try {
        $uri = "https://www.powershellgallery.com/api/v2/package/$tool/$([string]$entry.version)"
        Invoke-WebRequest -Uri $uri -OutFile $archive -UseBasicParsing
        $item = Get-Item -LiteralPath $archive
        $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($item.Length -ne [int64]$entry.packageBytes -or $actualHash -cne [string]$entry.packageSha256) { throw "Verified package digest mismatch: $tool" }
        $extract = Join-Path $downloadRoot 'extract'
        Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
        $manifest = Get-ChildItem -LiteralPath $extract -Filter ($tool + '.psd1') -File -Recurse | Select-Object -First 1
        if ($null -eq $manifest) { throw "Verified package has no $tool.psd1 module manifest." }
        $destination = Join-Path (Join-Path $ModuleRoot $tool) ([string]$entry.version)
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        Get-ChildItem -LiteralPath $manifest.Directory.FullName -Force | Copy-Item -Destination $destination -Recurse -Force
        $integrity.Add([ordered]@{ name=$tool; version=[string]$entry.version; bytes=$item.Length; sha256=$actualHash; source=$uri })
    } finally {
        if (Test-Path -LiteralPath $downloadRoot) { Remove-XqLockedToolDownload -Path $downloadRoot }
    }
}
$modulePath = [IO.Path]::GetFullPath($ModuleRoot)
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    "XQ_LOCKED_MODULE_ROOT=$modulePath" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "PSModulePath=$modulePath$([IO.Path]::PathSeparator)$env:PSModulePath" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}
$integrity | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ModuleRoot 'tool-integrity.json') -Encoding utf8
Write-Output ($integrity | ConvertTo-Json -Depth 8)

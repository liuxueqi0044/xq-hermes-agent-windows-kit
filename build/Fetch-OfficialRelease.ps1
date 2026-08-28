[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$TrustedSourcesPath = (Join-Path $PSScriptRoot '..\manifest\trusted-sources.json'),
    [Parameter(Mandatory)][string]$CacheDirectory,
    [string]$ReceiptPath,
    [scriptblock]$NetworkInvoker,
    [ValidateRange(1048576, 2147483647)][long]$MaximumArtifactBytes = 1073741824,
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
try {
    Assert-XqPowerShell7
    $trusted = Get-XqTrustedSources -Path $TrustedSourcesPath
    $manifest = Read-XqJsonFile -Path $ManifestPath
    if ([string]::IsNullOrWhiteSpace($ReceiptPath)) { $ReceiptPath = Join-Path $CacheDirectory 'download-receipt.json' }
    Invoke-XqValidatedDownload -Manifest $manifest -TrustedSources $trusted -CacheDirectory $CacheDirectory -NetworkInvoker $NetworkInvoker -ReceiptPath $ReceiptPath -MaximumArtifactBytes $MaximumArtifactBytes -TimeoutSeconds $TimeoutSeconds | ConvertTo-Json -Depth 8
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

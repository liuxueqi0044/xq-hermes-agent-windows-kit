[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$TrustedSourcesPath = (Join-Path $PSScriptRoot '..\manifest\trusted-sources.json'),
    [Parameter(Mandatory)][string]$ArtifactPath,
    [Parameter(Mandatory)][string]$SignatureReportPath,
    [scriptblock]$SignatureProvider
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
try {
    Assert-XqPowerShell7
    $trusted = Get-XqTrustedSources -Path $TrustedSourcesPath
    $manifest = Read-XqJsonFile -Path $ManifestPath
    Assert-XqManifest -Manifest $manifest -TrustedSources $trusted -Formal | Out-Null
    $hash = Test-XqArtifactIdentity -ArtifactPath $ArtifactPath -Manifest $manifest
    $report = Get-XqSignatureReport -ArtifactPath $ArtifactPath -SignatureProvider $SignatureProvider
    Assert-XqSignaturePolicy -Report $report -Manifest $manifest | Out-Null
    $report | Add-Member -NotePropertyName sha256 -NotePropertyValue $hash
    Write-XqJsonAtomic -InputObject $report -Path $SignatureReportPath
    $report | ConvertTo-Json -Depth 8
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

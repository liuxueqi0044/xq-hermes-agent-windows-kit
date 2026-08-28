[CmdletBinding()]
param(
    [string]$ReleasePageUrl = 'https://github.com/NousResearch/hermes-agent/releases',
    [string]$DesktopProductPageUrl = 'https://hermes-agent.nousresearch.com/',
    [string]$TrustedSourcesPath = (Join-Path $PSScriptRoot '..\manifest\trusted-sources.json'),
    [string]$ManifestPath,
    [scriptblock]$NetworkInvoker,
    [ValidateRange(1, 10)][int]$MaximumCandidates = 5
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
try {
    Assert-XqPowerShell7
    $trusted = Get-XqTrustedSources -Path $TrustedSourcesPath
    $releasePage = Invoke-XqHttpChain -Uri $ReleasePageUrl -TrustedSources $trusted -Purpose 'source-page' -NetworkInvoker $NetworkInvoker
    $releaseHtml = $releasePage.Response.ContentText
    if ($null -eq $releaseHtml -and $null -ne $releasePage.Response.ContentBytes) { $releaseHtml = [Text.Encoding]::UTF8.GetString([byte[]]$releasePage.Response.ContentBytes) }
    if ([string]::IsNullOrEmpty([string]$releaseHtml)) { throw 'Release discovery page returned no inspectable content.' }
    $productPage = Invoke-XqHttpChain -Uri $DesktopProductPageUrl -TrustedSources $trusted -Purpose 'source-page' -NetworkInvoker $NetworkInvoker
    $productHtml = $productPage.Response.ContentText
    if ($null -eq $productHtml -and $null -ne $productPage.Response.ContentBytes) { $productHtml = [Text.Encoding]::UTF8.GetString([byte[]]$productPage.Response.ContentBytes) }
    if ([string]::IsNullOrEmpty([string]$productHtml)) { throw 'Desktop product page returned no inspectable content.' }
    $tags = @([regex]::Matches([string]$releaseHtml, '/NousResearch/hermes-agent/releases/tag/(v\d{4}\.\d{1,2}\.\d{1,2})(?:["''?#/])') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique -First $MaximumCandidates)
    $assets = @([regex]::Matches([System.Net.WebUtility]::HtmlDecode([string]$productHtml), 'https://hermes-assets\.nousresearch\.com/[^"''\s<>]+') | ForEach-Object { $_.Value.TrimEnd('.',',',';',')') } | Where-Object { $_ -match 'Hermes-Setup\.exe\?build=[a-f0-9]{12,40}$' } | Sort-Object -Unique)
    if ($tags.Count -eq 0 -or $assets.Count -eq 0) { throw 'Discovery is not lockable: no stable release tag or no pinned official Desktop asset was found.' }
    $tagCandidates = foreach ($tag in $tags) {
        $tagPage = Invoke-XqHttpChain -Uri ("https://github.com/NousResearch/hermes-agent/releases/tag/$tag") -TrustedSources $trusted -Purpose 'source-page' -NetworkInvoker $NetworkInvoker
        $tagHtml = $tagPage.Response.ContentText
        if ($null -eq $tagHtml -and $null -ne $tagPage.Response.ContentBytes) { $tagHtml = [Text.Encoding]::UTF8.GetString([byte[]]$tagPage.Response.ContentBytes) }
        $commit = @([regex]::Matches([string]$tagHtml, '(?i)(?:commit/|["'']commit["'']\s*:\s*["''])([a-f0-9]{40})') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Select-Object -Unique)
        $version = @([regex]::Matches([string]$tagHtml, '(?i)Hermes(?:\s+Agent)?\s+v?(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 1)
        $versionValue = if ($version.Count) { $version[0] } else { $null }
        $commitValue = if ($commit.Count -eq 1) { $commit[0] } else { $null }
        [pscustomobject]@{ tag=$tag; hermesVersion=$versionValue; releaseCommit=$commitValue; releasePage=$tagPage.FinalUrl }
    }
    $lockable = @($tagCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_.hermesVersion) -and -not [string]::IsNullOrWhiteSpace($_.releaseCommit) })
    if ($lockable.Count -eq 0) { throw 'Discovery is not lockable: no tag has both a parsed Hermes version and a provable 40-character release commit.' }
    $desktopAssets = foreach ($asset in $assets) { [pscustomobject]@{ url=$asset; buildPrefix=([regex]::Match($asset, 'build=([a-f0-9]{12,40})$').Groups[1].Value); productPage=$productPage.FinalUrl } }
    $result = [pscustomobject]@{ discoveredAtUtc=[DateTimeOffset]::UtcNow.ToString('o'); releasePage=$releasePage.FinalUrl; desktopProductPage=$productPage.FinalUrl; lockableCandidates=$lockable; observedDesktopAssets=@($desktopAssets); note='Discovery output is not a lock. A reviewer must bind the asset build prefix to desktopBuildCommit, set the expected SHA-256, and commit a formal manifest.' }
    if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
        $manifest = Read-XqJsonFile -Path $ManifestPath
        Assert-XqManifest -Manifest $manifest -TrustedSources $trusted -Formal | Out-Null
        Assert-XqDiscoveredManifestBinding -Manifest $manifest -Candidates $lockable -DesktopAssets $desktopAssets | Out-Null
        Test-XqAssetSourceProof -Manifest $manifest -TrustedSources $trusted -NetworkInvoker $NetworkInvoker | Out-Null
        Test-XqLicenseSourceProof -Manifest $manifest -TrustedSources $trusted -NetworkInvoker $NetworkInvoker | Out-Null
        $result | Add-Member -NotePropertyName lockedManifestValidated -NotePropertyValue $true
    }
    $result | ConvertTo-Json -Depth 8
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

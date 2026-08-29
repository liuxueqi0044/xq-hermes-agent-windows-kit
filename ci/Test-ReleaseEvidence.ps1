[CmdletBinding()]
param(
    [string]$EvidenceRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'evidence'),
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'manifest\product-manifest.json'),
    [string]$CandidateArtifactPath = '' ,
    [string]$ReleaseDestinationPath = '',
    [string]$ReleaseManifestPath = '',
    [string]$ReleaseTag = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($CandidateArtifactPath)) { $CandidateArtifactPath = Join-Path $projectRoot 'artifacts' }
if ([string]::IsNullOrWhiteSpace($ReleaseDestinationPath)) { $ReleaseDestinationPath = Join-Path $projectRoot 'artifacts\release-created.marker' }
if ([string]::IsNullOrWhiteSpace($ReleaseManifestPath)) { $ReleaseManifestPath = Join-Path $EvidenceRoot 'release-manifest.json' }
$ReleaseManifestPath = [IO.Path]::GetFullPath($ReleaseManifestPath)
$required = @('formal-manifest.json', 'tool-integrity.json', 'release-manifest.json', 'm1-m7.json', 'm1-m10.json', 'm1-m10-coverage.xml', 'candidate.json', 'signature-report.json', 'license-proof.json', 'm6-source.json', 'm6-staging.json', 'm6-zip.json', 'm6-evidence.json', 'vm-acceptance.md', 'vm-acceptance.json')
foreach ($name in $required) {
    $path = Join-Path $EvidenceRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release evidence is incomplete: missing $name" }
}
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw 'Formal product manifest is missing.' }
if (-not (Test-Path -LiteralPath $CandidateArtifactPath -PathType Leaf)) { throw 'Candidate artifact is missing.' }
if (Test-Path -LiteralPath $ReleaseDestinationPath) { throw 'Release destination already exists; immutable artifacts cannot be overwritten.' }
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
if ([string]$manifest.buildMode -cne 'formal') { throw 'Release requires a formal product manifest.' }
$formalHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$formalEvidence = Join-Path $EvidenceRoot 'formal-manifest.json'
if ((Get-FileHash -LiteralPath $formalEvidence -Algorithm SHA256).Hash.ToLowerInvariant() -cne $formalHash) { throw 'formal-manifest.json is not byte-identical to the current product manifest.' }
$toolLock = Get-Content -LiteralPath (Join-Path $projectRoot 'ci\tool-versions.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
$toolIntegrity = @(Get-Content -LiteralPath (Join-Path $EvidenceRoot 'tool-integrity.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16)
foreach ($toolName in @('Pester', 'PSScriptAnalyzer')) {
    $locked = $toolLock.tools.$toolName
    $installed = @($toolIntegrity | Where-Object { [string]$_.name -ceq $toolName })
    if ($installed.Count -ne 1 -or [string]$installed[0].version -cne [string]$locked.version -or [string]$installed[0].sha256 -cne [string]$locked.packageSha256 -or [int64]$installed[0].bytes -ne [int64]$locked.packageBytes) { throw "Locked tool integrity evidence mismatch: $toolName" }
}
foreach ($summaryName in @('m1-m7.json', 'm1-m10.json')) {
    $summary = Get-Content -LiteralPath (Join-Path $EvidenceRoot $summaryName) -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
    if ([int]$summary.failed -ne 0 -or [int]$summary.notRun -ne 0 -or [int]$summary.skipped -ne 0) { throw "Test evidence reports failures, skipped, or not-run tests: $summaryName" }
}
if ((Get-Item -LiteralPath (Join-Path $EvidenceRoot 'm1-m10-coverage.xml')).Length -lt 1) { throw 'Pester coverage report is missing or empty.' }
$candidate = Get-Content -LiteralPath (Join-Path $EvidenceRoot 'candidate.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
$candidateHash = (Get-FileHash -LiteralPath $CandidateArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ([string]$candidate.status -notin @('verified', 'ready-for-release') -or [string]$candidate.packageSha256 -cne $candidateHash) { throw 'Candidate evidence does not bind the rebuilt artifact SHA-256.' }
$candidateName = [IO.Path]::GetFileName($CandidateArtifactPath)
if ($candidateName -cne "XQ-Hermes-Agent-Windows-v$($manifest.productVersion)-Hermes-$($manifest.hermesVersion).zip") { throw 'Candidate filename is not the deterministic XQ/Hermes package name.' }
Import-Module (Join-Path $projectRoot 'build\Common.psm1') -Force
$signature = Get-Content -LiteralPath (Join-Path $EvidenceRoot 'signature-report.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
if ([string]$signature.sha256 -cne [string]$manifest.officialSha256) { throw 'Signature report hash does not match the formal manifest.' }
Assert-XqSignaturePolicy -Report $signature -Manifest $manifest | Out-Null
$licenseProof = Get-Content -LiteralPath (Join-Path $EvidenceRoot 'license-proof.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
if ([string]$licenseProof.Sha256 -cne [string]$manifest.licenseSha256) { throw 'LICENSE proof hash does not match the formal manifest.' }
foreach ($entry in @(@('m6-source.json', 'Source'), @('m6-staging.json', 'Staging'), @('m6-zip.json', 'Zip'), @('m6-evidence.json', 'Evidence'))) {
    $m6 = Get-Content -LiteralPath (Join-Path $EvidenceRoot $entry[0]) -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
    if ([string]$m6.status -cne 'PASS' -or [string]$m6.targetType -cne $entry[1]) { throw "M6 security evidence failed or has wrong target: $($entry[0])" }
}
$release = Get-Content -LiteralPath $ReleaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
if ([string]$release.releaseStatus -cne 'CANDIDATE' -or [string]$release.productVersion -cne [string]$manifest.productVersion -or [string]$release.hermesVersion -cne [string]$manifest.hermesVersion) { throw 'M10 release manifest is not a candidate bound to the current versions.' }
$declaredReleaseTag = if ($release.PSObject.Properties.Name -contains 'releaseTag') { [string]$release.releaseTag } elseif ($release.PSObject.Properties.Name -contains 'tag') { [string]$release.tag } else { '' }
if ([string]::IsNullOrWhiteSpace($ReleaseTag) -or [string]::IsNullOrWhiteSpace($declaredReleaseTag) -or $declaredReleaseTag -cne $ReleaseTag) { throw 'Dispatch release_tag must exactly match the reviewed M10 release manifest tag.' }
$declaredTagCommit = if ($release.PSObject.Properties.Name -contains 'tagCommitSha') { [string]$release.tagCommitSha } elseif ($release.PSObject.Properties.Name -contains 'commit') { [string]$release.commit } else { '' }
if ($declaredTagCommit -notmatch '^[a-f0-9]{40}$') { throw 'M10 release manifest must bind release_tag to a full commit SHA.' }
$actualTagCommit = ((@(& git rev-parse "refs/tags/$ReleaseTag^{commit}" 2>$null) -join '')).Trim()
if ($LASTEXITCODE -ne 0 -or $actualTagCommit -cne $declaredTagCommit) { throw 'Dispatch release_tag does not resolve to the reviewed immutable tag commit.' }
$checkoutCommit = ((@(& git rev-parse 'HEAD^{commit}' 2>$null) -join '')).Trim()
if ($LASTEXITCODE -ne 0 -or $checkoutCommit -cne $declaredTagCommit) { throw 'Reviewed release tag does not point to the workflow checkout commit.' }
if ([string]$release.artifact.path -ne [string]$candidate.packagePath -or [string]$release.artifact.sha256 -cne $candidateHash -or $release.artifact.immutable -ne $true) { throw 'M10 release manifest artifact binding does not match the rebuilt candidate.' }
$acceptanceJson = Join-Path $EvidenceRoot 'vm-acceptance.json'
$acceptanceHash = (Get-FileHash -LiteralPath $acceptanceJson -Algorithm SHA256).Hash.ToLowerInvariant()
if ([string]$release.acceptanceRecord.sha256 -cne $acceptanceHash -or [string]$release.acceptanceRecord.state -cne 'PASSED') { throw 'M10 release manifest acceptance binding is invalid.' }
& (Join-Path $projectRoot 'acceptance\Validate-VmAcceptance.ps1') -AcceptancePath $acceptanceJson -ManifestPath $ManifestPath | Out-Null
$governanceEvidence = Get-Content -LiteralPath (Join-Path $EvidenceRoot 'governance-gate.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 12
if ([string]$governanceEvidence.Gate -cne 'APPROVED_FOR_DRAFT_RELEASE' -or [string]$governanceEvidence.ReleaseStatus -cne 'CANDIDATE' -or [string]$governanceEvidence.ProductVersion -cne [string]$manifest.productVersion -or [string]$governanceEvidence.HermesVersion -cne [string]$manifest.hermesVersion -or [string]$governanceEvidence.Acceptance -cne 'PASSED') { throw 'Governance gate evidence is not an approved, version-bound draft-release decision.' }
if ((Get-Item -LiteralPath (Join-Path $EvidenceRoot 'vm-acceptance.md')).Length -lt 1) { throw 'vm-acceptance.md is empty.' }
Write-Output ([ordered]@{ valid = $true; gate = 'APPROVED_FOR_DRAFT_RELEASE'; manifest = $ManifestPath; evidenceRoot = $EvidenceRoot; candidate = $CandidateArtifactPath; required = $required } | ConvertTo-Json -Depth 5)

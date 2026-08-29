[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$AcceptancePath,
    [Parameter(Mandatory)][string]$CandidateArtifactPath,
    [Parameter(Mandatory)][string]$ReleaseDestinationPath,
    [Parameter(Mandatory)][string]$ReleaseManifestPath,
    [string]$SupportScopePath = (Join-Path $PSScriptRoot '..\manifest\support-scope.json'),
    [string]$SupportMatrixPath = (Join-Path $PSScriptRoot 'support-matrix.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$reasons = [System.Collections.Generic.List[string]]::new()
function Add-Reason { param([string]$Message) $reasons.Add($Message) }
function Get-Property { param([object]$Object, [string]$Name) if ($null -eq $Object) { return $null }; $property = $Object.PSObject.Properties[$Name]; if ($null -eq $property) { return $null }; return $property.Value }
function Test-SemVer { param([string]$Value) return $Value -match '^\d+\.\d+\.\d+$' }
function Test-Hash { param([string]$Value) return $Value -match '^[a-f0-9]{64}$' }

foreach ($path in @($ManifestPath, $AcceptancePath, $CandidateArtifactPath, $ReleaseManifestPath, $SupportScopePath, $SupportMatrixPath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Add-Reason 'required release input is missing' } }
if (Test-Path -LiteralPath $ReleaseDestinationPath) { Add-Reason 'release destination already exists; old artifacts are immutable and cannot be overwritten' }
$manifest = $null; $acceptance = $null; $release = $null; $scope = $null; $supportMatrix = $null; $matchingRows = @()
if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) { $manifest = try { Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json } catch { $null }; if ($null -eq $manifest) { Add-Reason 'product manifest is not valid JSON' } }
if (Test-Path -LiteralPath $AcceptancePath -PathType Leaf) {
    $acceptanceJsonPath = $AcceptancePath
    if ([IO.Path]::GetExtension($AcceptancePath).ToLowerInvariant() -eq '.md') { $acceptanceJsonPath = [IO.Path]::ChangeExtension($AcceptancePath, '.json') }
    if (Test-Path -LiteralPath $acceptanceJsonPath -PathType Leaf) { $acceptance = try { Get-Content -LiteralPath $acceptanceJsonPath -Raw | ConvertFrom-Json } catch { $null }; if ($null -eq $acceptance) { Add-Reason 'VM acceptance JSON is not valid' } } else { Add-Reason 'Markdown acceptance needs a machine-verifiable JSON sidecar' }
} else { $acceptanceJsonPath = $AcceptancePath }
if (Test-Path -LiteralPath $ReleaseManifestPath -PathType Leaf) { $release = try { Get-Content -LiteralPath $ReleaseManifestPath -Raw | ConvertFrom-Json } catch { $null }; if ($null -eq $release) { Add-Reason 'M10 release manifest is not valid JSON' } }
if (Test-Path -LiteralPath $SupportScopePath -PathType Leaf) { $scope = try { Get-Content -LiteralPath $SupportScopePath -Raw | ConvertFrom-Json } catch { $null } }
if (Test-Path -LiteralPath $SupportMatrixPath -PathType Leaf) { $supportMatrix = try { Get-Content -LiteralPath $SupportMatrixPath -Raw | ConvertFrom-Json } catch { $null }; if ($null -eq $supportMatrix) { Add-Reason 'support matrix is not valid JSON' } }
if ($null -ne $supportMatrix -and ((Get-Property $supportMatrix 'productVersion') -ne [string](Get-Property $manifest 'productVersion') -or @(Get-Property $supportMatrix 'supportedOs') -notcontains 'Windows 11 x64')) { Add-Reason 'support matrix does not match product version or supported OS' }
if ($null -ne $supportMatrix) {
    if ($supportMatrix.PSObject.Properties.Name -notcontains 'entries') { Add-Reason 'support matrix entries are missing' }
    else {
        $matchingRows = @($supportMatrix.entries | Where-Object { [string](Get-Property $_ 'hermesVersion') -eq [string](Get-Property $manifest 'hermesVersion') -and [string](Get-Property $_ 'status') -eq 'VALIDATED' })
        if ($matchingRows.Count -ne 1) { Add-Reason 'support matrix must have exactly one VALIDATED row for this Hermes version' }
    }
}

if ($null -ne $manifest) {
    if ((Get-Property $manifest 'buildMode') -ne 'formal') { Add-Reason 'product manifest is not a formal build' }
    try {
        Import-Module (Join-Path $PSScriptRoot '..\build\Common.psm1') -Force
        $trusted = Get-XqTrustedSources -Path (Join-Path $PSScriptRoot '..\manifest\trusted-sources.json')
        $formalCheck = Test-XqManifest -Manifest $manifest -TrustedSources $trusted -Formal
        if (-not $formalCheck.IsValid) { Add-Reason 'product manifest formal validation failed' }
    } catch { Add-Reason 'product manifest formal validation could not run' }
}
if ($null -ne $acceptance) {
    if ((Get-Property $acceptance 'state') -ne 'PASSED') { Add-Reason 'VM acceptance state must be PASSED' }
    try { & (Join-Path $PSScriptRoot '..\acceptance\Validate-VmAcceptance.ps1') -AcceptancePath $acceptanceJsonPath -ManifestPath $ManifestPath | Out-Null } catch { Add-Reason 'VM acceptance failed validation' }
    if ($matchingRows.Count -eq 1) {
        $matrixRow = $matchingRows[0]
        $expectedRuntimeCommit = [string](Get-Property (Get-Property $manifest 'runtimeInstallPin') 'value')
        if ([string](Get-Property $matrixRow 'runtimeCommit') -ne [string](Get-Property (Get-Property $acceptance 'runtime') 'commit') -or
            [string](Get-Property $matrixRow 'runtimeCommit') -ne $expectedRuntimeCommit) {
            Add-Reason 'support matrix runtime commit does not bind the acceptance record and formal manifest'
        }
        if ([IO.Path]::GetFileName([string](Get-Property $matrixRow 'acceptanceRecord')) -ne [IO.Path]::GetFileName($acceptanceJsonPath)) {
            Add-Reason 'support matrix acceptanceRecord does not bind the authoritative VM record'
        }
    }
}
if ($null -ne $release) {
    $required = 'schemaVersion','releaseId','releaseTag','tagCommitSha','productVersion','hermesVersion','semver','supportMatrix','supportScopeSha256','acceptanceRecord','artifact','releaseStatus','knownIssues','unsupported','oldArtifactPolicy'
    foreach ($name in $required) { if ($null -eq (Get-Property $release $name)) { Add-Reason "M10 release manifest missing $name" } }
    if ([string](Get-Property $release 'releaseId') -notmatch '^XQ-\d+\.\d+\.\d+-Hermes-.+$') { Add-Reason 'M10 releaseId is invalid' }
    $expectedReleaseTag = "xq-v$([string](Get-Property $release 'productVersion'))-hermes-$([string](Get-Property $release 'hermesVersion'))"
    if ([string](Get-Property $release 'releaseTag') -notmatch '^xq-v\d+\.\d+\.\d+-hermes-[0-9A-Za-z._-]+$' -or [string](Get-Property $release 'releaseTag') -ne $expectedReleaseTag) { Add-Reason 'M10 releaseTag does not map product and Hermes versions' }
    if ([string](Get-Property $release 'tagCommitSha') -notmatch '^[a-f0-9]{40}$' -or [string](Get-Property $release 'tagCommitSha') -match '^0{40}$') { Add-Reason 'M10 tagCommitSha must be a nonzero full lowercase commit SHA' }
    $releaseStatus = [string](Get-Property $release 'releaseStatus')
    if ($releaseStatus -ne 'CANDIDATE') { Add-Reason 'M10 release manifest status must be CANDIDATE before human release action' }
    $releaseProductVersion = [string](Get-Property $release 'productVersion')
    if (-not (Test-SemVer $releaseProductVersion)) { Add-Reason 'M10 productVersion is not SemVer' }
    $semver = Get-Property $release 'semver'
    $major = Get-Property $semver 'major'; $minor = Get-Property $semver 'minor'; $patch = Get-Property $semver 'patch'
    if ($null -eq $semver -or $major -isnot [int] -or $minor -isnot [int] -or $patch -isnot [int] -or $major -lt 0 -or $minor -lt 0 -or $patch -lt 0 -or "$major.$minor.$patch" -ne $releaseProductVersion) { Add-Reason 'M10 semver object does not match productVersion' }
    $acceptanceBinding = Get-Property $release 'acceptanceRecord'; $artifactBinding = Get-Property $release 'artifact'
    if ((Get-Property $acceptanceBinding 'state') -ne 'PASSED') { Add-Reason 'M10 acceptanceRecord.state must be PASSED' }
    if ((Get-Property $artifactBinding 'immutable') -ne $true) { Add-Reason 'M10 artifact.immutable must be true' }
    $releaseMatrix = Get-Property $release 'supportMatrix'
    if ((Get-Property $releaseMatrix 'status') -ne 'VALIDATED' -or [string](Get-Property $releaseMatrix 'hermesVersion') -ne [string](Get-Property $release 'hermesVersion') -or @(Get-Property $releaseMatrix 'supportedOs') -notcontains 'Windows 11 x64') { Add-Reason 'M10 supportMatrix is not validated or does not match Hermes/OS' }
    $knownIssues = Get-Property $release 'knownIssues'; $unsupported = Get-Property $release 'unsupported'
    if ($knownIssues -isnot [array] -or @($knownIssues).Count -eq 0 -or $unsupported -isnot [array] -or @($unsupported).Count -eq 0) { Add-Reason 'M10 knownIssues and unsupported are required arrays' }
    if ($null -ne $manifest -and ($releaseProductVersion -ne [string](Get-Property $manifest 'productVersion') -or [string](Get-Property $release 'hermesVersion') -ne [string](Get-Property $manifest 'hermesVersion'))) { Add-Reason 'M10 versions do not match product manifest' }
    if (Test-Path -LiteralPath $SupportScopePath -PathType Leaf) {
        $scopeHash = (Get-FileHash -LiteralPath $SupportScopePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not (Test-Hash ([string](Get-Property $release 'supportScopeSha256'))) -or [string](Get-Property $release 'supportScopeSha256') -ne $scopeHash) { Add-Reason 'M10 support scope hash mismatch' }
        if ($null -eq $scope -or $scope.PSObject.Properties.Name -notcontains 'firstReleaseExclusions') { Add-Reason 'support scope is not valid JSON' }
        $requiredExclusions = if ($null -ne $scope) { @($scope.firstReleaseExclusions | ForEach-Object { [string]$_ } | Select-Object -Unique) } else { @() }
        $unsupported = @((Get-Property $release 'unsupported') | ForEach-Object { [string]$_ })
        foreach ($excluded in $requiredExclusions) { if ($unsupported -cnotcontains $excluded) { Add-Reason "M10 unsupported scope omits $excluded" } }
    }
    if (Test-Path -LiteralPath $acceptanceJsonPath -PathType Leaf) {
        $acceptanceHash = (Get-FileHash -LiteralPath $acceptanceJsonPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([string](Get-Property $acceptanceBinding 'sha256') -ne $acceptanceHash) { Add-Reason 'M10 acceptance hash mismatch' }
    }
    $boundAcceptancePath = [string](Get-Property $acceptanceBinding 'path')
    if ([string]::IsNullOrWhiteSpace($boundAcceptancePath) -or [IO.Path]::GetFileName($boundAcceptancePath) -ne [IO.Path]::GetFileName($acceptanceJsonPath)) { Add-Reason 'M10 acceptanceRecord.path does not bind the authoritative JSON sidecar' }
    if ([IO.Path]::IsPathRooted($boundAcceptancePath)) { Add-Reason 'M10 acceptanceRecord.path must be a relative evidence path' }
    if (Test-Path -LiteralPath $CandidateArtifactPath -PathType Leaf) {
        $candidateHash = (Get-FileHash -LiteralPath $CandidateArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([string](Get-Property $artifactBinding 'sha256') -ne $candidateHash) { Add-Reason 'M10 candidate artifact hash mismatch' }
    }
    if ([IO.Path]::GetFileName([string](Get-Property $artifactBinding 'path')) -ne [IO.Path]::GetFileName($CandidateArtifactPath)) { Add-Reason 'M10 artifact.path does not bind CandidateArtifactPath' }
    if ([IO.Path]::IsPathRooted([string](Get-Property $artifactBinding 'path'))) { Add-Reason 'M10 artifact.path must be a relative artifact path' }
}
try { & (Join-Path $PSScriptRoot 'Compare-SupportScope.ps1') -SupportScopePath $SupportScopePath | Out-Null } catch { Add-Reason 'support scope/document comparison failed' }
try { & (Join-Path $PSScriptRoot 'Scan-CommercialClaims.ps1') -Path (Join-Path $PSScriptRoot '..\content\support') | Out-Null } catch { Add-Reason 'commercial claim scan failed' }
if ($reasons.Count -gt 0) { throw ('RELEASE BLOCKED: ' + ($reasons -join '; ')) }
[pscustomobject]@{ Gate = 'APPROVED_FOR_DRAFT_RELEASE'; ReleaseStatus = 'CANDIDATE'; ProductVersion = [string](Get-Property $manifest 'productVersion'); HermesVersion = [string](Get-Property $manifest 'hermesVersion'); Acceptance = 'PASSED'; Summary = 'Machine-checkable gates passed; a human release owner must perform the final release action.' }

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseManifestPath,
    [Parameter(Mandatory)][string]$ProductManifestPath,
    [Parameter(Mandatory)][string]$AcceptancePath,
    [Parameter(Mandatory)][string]$SupportScopePath,
    [Parameter(Mandatory)][string]$CandidateArtifactPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-Property { param([object]$Object, [string]$Name) if ($null -eq $Object) { return $null }; $property = $Object.PSObject.Properties[$Name]; if ($null -eq $property) { return $null }; return $property.Value }
foreach ($path in @($ReleaseManifestPath, $ProductManifestPath, $AcceptancePath, $SupportScopePath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'M10 release evidence file is missing.' } }
$raw = Get-Content -LiteralPath $ReleaseManifestPath -Raw
if ($raw -match '(?i)NOT[_ -]?VALID|REPLACE-ME') { throw 'M10 release manifest is a template.' }
$release = try { $raw | ConvertFrom-Json } catch { throw 'M10 release manifest is not valid JSON.' }
$product = try { Get-Content -LiteralPath $ProductManifestPath -Raw | ConvertFrom-Json } catch { throw 'Product manifest is not valid JSON.' }
$acceptance = try { Get-Content -LiteralPath $AcceptancePath -Raw | ConvertFrom-Json } catch { throw 'VM acceptance JSON is not valid.' }
$errors = [System.Collections.Generic.List[string]]::new()
$required = 'schemaVersion','releaseId','releaseTag','tagCommitSha','productVersion','hermesVersion','semver','supportMatrix','supportScopeSha256','acceptanceRecord','artifact','releaseStatus','knownIssues','unsupported','oldArtifactPolicy'
foreach ($name in $required) { if ($null -eq (Get-Property $release $name)) { $errors.Add("Required release field is missing: $name.") } }
if ((Get-Property $release 'schemaVersion') -ne '1.0') { $errors.Add('schemaVersion must be 1.0.') }
if ((Get-Property $release 'releaseStatus') -ne 'CANDIDATE') { $errors.Add('releaseStatus must be CANDIDATE before human release action.') }
if ([string](Get-Property $release 'releaseId') -notmatch '^XQ-\d+\.\d+\.\d+-Hermes-.+$') { $errors.Add('releaseId is invalid.') }
if ((Get-Property $release 'productVersion') -ne (Get-Property $product 'productVersion') -or (Get-Property $release 'hermesVersion') -ne (Get-Property $product 'hermesVersion')) { $errors.Add('Release and product manifest versions differ.') }
$expectedReleaseTag = "xq-v$([string](Get-Property $release 'productVersion'))-hermes-$([string](Get-Property $release 'hermesVersion'))"
if ([string](Get-Property $release 'releaseTag') -notmatch '^xq-v\d+\.\d+\.\d+-hermes-[0-9A-Za-z._-]+$' -or [string](Get-Property $release 'releaseTag') -ne $expectedReleaseTag) { $errors.Add('releaseTag does not map product and Hermes versions.') }
if ([string](Get-Property $release 'tagCommitSha') -notmatch '^[a-f0-9]{40}$' -or [string](Get-Property $release 'tagCommitSha') -match '^0{40}$') { $errors.Add('tagCommitSha must be a nonzero full lowercase commit SHA.') }
$semver = Get-Property $release 'semver'; $major = Get-Property $semver 'major'; $minor = Get-Property $semver 'minor'; $patch = Get-Property $semver 'patch'
if ($major -isnot [int] -or $minor -isnot [int] -or $patch -isnot [int] -or $major -lt 0 -or $minor -lt 0 -or $patch -lt 0 -or "$major.$minor.$patch" -ne [string](Get-Property $release 'productVersion')) { $errors.Add('semver does not match productVersion.') }
$acceptanceBinding = Get-Property $release 'acceptanceRecord'
$artifactBinding = Get-Property $release 'artifact'
if ((Get-Property $acceptanceBinding 'state') -ne 'PASSED' -or (Get-Property $acceptance 'state') -ne 'PASSED') { $errors.Add('Acceptance binding and record must both be PASSED.') }
if ((Get-Property $artifactBinding 'immutable') -ne $true) { $errors.Add('Artifact must be marked immutable.') }
$matrix = Get-Property $release 'supportMatrix'
if ((Get-Property $matrix 'status') -ne 'VALIDATED' -or [string](Get-Property $matrix 'hermesVersion') -ne [string](Get-Property $release 'hermesVersion') -or @(Get-Property $matrix 'supportedOs') -notcontains 'Windows 11 x64') { $errors.Add('supportMatrix must be VALIDATED for the matching Hermes version and OS.') }
if ((Get-Property $release 'knownIssues') -isnot [array] -or @(Get-Property $release 'knownIssues').Count -eq 0) { $errors.Add('knownIssues must be a non-empty array.') }
if ((Get-Property $release 'unsupported') -isnot [array] -or @(Get-Property $release 'unsupported').Count -eq 0) { $errors.Add('unsupported scope must be a non-empty array.') }
if ([string]::IsNullOrWhiteSpace([string](Get-Property $release 'oldArtifactPolicy'))) { $errors.Add('oldArtifactPolicy must be present.') }
$scopeHash = (Get-FileHash -LiteralPath $SupportScopePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ((Get-Property $release 'supportScopeSha256') -ne $scopeHash) { $errors.Add('supportScopeSha256 mismatch.') }
$scope = Get-Content -LiteralPath $SupportScopePath -Raw | ConvertFrom-Json
foreach ($excluded in @($scope.firstReleaseExclusions)) { if (@(Get-Property $release 'unsupported') -cnotcontains [string]$excluded) { $errors.Add("unsupported scope omits $excluded.") } }
$acceptanceHash = (Get-FileHash -LiteralPath $AcceptancePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ((Get-Property $acceptanceBinding 'sha256') -ne $acceptanceHash) { $errors.Add('acceptanceRecord.sha256 mismatch.') }
$acceptanceBindingPath = [string](Get-Property $acceptanceBinding 'path')
if ([IO.Path]::IsPathRooted($acceptanceBindingPath) -or $acceptanceBindingPath -split '[\\/]' -contains '..' -or [IO.Path]::GetFileName($acceptanceBindingPath) -ne [IO.Path]::GetFileName($AcceptancePath)) { $errors.Add('acceptanceRecord.path must be a safe relative path bound to the acceptance JSON.') }
if (-not (Test-Path -LiteralPath $CandidateArtifactPath -PathType Leaf)) { $errors.Add('Candidate artifact is missing.') }
else { $artifactHash = (Get-FileHash -LiteralPath $CandidateArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant(); if ((Get-Property $artifactBinding 'sha256') -ne $artifactHash) { $errors.Add('artifact.sha256 mismatch.') } }
$artifactBindingPath = [string](Get-Property $artifactBinding 'path')
if ([IO.Path]::IsPathRooted($artifactBindingPath) -or $artifactBindingPath -split '[\\/]' -contains '..' -or [IO.Path]::GetFileName($artifactBindingPath) -ne [IO.Path]::GetFileName($CandidateArtifactPath)) { $errors.Add('artifact.path must be a safe relative path bound to the candidate artifact.') }
try { & (Join-Path $PSScriptRoot '..\acceptance\Validate-VmAcceptance.ps1') -AcceptancePath $AcceptancePath -ManifestPath $ProductManifestPath | Out-Null } catch { $errors.Add('Authoritative VM acceptance validation failed.') }
if ($errors.Count -gt 0) { throw ('M10 release manifest rejected: ' + ($errors -join '; ')) }
[pscustomobject]@{ Valid = $true; Status = 'CANDIDATE'; ProductVersion = [string](Get-Property $release 'productVersion'); HermesVersion = [string](Get-Property $release 'hermesVersion'); Summary = 'M10 release manifest bindings are consistent.' }

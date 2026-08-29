[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$SupportScopePath = (Join-Path $PSScriptRoot '..\manifest\support-scope.json'),
    [Parameter(Mandatory = $false)][string]$SelfServicePath = (Join-Path $PSScriptRoot '..\content\support\self-service.md'),
    [Parameter(Mandatory = $false)][string]$RemoteServicePath = (Join-Path $PSScriptRoot '..\content\support\remote-install.md'),
    [Parameter(Mandatory = $false)][string]$ProblemTemplatePath = (Join-Path $PSScriptRoot '..\content\support\before-support.md')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scope = Get-Content -LiteralPath $SupportScopePath -Raw | ConvertFrom-Json
$failures = [System.Collections.Generic.List[string]]::new()
$self = Get-Content -LiteralPath $SelfServicePath -Raw
$remote = Get-Content -LiteralPath $RemoteServicePath -Raw
$selfTier = $scope.tiers.selfService
$remoteTier = $scope.tiers.remoteBasicInstall
$selfStandard = @($selfTier.completionStandard)
$remoteStandard = @($remoteTier.completionStandard)
if (@(Compare-Object -ReferenceObject $selfStandard -DifferenceObject $remoteStandard).Count -gt 0) { $failures.Add('support-scope completion standards conflict.') }
if ([string]::IsNullOrWhiteSpace([string]$selfTier.assistanceMode) -or [string]::IsNullOrWhiteSpace([string]$remoteTier.assistanceMode) -or $selfTier.assistanceMode -eq $remoteTier.assistanceMode) { $failures.Add('Tier differences must be explicit assistanceMode differences.') }
if ($self -notmatch '(?im)^\s*#{1,6}\s*(完成标准|completion standard)' -or $remote -notmatch '(?im)^\s*#{1,6}\s*(完成标准|completion standard)') { $failures.Add('Both self-service and remote-service documents must publish a completion-standard section.') }
foreach ($tier in @(@{ Name = 'selfService'; Text = $self; Data = $selfTier }, @{ Name = 'remoteBasicInstall'; Text = $remote; Data = $remoteTier })) {
    $markers = $tier.Data.documentMarkers
    foreach ($markerType in @('included', 'excluded', 'completionStandard')) {
        foreach ($marker in @($markers.$markerType)) { if ($tier.Text -notmatch [regex]::Escape([string]$marker)) { $failures.Add("$($tier.Name) document omits $markerType marker.") } }
    }
}
foreach ($term in @('Gateway', 'Cron', 'Computer Use')) {
    foreach ($document in @($self, $remote)) {
        foreach ($line in ($document -split "`r?`n")) {
            if ($line -match [regex]::Escape($term) -and $line -notmatch '(?i)(不包含|不支持|excluded|outside|not included)') { $failures.Add("Document enables a first-release exclusion: $term.") }
        }
    }
}
if (Test-Path -LiteralPath $ProblemTemplatePath -PathType Leaf) {
    $problem = Get-Content -LiteralPath $ProblemTemplatePath -Raw
    if ($problem -notmatch '(?i)(api key|token|密码|password)' -or $problem -notmatch '(?i)(邮箱|email|余额|balance|cookie|会话)') { $failures.Add('Problem template must require redaction and reject complete credentials or sensitive screenshots.') }
}
if ($failures.Count -gt 0) { throw ('SUPPORT SCOPE CHECK FAILED: ' + ($failures -join '; ')) }
[pscustomobject]@{ Passed = $true; SelfService = [IO.Path]::GetFileName($SelfServicePath); RemoteService = [IO.Path]::GetFileName($RemoteServicePath); CompletionStandardsMatch = $true }

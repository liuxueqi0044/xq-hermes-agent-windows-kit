[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AcceptancePath,
    [string]$ManifestPath,
    [datetime]$CurrentUtc = [datetime]::UtcNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-Failure {
    param([System.Collections.Generic.List[string]]$List, [string]$Message)
    $List.Add($Message)
}

if (-not (Test-Path -LiteralPath $AcceptancePath -PathType Leaf)) { throw "Acceptance record not found: $AcceptancePath" }
$raw = Get-Content -LiteralPath $AcceptancePath -Raw
$record = try { $raw | ConvertFrom-Json -DateKind String } catch { throw 'Acceptance record is not valid JSON.' }
$failures = [System.Collections.Generic.List[string]]::new()

if ($raw -match '(?i)NOT[_ -]?VALID[_ -]?EVIDENCE|REPLACE-ME|TODO|PENDING') { Add-Failure $failures 'Record is a template, contains placeholders, or pending evidence.' }
if ($record.schemaVersion -ne '1.0') { Add-Failure $failures 'Unsupported acceptance schemaVersion.' }
if ($record.state -notin @('DRAFT', 'IN_PROGRESS', 'PASSED', 'FAILED')) { Add-Failure $failures 'Invalid acceptance state.' }
if ($record.state -in @('IN_PROGRESS', 'FAILED', 'PASSED') -and $record.PSObject.Properties.Name -notcontains 'previousState') { Add-Failure $failures "$($record.state) requires a previousState." }
if ($record.PSObject.Properties.Name -contains 'previousState') {
    $allowedTransitions = @{
        DRAFT = @('IN_PROGRESS')
        IN_PROGRESS = @('PASSED', 'FAILED')
        FAILED = @('IN_PROGRESS')
        PASSED = @()
    }
    if ($record.previousState -notin $allowedTransitions.Keys -or $record.state -notin $allowedTransitions[[string]$record.previousState]) { Add-Failure $failures 'Invalid acceptance state transition.' }
}

$steps = @($record.steps)
if ($steps.Count -eq 0) { Add-Failure $failures 'Required steps are missing.' }
$requiredStepIds = @('offline-content', 'source-hash-signature', 'install-first-run', 'runtime-pin', 'user-model-config', 'ordinary-chat', 'version-doctor', 'diagnostic-redaction', 'reboot-reopen', 'reinstall-update-data', 'uninstall-behavior', 'system-baseline-diff', 'credential-revoke-vm-rollback')
foreach ($step in $steps) {
    if ([string]::IsNullOrWhiteSpace([string]$step.id) -or [string]::IsNullOrWhiteSpace([string]$step.evidenceRef)) { Add-Failure $failures 'A step is missing id or evidenceRef.' }
    if ($step.result -notin @('PASS', 'FAIL', 'PENDING', 'N/A')) { Add-Failure $failures 'A step has an invalid result.' }
}

foreach ($locale in @('zh-CN', 'en-US')) {
    $vm = @($record.vmMatrix | Where-Object { $_.locale -eq $locale })
    if ($vm.Count -ne 1) { Add-Failure $failures "VM matrix must contain exactly one $locale Windows 11 x64 entry."; continue }
    if ($vm[0].os -ne 'Windows 11' -or $vm[0].architecture -ne 'x64' -or $vm[0].result -ne 'PASS') { Add-Failure $failures "$locale VM is not a passed Windows 11 x64 result." }
    if ($record.state -eq 'PASSED' -and ([string]::IsNullOrWhiteSpace([string]$vm[0].machineEvidenceId) -or [string]::IsNullOrWhiteSpace([string]$vm[0].baselineEvidenceRef))) { Add-Failure $failures "$locale VM is missing machine or baseline evidence reference." }
}

if ($record.state -eq 'PASSED') {
    $zhVmMatches = @($record.vmMatrix | Where-Object { $_.locale -eq 'zh-CN' })
    $enVmMatches = @($record.vmMatrix | Where-Object { $_.locale -eq 'en-US' })
    if ($zhVmMatches.Count -eq 1 -and $enVmMatches.Count -eq 1) {
        if ([string]$zhVmMatches[0].machineEvidenceId -ceq [string]$enVmMatches[0].machineEvidenceId -or
            [string]$zhVmMatches[0].baselineEvidenceRef -ceq [string]$enVmMatches[0].baselineEvidenceRef) {
            Add-Failure $failures 'Chinese and English VM runs require independent machine and baseline evidence.'
        }
    }
    $stepIds = @($steps | ForEach-Object { [string]$_.id })
    foreach ($requiredId in $requiredStepIds) { if (@($stepIds | Where-Object { $_ -ceq $requiredId }).Count -ne 1) { Add-Failure $failures "PASSED requires exactly one step: $requiredId." } }
    if (@($stepIds | Where-Object { $requiredStepIds -notcontains $_ }).Count -gt 0) { Add-Failure $failures 'PASSED contains an unknown step id.' }
    if (@($steps | Where-Object { $_.result -ne 'PASS' }).Count -gt 0) { Add-Failure $failures 'PASSED requires every listed required step to be PASS.' }
    if (@($steps | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.evidenceRef) -or [string]$_.evidenceRef -match '(?i)replace|placeholder|todo' }).Count -gt 0) { Add-Failure $failures 'PASSED requires non-placeholder evidenceRef values for every step.' }
    if ($record.runtime.consistent -ne $true) { Add-Failure $failures 'Runtime consistency attestation is not true.' }
    if ($record.runtime.commit -ne $record.runtime.manifestCommit) { Add-Failure $failures 'Runtime commit does not match manifest commit.' }
    if ($record.runtime.version -ne $record.hermesVersion) { Add-Failure $failures 'Runtime version does not match acceptance Hermes version.' }
    if (@($record.evidence.screenshotIndex).Count -eq 0 -or $record.evidence.screenshotsRedacted -ne $true) { Add-Failure $failures 'A non-empty, explicitly redacted screenshot index is required.' }
    if ($record.credentialRevocation.completed -ne $true -or [string]::IsNullOrWhiteSpace([string]$record.credentialRevocation.declaration)) { Add-Failure $failures 'Credential revocation declaration is incomplete.' }
    if ($record.vmRollback.completed -ne $true -or [string]::IsNullOrWhiteSpace([string]$record.vmRollback.declaration)) { Add-Failure $failures 'VM rollback declaration is incomplete.' }
    if ([string]::IsNullOrWhiteSpace([string]$record.signoff.name) -or [string]::IsNullOrWhiteSpace([string]$record.signoff.signature)) { Add-Failure $failures 'Human acceptance signature is incomplete.' }
    $signedAt = $null
    try { $signedAt = [DateTimeOffset]::Parse([string]$record.signoff.signedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    catch { Add-Failure $failures 'signoff.signedAtUtc is not a valid UTC timestamp.' }
    if ($null -ne $signedAt -and $signedAt.ToUniversalTime() -gt $CurrentUtc.ToUniversalTime()) { Add-Failure $failures 'Acceptance signature is in the future.' }
    if ([string]$record.signoff.signedAtUtc -notmatch 'Z$' -or ($null -ne $signedAt -and $signedAt.Offset -ne [TimeSpan]::Zero)) { Add-Failure $failures 'signoff.signedAtUtc must be UTC with a Z suffix.' }
    $executionPresent = $record.PSObject.Properties.Name -contains 'execution'
    if (-not $executionPresent -or $record.execution.humanVerified -ne $true -or [string]::IsNullOrWhiteSpace([string]$record.execution.vmEvidenceId) -or $record.execution.isDevelopmentMachine -eq $true) { Add-Failure $failures 'PASSED requires human evidence from a real VM; a development machine cannot pass.' }
}

if ($record.PSObject.Properties.Name -contains 'expiresAtUtc' -and -not [string]::IsNullOrWhiteSpace([string]$record.expiresAtUtc)) {
    $expires = $null
    try { $expires = [DateTimeOffset]::Parse([string]$record.expiresAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    catch { Add-Failure $failures 'expiresAtUtc is not a valid UTC timestamp.' }
    if ($null -ne $expires -and $expires.ToUniversalTime() -lt $CurrentUtc.ToUniversalTime()) { Add-Failure $failures 'Acceptance evidence is expired.' }
}
if ($ManifestPath) {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { Add-Failure $failures 'Manifest file is missing.' }
    else {
        $actualHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($record.manifestSha256 -ne $actualHash) { Add-Failure $failures 'Acceptance manifestSha256 does not match manifest.' }
        try {
            $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -DateKind String
            $pinProperty = $manifest.PSObject.Properties['runtimeInstallPin']
            if ($null -ne $pinProperty -and $null -ne $manifest.runtimeInstallPin.value -and $record.runtime.commit -ne $manifest.runtimeInstallPin.value) { Add-Failure $failures 'Runtime commit does not match manifest runtimeInstallPin.' }
            if ($null -ne $manifest.PSObject.Properties['hermesVersion'] -and $record.hermesVersion -ne $manifest.hermesVersion) { Add-Failure $failures 'Acceptance Hermes version does not match manifest.' }
            if ($null -ne $manifest.PSObject.Properties['productVersion'] -and $record.productVersion -ne $manifest.productVersion) { Add-Failure $failures 'Acceptance product version does not match manifest.' }
        } catch { Add-Failure $failures 'Manifest binding could not be inspected.' }
    }
}

$valid = $failures.Count -eq 0
$summary = [pscustomobject]@{ Valid = $valid; State = [string]$record.state; FailureCount = $failures.Count; Failures = @($failures); RecordId = [string]$record.recordId }
if (-not $valid) { throw ('VM acceptance rejected: ' + (($failures | Select-Object -First 8) -join '; ')) }
$summary

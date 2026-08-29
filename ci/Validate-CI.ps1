[CmdletBinding()]
param(
    [string[]]$WorkflowPath = @((Join-Path $PSScriptRoot '..\.github\workflows\validate.yml'), (Join-Path $PSScriptRoot '..\.github\workflows\build-package.yml')),
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-CiCheck {
    param([string]$Workflow, [string]$Rule, [bool]$Passed, [string]$Detail)
    [pscustomobject]@{ workflow = $Workflow; rule = $Rule; passed = $Passed; detail = $Detail }
}

function Get-CiValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-CiWorkflowPolicy {
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @(ConvertTo-CiCheck -Workflow $Path -Rule 'file-exists' -Passed $false -Detail 'Workflow file does not exist.')
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $name = [IO.Path]::GetFileName($Path)
    $checks = [Collections.Generic.List[object]]::new()
    $uses = @([regex]::Matches($raw, '(?im)^[ 	]*uses:[ 	]*([^ 	#]+)') | ForEach-Object { $_.Groups[1].Value })
    $floating = @($uses | Where-Object { $_ -notmatch '@[0-9a-fA-F]{40}$' })
    $checks.Add((ConvertTo-CiCheck $name 'third-party-actions-use-full-commit-sha' ($floating.Count -eq 0) $(if ($floating.Count) { 'Floating action reference detected.' } else { 'All action refs are full commit SHAs.' })))
    $checks.Add((ConvertTo-CiCheck $name 'no-pull-request-target' (-not ($raw -match '(?im)pull_request_target\s*:')) 'pull_request_target is not permitted.'))
    $broadPermissions = $raw -match '(?im)permissions\s*:\s*(?:write-all|read-all|{})'
    $contentWriteCount = @([regex]::Matches($raw, '(?im)^\s+contents\s*:\s*write\s*$')).Count
    if ($name -ieq 'build-package.yml') {
        # A single release job may opt into contents: write; the default must stay read.
        $broadPermissions = $broadPermissions -or $contentWriteCount -ne 1 -or (-not ($raw -match '(?ms)release:\s*\r?\n.*?permissions:\s*\r?\n\s+contents:\s*write'))
    } else {
        $broadPermissions = $broadPermissions -or $contentWriteCount -gt 0
    }
    $checks.Add((ConvertTo-CiCheck $name 'least-privilege-permissions' (-not $broadPermissions) 'Default permissions are read-only; only the release job may write contents.'))
    $secretLeak = $raw -match '(?i)\$\{\{\s*secrets\.|Get-ChildItem\s+Env:|gci\s+Env:|set\s+|printenv|env\s*$'
    $checks.Add((ConvertTo-CiCheck $name 'no-secret-or-environment-dump' (-not $secretLeak) 'Secrets, environment dumps, and private denylist output are prohibited.'))
    if ($name -ieq 'validate.yml') {
        $checks.Add((ConvertTo-CiCheck $name 'validate-triggers' (($raw -match '(?im)^\s*pull_request\s*:') -and ($raw -match '(?im)^\s*push\s*:')) 'PR and push triggers are required.'))
        $checks.Add((ConvertTo-CiCheck $name 'validate-is-offline' (-not ($raw -match '(?i)Fetch-OfficialRelease|Resolve-OfficialRelease|Hermes-Setup\.exe.*(?:Invoke-WebRequest|curl|wget)')) 'Validation must not acquire the formal installer.'))
        $checks.Add((ConvertTo-CiCheck $name 'validate-runs-locked-tools' (($raw -match 'Install-LockedTools\.ps1') -and ($raw -match 'tool-versions\.json')) 'Locked tool installer and tool lock are invoked.'))
    }
    if ($name -ieq 'build-package.yml') {
        $required = @('workflow_dispatch', 'formal-manifest.json', 'tool-integrity.json', 'release-manifest.json', 'm1-m7.json', 'm1-m10.json', 'm1-m10-coverage.xml', 'candidate.json', 'signature-report.json', 'm6-source.json', 'm6-staging.json', 'm6-zip.json', 'm6-evidence.json', 'governance-gate.json', 'vm-acceptance.md', 'vm-acceptance.json')
        foreach ($needle in $required) { $checks.Add((ConvertTo-CiCheck $name "release-gate-$needle" ($raw.Contains($needle)) "Release gate references $needle.")) }
        $checks.Add((ConvertTo-CiCheck $name 'dispatch-only' (($raw -match '(?im)^\s*workflow_dispatch\s*:') -and (-not ($raw -match '(?im)^\s*pull_request\s*:'))) 'Formal package workflow is manually dispatched.'))
        $checks.Add((ConvertTo-CiCheck $name 'protected-release-environment' (($raw -match '(?im)environment:\s*release-approval') -and ($raw -match '(?im)approval')) 'Release job is tied to the protected approval environment.'))
        $checks.Add((ConvertTo-CiCheck $name 'draft-release-only' (($raw -match '(?i)gh\s+release\s+create') -and ($raw -match '(?i)--draft')) 'Release creation is draft-only and does not publish automatically.'))
    }
    return $checks.ToArray()
}

function Test-CiToolVersionLock {
    [OutputType([object[]])]
    param([string]$Path = (Join-Path $PSScriptRoot 'tool-versions.json'))
    $checks = [Collections.Generic.List[object]]::new()
    try { $lock = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16 }
    catch { return @(ConvertTo-CiCheck 'tool-versions.json' 'valid-json' $false 'Tool lock is not valid JSON.') }
    foreach ($tool in @('Pester', 'PSScriptAnalyzer')) {
        $entry = Get-CiValue $lock.tools $tool
        $version = [string](Get-CiValue $entry 'version')
        $packageSha256 = [string](Get-CiValue $entry 'packageSha256')
        $packageBytes = Get-CiValue $entry 'packageBytes'
        $valid = $null -ne $entry -and $version -match '^\d+\.\d+\.\d+$' -and $version -notmatch '(?i)latest|main' -and $packageSha256 -match '^[a-f0-9]{64}$' -and $null -ne $packageBytes -and [int64]$packageBytes -gt 0 -and -not [string]::IsNullOrWhiteSpace([string](Get-CiValue $entry 'packageHashSource')) -and -not [string]::IsNullOrWhiteSpace([string](Get-CiValue $entry 'packageHashVerification'))
        $checks.Add((ConvertTo-CiCheck 'tool-versions.json' "locked-$tool" $valid "$tool has a concrete, non-floating version."))
    }
    foreach ($action in @($lock.actions.PSObject.Properties)) {
        $valid = [string]$action.Value.ref -match '^[0-9a-fA-F]{40}$'
        $checks.Add((ConvertTo-CiCheck 'tool-versions.json' "pinned-$($action.Name)" $valid "$($action.Name) is pinned to a full commit SHA."))
    }
    return $checks.ToArray()
}

if ($MyInvocation.InvocationName -ne '.') {
    $all = [Collections.Generic.List[object]]::new()
    foreach ($check in @(Test-CiToolVersionLock)) { $all.Add($check) }
    foreach ($path in $WorkflowPath) { foreach ($check in @(Test-CiWorkflowPolicy -Path $path)) { $all.Add($check) } }
    $passed = @($all | Where-Object passed).Count
    $failed = @($all | Where-Object { -not $_.passed }).Count
    $report = [ordered]@{ schemaVersion = '1.0'; policy = 'M8-CI'; generatedUtc = [DateTime]::UtcNow.ToString('o'); total = $all.Count; passed = $passed; failed = $failed; checks = $all.ToArray() }
    $json = $report | ConvertTo-Json -Depth 8
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $full = [IO.Path]::GetFullPath($OutputPath); [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
        [IO.File]::WriteAllText($full, $json + "`r`n", [Text.UTF8Encoding]::new($false))
    }
    Write-Output $json
    if ($failed -gt 0) { exit 1 }
    exit 0
}

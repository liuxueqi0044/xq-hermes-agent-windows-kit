[CmdletBinding()]
param(
    [string]$ResultPath = (Join-Path (Join-Path $PSScriptRoot '..') 'TestResults\m7-pester-results.xml'),
    [string]$SummaryJsonPath = (Join-Path (Join-Path $PSScriptRoot '..') 'TestResults\m7-summary.json'),
    [string]$SummaryTextPath = (Join-Path (Join-Path $PSScriptRoot '..') 'TestResults\m7-summary.txt'),
    [string]$CoveragePath = (Join-Path (Join-Path $PSScriptRoot '..') 'TestResults\m7-coverage.xml')
)

# This entry point is deliberately offline. Tool installation belongs to CI; a
# test run must never silently reach PSGallery, GitHub, or a Hermes endpoint.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$requiredPester = [version]'5.7.1'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'The M1-M10 test suite requires PowerShell 7 or later.'
}

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -eq $requiredPester } |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $pester) {
    throw "Pester $requiredPester is required. The offline runner does not install dependencies."
}
Import-Module $pester.Path -Force

function Set-TemporaryEnvironment {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    $old = [Environment]::GetEnvironmentVariable($Name, 'Process')
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    return [pscustomobject]@{ Name = $Name; Value = $old }
}

$resultFull = [IO.Path]::GetFullPath($ResultPath)
$summaryJsonFull = [IO.Path]::GetFullPath($SummaryJsonPath)
$summaryTextFull = [IO.Path]::GetFullPath($SummaryTextPath)
$coverageFull = [IO.Path]::GetFullPath($CoveragePath)
foreach ($path in @($resultFull, $summaryJsonFull, $summaryTextFull, $coverageFull)) {
    $parent = [IO.Path]::GetDirectoryName($path)
    if ([string]::IsNullOrWhiteSpace($parent)) { throw "Report path has no parent: $path" }
    [IO.Directory]::CreateDirectory($parent) | Out-Null
}

$isolationRoot = Join-Path ([IO.Path]::GetTempPath()) ('xq-hermes-tests-' + [Guid]::NewGuid().ToString('N'))
$isolationRoot = [IO.Path]::GetFullPath($isolationRoot)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $isolationRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test isolation path escaped the operating-system temporary root.'
}
[IO.Directory]::CreateDirectory($isolationRoot) | Out-Null
$oldEnvironment = @()
$environmentNames = @('HERMES_HOME', 'HERMES_CONFIG_DIR', 'HERMES_DATA_DIR', 'LOCALAPPDATA')
try {
    foreach ($name in $environmentNames) {
        $oldEnvironment += Set-TemporaryEnvironment -Name $name -Value $isolationRoot
    }

    $testRoot = $PSScriptRoot
    $preferred = @(
        'Provenance.Tests.ps1', 'Content.Tests.ps1', 'Diagnose.Tests.ps1',
        'Package.Tests.ps1', 'Integration.Tests.ps1', 'Security.Tests.ps1',
        'Pipeline.Tests.ps1', 'Governance.Tests.ps1'
    )
    $orderedSuites = [Collections.Generic.List[string]]::new()
    foreach ($name in $preferred) {
        $candidate = Join-Path $testRoot $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $orderedSuites.Add([IO.Path]::GetFullPath($candidate)) }
    }
    $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($suite in $orderedSuites) { [void]$known.Add($suite) }
    foreach ($suite in @(Get-ChildItem -LiteralPath $testRoot -Filter '*.Tests.ps1' -File -Recurse | Sort-Object FullName)) {
        $full = [IO.Path]::GetFullPath($suite.FullName)
        if ($known.Add($full)) { $orderedSuites.Add($full) }
    }
    if ($orderedSuites.Count -eq 0) { throw 'No Pester test suites were found.' }

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $orderedSuites.ToArray()
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = $resultFull
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.CodeCoverage.Enabled = $true
    $configuration.CodeCoverage.Path = @(
        (Join-Path (Split-Path -Parent $testRoot) 'build\Common.psm1'),
        (Join-Path (Split-Path -Parent $testRoot) 'security\Invoke-SecurityGate.ps1'),
        (Join-Path (Split-Path -Parent $testRoot) 'tools\Hermes-XQ-Diagnose.ps1'),
        (Join-Path (Split-Path -Parent $testRoot) 'ci\Validate-CI.ps1')
    )
    $configuration.CodeCoverage.OutputPath = $coverageFull
    $configuration.CodeCoverage.OutputFormat = 'JaCoCo'

    $result = Invoke-Pester -Configuration $configuration
    $failed = [int]$result.FailedCount
    $summary = [ordered]@{
        schemaVersion = '1.0'
        runner = 'tests/Run-All.ps1'
        mode = 'offline'
        generatedUtc = [DateTime]::UtcNow.ToString('o')
        pesterVersion = [string]$pester.Version
        suites = @($orderedSuites | ForEach-Object { [IO.Path]::GetRelativePath((Split-Path -Parent $testRoot), $_).Replace('\', '/') })
        total = [int]$result.TotalCount
        passed = [int]$result.PassedCount
        failed = $failed
        skipped = [int]$result.SkippedCount
        notRun = [int]$result.NotRunCount
        nunitXml = $resultFull
        coverageEnabled = $true
        coverageFormat = 'JaCoCo'
        coveragePath = $coverageFull
        coverageThresholdStrategy = 'report-required; branch coverage is not claimed; release gate requires a non-empty coverage report'
        isolatedHome = $true
    }
    [IO.File]::WriteAllText($summaryJsonFull, (($summary | ConvertTo-Json -Depth 8) + "`r`n"), [Text.UTF8Encoding]::new($false))
    $lines = @(
        'XQ Hermes Agent Windows Kit - M1-M10 offline test summary',
        ('Mode: {0}' -f $summary.mode),
        ('Pester: {0}' -f $summary.pesterVersion),
        ('Suites: {0}' -f $summary.suites.Count),
        ('Total: {0}  Passed: {1}  Failed: {2}  Skipped: {3}  NotRun: {4}' -f $summary.total, $summary.passed, $summary.failed, $summary.skipped, $summary.notRun),
        ('NUnit XML: {0}' -f $resultFull),
        ('JSON summary: {0}' -f $summaryJsonFull)
    )
    [IO.File]::WriteAllText($summaryTextFull, (($lines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($false))
    Write-Output ($lines -join "`n")
    if ($failed -gt 0) { exit 1 }
    exit 0
}
finally {
    foreach ($entry in $oldEnvironment) {
        [Environment]::SetEnvironmentVariable([string]$entry.Name, $entry.Value, 'Process')
    }
    if (Test-Path -LiteralPath $isolationRoot) {
        Remove-Item -LiteralPath $isolationRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

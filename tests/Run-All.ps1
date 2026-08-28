[CmdletBinding()]
param(
    [string]$ResultPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'The M1-M5 test suite requires PowerShell 7 or later.'
}

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $pester) {
    throw 'Pester 5.x is required. Install it for the current user before running this suite.'
}
Import-Module $pester.Path -Force

$testRoot = $PSScriptRoot
$orderedSuites = @(
    'Provenance.Tests.ps1',
    'Content.Tests.ps1',
    'Diagnose.Tests.ps1',
    'Package.Tests.ps1',
    'Integration.Tests.ps1'
) | ForEach-Object { Join-Path $testRoot $_ }

$configuration = New-PesterConfiguration
$configuration.Run.Path = $orderedSuites
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'

if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $resultFull = [IO.Path]::GetFullPath($ResultPath)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resultFull)) | Out-Null
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = $resultFull
    $configuration.TestResult.OutputFormat = 'NUnitXml'
}

$result = Invoke-Pester -Configuration $configuration
Write-Output ("M1-M5 TEST SUMMARY: total={0}, passed={1}, failed={2}, skipped={3}" -f
    $result.TotalCount, $result.PassedCount, $result.FailedCount, $result.SkippedCount)
if ($result.FailedCount -gt 0) {
    throw "M1-M5 test suite failed with $($result.FailedCount) failure(s)."
}

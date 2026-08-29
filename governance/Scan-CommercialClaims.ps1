[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$Path = (Join-Path $PSScriptRoot '..\content\support')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$patterns = @(
    '(?i)永久(更新|升级|维护|支持)', '(?i)无限(售后|支持|答疑)', '(?i)(lifetime|永久).*(update|support|maintenance)',
    '(?i)(100\s*%|百分之百|百分百).*(成功|可用|通过)', '(?i)(guaranteed|guarantee|one hundred percent).*(success|works)',
    '(?i)(所有杀软|all antivirus).*(零误报|无误报|zero false positive)', '(?i)zero false positives', '(?i)never expires.*support'
)
$files = if (Test-Path -LiteralPath $Path -PathType Leaf) { @(Get-Item -LiteralPath $Path) } else { @(Get-ChildItem -LiteralPath $Path -Recurse -File -Include '*.md', '*.html', '*.txt') }
$findings = [System.Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
        $lineNumber++
        foreach ($pattern in $patterns) {
            if ($line -match $pattern) { $findings.Add([pscustomobject]@{ File = $file.Name; Line = $lineNumber; Rule = $pattern }) }
        }
    }
}
if ($findings.Count -gt 0) { throw ('COMMERCIAL CLAIM SCAN FAILED: {0} prohibited claim(s) found.' -f $findings.Count) }
[pscustomobject]@{ Passed = $true; FilesScanned = $files.Count; FindingCount = 0; Message = 'No prohibited commercial promises found.' }

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BeforePath,
    [Parameter(Mandatory)][string]$AfterPath,
    [Parameter(Mandatory)][string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CanonicalJson { param([object]$Value) return ($Value | ConvertTo-Json -Depth 30 -Compress) }
function Protect-DiffValue {
    param([object]$Value)
    if ($Value -is [string]) {
        $safe = [regex]::Replace($Value, '(?i)(api[_-]?key|token|bearer|password|secret)(?:\s*[=:]\s*|\s+)[^\s;]+', '$1=[REDACTED]')
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $safe = [regex]::Replace($safe, [regex]::Escape($env:USERPROFILE), '[USERPROFILE]', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        return $safe
    }
    return $Value
}
function Get-FlatValue {
    param([object]$Value, [string]$Prefix = '')
    $map = [ordered]@{}
    if ($null -eq $Value) { $map[$Prefix] = $null; return $map }
    if ($Value -is [psobject] -and @($Value.PSObject.Properties).Count -gt 0 -and $Value -isnot [string]) {
        foreach ($property in $Value.PSObject.Properties) {
            $child = if ($Prefix) { "$Prefix.$($property.Name)" } else { $property.Name }
            foreach ($entry in (Get-FlatValue -Value $property.Value -Prefix $child).GetEnumerator()) { $map[$entry.Key] = $entry.Value }
        }
        return $map
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $index = 0
        foreach ($item in $Value) {
            foreach ($entry in (Get-FlatValue -Value $item -Prefix "$Prefix[$index]").GetEnumerator()) { $map[$entry.Key] = $entry.Value }
            $index++
        }
        if ($index -eq 0) { $map[$Prefix] = @() }
        return $map
    }
    $map[$Prefix] = $Value
    return $map
}

$before = Get-Content -LiteralPath $BeforePath -Raw | ConvertFrom-Json
$after = Get-Content -LiteralPath $AfterPath -Raw | ConvertFrom-Json
$beforeMap = Get-FlatValue $before
$afterMap = Get-FlatValue $after
$keys = @($beforeMap.Keys + $afterMap.Keys | Sort-Object -Unique)
$changes = foreach ($key in $keys) {
    $old = if ($beforeMap.Contains($key)) { Get-CanonicalJson $beforeMap[$key] } else { $null }
    $new = if ($afterMap.Contains($key)) { Get-CanonicalJson $afterMap[$key] } else { $null }
    if ($old -ne $new) { [ordered]@{ path = $key; before = Protect-DiffValue $beforeMap[$key]; after = Protect-DiffValue $afterMap[$key] } }
}
$result = [ordered]@{ schemaVersion = '1.0'; generatedAtUtc = [DateTime]::UtcNow.ToString('o'); before = [IO.Path]::GetFileName($BeforePath); after = [IO.Path]::GetFileName($AfterPath); changedCount = @($changes).Count; changes = @($changes) }
$fullPath = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath)) | Out-Null
$result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $fullPath -Encoding utf8NoBOM
$result

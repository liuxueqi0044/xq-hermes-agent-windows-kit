[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath,
    [hashtable]$Provider = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-InjectedValue {
    param([string]$Name, [scriptblock]$Fallback)
    if ($Provider.ContainsKey($Name)) {
        $value = $Provider[$Name]
        if ($value -is [scriptblock]) { return @(& $value) }
        return @($value)
    }
    return @(& $Fallback)
}

function ConvertTo-SafeBaselineValue {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $safe = [regex]::Replace($Value, '(?i)(api[_-]?key|token|bearer|password|secret)(?:\s*[=:]\s*|\s+)[^\s;]+', '$1=[REDACTED]')
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $safe = [regex]::Replace($safe, [regex]::Escape($env:USERPROFILE), '[USERPROFILE]', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        return $safe
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $output = [ordered]@{}
        foreach ($key in $Value.Keys) { $output[[string]$key] = ConvertTo-SafeBaselineValue $Value[$key] }
        return $output
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-SafeBaselineValue $_ })
    }
    if ($Value -is [psobject] -and @($Value.PSObject.Properties).Count -gt 0) {
        $output = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $output[$property.Name] = ConvertTo-SafeBaselineValue $property.Value }
        return $output
    }
    return $Value
}

$services = Get-InjectedValue -Name 'Services' -Fallback {
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        Get-CimInstance Win32_Service | Select-Object Name, State, StartMode, PathName, StartName
    }
}
$tasks = Get-InjectedValue -Name 'ScheduledTasks' -Fallback {
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        Get-ScheduledTask | Select-Object TaskPath, TaskName, State
    }
}
$startup = Get-InjectedValue -Name 'StartupItems' -Fallback {
    $items = @()
    if ($IsWindows) {
        foreach ($key in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run') {
            if (Test-Path -LiteralPath $key) { $items += Get-ItemProperty -LiteralPath $key | Select-Object PSPath, * }
        }
    }
    $items
}
$ports = Get-InjectedValue -Name 'ListeningPorts' -Fallback {
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        Get-NetTCPConnection -State Listen | Select-Object LocalAddress, LocalPort, OwningProcess
    }
}
$userPath = Get-InjectedValue -Name 'UserPath' -Fallback { [Environment]::GetEnvironmentVariable('Path', 'User') }
$directories = Get-InjectedValue -Name 'RelatedDirectories' -Fallback {
    @(
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'hermes' })
        $(if ($env:APPDATA) { Join-Path $env:APPDATA 'hermes' })
        $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.hermes' })
    ) | Where-Object { $_ } | Select-Object -Unique | ForEach-Object {
        [pscustomobject]@{ Path = $_; Exists = Test-Path -LiteralPath $_ -PathType Container }
    }
}
$firewall = Get-InjectedValue -Name 'Firewall' -Fallback {
    if (Get-Command Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
        Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction
    }
}
$security = Get-InjectedValue -Name 'Security' -Fallback {
    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        Get-MpComputerStatus | Select-Object AMServiceEnabled, AntivirusEnabled, RealTimeProtectionEnabled, IoavProtectionEnabled
    }
}
$os = Get-InjectedValue -Name 'OperatingSystem' -Fallback {
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, OSArchitecture
    }
}

$record = [ordered]@{
    schemaVersion = '1.0'
    capturedAtUtc = [DateTime]::UtcNow.ToString('o')
    collectionMode = if ($Provider.Count -gt 0) { 'injected-provider' } else { 'read-only-local' }
    host = [ordered]@{ computerName = '[REDACTED]'; os = ConvertTo-SafeBaselineValue $os }
    services = ConvertTo-SafeBaselineValue $services
    scheduledTasks = ConvertTo-SafeBaselineValue $tasks
    startupItems = ConvertTo-SafeBaselineValue $startup
    listeningPorts = ConvertTo-SafeBaselineValue $ports
    userPath = ConvertTo-SafeBaselineValue $userPath
    relatedDirectories = ConvertTo-SafeBaselineValue $directories
    firewall = ConvertTo-SafeBaselineValue $firewall
    security = ConvertTo-SafeBaselineValue $security
}
$fullPath = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath)) | Out-Null
$record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fullPath -Encoding utf8NoBOM
Get-Item -LiteralPath $fullPath

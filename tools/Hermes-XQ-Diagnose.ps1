[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers only manage a validated child process and an owned temporary directory; the public diagnostic remains read-only.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification = 'Best-effort cleanup and bounded stream collection must not replace the primary diagnostic result with a cleanup error.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Private helper names describe measured milliseconds and the complete Hermes home metadata set; they are not exported commands.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Script entry parameters are forwarded only in direct-execution mode; dot-sourcing deliberately exposes the functions without invoking them.')]
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidateSet('Isolated')]
    [string]$SafeDoctorMode = 'Isolated',
    [ValidateRange(1, 300)]
    [int]$CommandTimeoutSeconds = 15,
    # These hooks are intentionally public so tests can use fake executables without
    # changing PATH or reading a real Hermes installation.
    [scriptblock]$CommandInvoker,
    [scriptblock]$ExecutableResolver,
    [scriptblock]$GatewayProbe
)

# Windows PowerShell 5.1-compatible runtime behavior is intentional.
Set-StrictMode -Version 2.0

$script:DiagnosticStatuses = @('正常', '警告', '未安装', '无法检查')

function New-ProbeResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('正常', '警告', '未安装', '无法检查')][string]$Status,
        [string]$Detail = '',
        [int]$DurationMs = 0
    )

    [pscustomobject]@{
        Name       = $Name
        Status     = $Status
        Detail     = $Detail
        DurationMs = $DurationMs
    }
}

function Get-ElapsedMilliseconds {
    param([System.Diagnostics.Stopwatch]$Stopwatch)
    if ($null -eq $Stopwatch) { return 0 }
    return [int][Math]::Min([int]::MaxValue, $Stopwatch.ElapsedMilliseconds)
}

function Invoke-SafeProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Probe
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $value = & $Probe
        $watch.Stop()
        if ($null -ne $value -and $value.PSObject.Properties['Status']) { return $value }
        return New-ProbeResult -Name $Name -Status '正常' -Detail ([string]$value) -DurationMs (Get-ElapsedMilliseconds $watch)
    } catch {
        $watch.Stop()
        return New-ProbeResult -Name $Name -Status '无法检查' -Detail '检查发生异常。' -DurationMs (Get-ElapsedMilliseconds $watch)
    }
}

function ConvertTo-WindowsProcessArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    # Quote arguments for ProcessStartInfo.Arguments. This is the Windows argv
    # quoting algorithm and does not construct a shell command line.
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
            [void]$sb.Append('\"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$sb.Append(('\' * $slashes)); $slashes = 0 }
        [void]$sb.Append($character)
    }
    if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Stop-ChildProcess {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process -or $Process.HasExited) { return }
    try {
        # Kill(bool) exists on modern .NET and also terminates a process tree. The
        # fallback is required for Windows PowerShell/.NET Framework.
        $killWithTree = $Process.GetType().GetMethod('Kill', [type[]]@([bool]))
        if ($null -ne $killWithTree) { [void]$killWithTree.Invoke($Process, @($true)) }
        else { $Process.Kill() }
    } catch {
        try { $Process.Kill() } catch { }
    }
}

function Invoke-ChildCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 15,
        [hashtable]$Environment
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        # PS 7/.NET Core exposes ArgumentList. Windows PowerShell 5.1 does not,
        # so use its direct ProcessStartInfo.Arguments property with safe quoting.
        $argumentListProperty = $startInfo.GetType().GetProperty('ArgumentList')
        if ($null -ne $argumentListProperty) {
            foreach ($argument in $ArgumentList) { [void]$startInfo.ArgumentList.Add([string]$argument) }
        } else {
            $quoted = @()
            foreach ($argument in $ArgumentList) { $quoted += (ConvertTo-WindowsProcessArgument ([string]$argument)) }
            $startInfo.Arguments = ($quoted -join ' ')
        }

        if ($null -ne $Environment) {
            # Build a deliberately tiny child environment. Only values needed to
            # locate the executable and temporary directories are copied.
            $startInfo.EnvironmentVariables.Clear()
            $safeNames = @('Path', 'SystemRoot', 'SystemDrive', 'WINDIR', 'TEMP', 'TMP', 'PATHEXT', 'ComSpec')
            foreach ($safeName in $safeNames) {
                $safeValue = [Environment]::GetEnvironmentVariable($safeName)
                if ($null -ne $safeValue) { $startInfo.EnvironmentVariables[$safeName] = $safeValue }
            }
            foreach ($entry in $Environment.GetEnumerator()) {
                if ($null -ne $entry.Key -and $null -ne $entry.Value) {
                    $startInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
                }
            }
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Process could not be started.' }
        # Read both redirected streams asynchronously. Event handlers execute on
        # .NET thread-pool threads and cannot safely invoke PowerShell scriptblocks
        # under Windows PowerShell 5.1.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $timedOut = $false
        while (-not ([bool]$process.WaitForExit(100))) {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                Stop-ChildProcess -Process $process
                break
            }
        }
        try { [void]$process.WaitForExit(2000) } catch { }
        $stdoutText = ''
        $stderrText = ''
        # A timed-out process can leave inherited pipe handles in a child
        # process. Never wait indefinitely for those tasks; only consume streams
        # once their tasks have completed.
        if ($stdoutTask.IsCompleted) { try { $stdoutText = $stdoutTask.GetAwaiter().GetResult() } catch { } }
        if ($stderrTask.IsCompleted) { try { $stderrText = $stderrTask.GetAwaiter().GetResult() } catch { } }
        $watch.Stop()
        return [pscustomobject]@{
            Succeeded = (-not $timedOut -and $process.ExitCode -eq 0)
            TimedOut  = $timedOut
            ExitCode  = if ($timedOut) { $null } else { $process.ExitCode }
            StdOut    = $stdoutText
            StdErr    = $stderrText
            Error     = ''
            DurationMs = (Get-ElapsedMilliseconds $watch)
        }
    } catch {
        $watch.Stop()
        if ($null -ne $process) { Stop-ChildProcess -Process $process }
        return [pscustomobject]@{
            Succeeded = $false
            TimedOut  = $false
            ExitCode  = $null
            StdOut    = ''
            StdErr    = ''
            Error     = $_.Exception.Message
            DurationMs = (Get-ElapsedMilliseconds $watch)
        }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Protect-DiagnosticText {
    [OutputType([string])]
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }

    $safe = [string]$Text
    # Labelled secrets, including values in JSON/YAML and command output.
    # Once a line identifies a secret-bearing field, redact the rest of that
    # line. This also covers multi-value Cookie/Authorization headers where a
    # delimiter-based replacement could leave secondary credentials behind.
    $safe = [regex]::Replace($safe, '(?im)(?<![A-Za-z])((?:api[_-]?key|secret|token|access[_-]?token|refresh[_-]?token|password|passwd|authorization|cookie|client[_-]?secret))\s*[=:]\s*[^\r\n]*', '$1=<REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}', 'Bearer <REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)\b(?:sk-[A-Za-z0-9_-]{12,}|sk-proj-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|xox[baprs]-[A-Za-z0-9-]{12,}|AIzaSy[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})\b', '<REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)https?://[^\s/@:]+:[^\s/@]+@', 'https://<REDACTED>@')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '<REDACTED>')
    # High-entropy standalone values: require mixed case/digits and punctuation
    # to avoid redacting ordinary version strings and filesystem paths.
    $safe = [regex]::Replace($safe, '\b(?=[A-Za-z0-9+/=_-]{32,}\b)(?=[A-Za-z0-9+/=_-]*[A-Z])(?=[A-Za-z0-9+/=_-]*[a-z])(?=[A-Za-z0-9+/=_-]*\d)[A-Za-z0-9+/=_-]{32,}\b', '<REDACTED>')
    return $safe
}

function Get-SafeDiagnosticSnippet {
    param([AllowNull()][string]$Text, [int]$MaxLength = 2000)
    $safe = Protect-DiagnosticText $Text
    # Reports contain a compact diagnostic hint, never an unbounded command log.
    $safe = ($safe -replace '[\r\n]+', ' | ').Trim()
    if ($safe.Length -gt $MaxLength) { return ($safe.Substring(0, $MaxLength) + ' …') }
    return $safe
}

function Test-HighConfidenceSecret {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $false }
    return ($Text -match '(?im)(?:api[_-]?key|secret|token|access[_-]?token|refresh[_-]?token|password|passwd|authorization|cookie)\s*[=:]\s*(?!<REDACTED>)[^\s,;]+' -or
            $Text -match '(?i)\bBearer\s+(?!<REDACTED>)[A-Za-z0-9._~+/=-]{8,}' -or
            $Text -match '(?i)\b(?:sk-|gh[pousr]_|xox[baprs]-|AIzaSy|AKIA)[A-Za-z0-9_-]{12,}' -or
            $Text -match '(?i)https?://[^\s/@:]+:[^\s/@]+@' -or
            $Text -match '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b')
}

function Resolve-Executable {
    param([Parameter(Mandatory = $true)][string]$Name, [scriptblock]$Resolver)
    try {
        if ($null -ne $Resolver) {
            $resolved = & $Resolver $Name
            if ($null -eq $resolved) { return $null }
            if ($resolved -is [string]) { return [pscustomobject]@{ Name = $Name; Path = [string]$resolved } }
            return $resolved
        }
        $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $command) { return $null }
        $path = $command.Path
        if ([string]::IsNullOrWhiteSpace($path)) { $path = $command.Source }
        if ([string]::IsNullOrWhiteSpace($path)) { $path = $command.Definition }
        if ([string]::IsNullOrWhiteSpace($path)) { return $null }
        # Do not execute PowerShell functions, aliases, or scripts as a substitute
        # for an executable. The official launcher is an executable on Windows.
        if ($command.CommandType -notmatch '^Application$') { return $null }
        return [pscustomobject]@{ Name = $Name; Path = [string]$path }
    } catch { return $null }
}

function Invoke-ConfiguredCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 15,
        [hashtable]$Environment,
        [scriptblock]$Invoker
    )
    if ($null -ne $Invoker) {
        try {
            return (& $Invoker $FilePath $ArgumentList $TimeoutSeconds $Environment)
        } catch {
            return [pscustomobject]@{ Succeeded = $false; TimedOut = $false; ExitCode = $null; StdOut = ''; StdErr = ''; Error = $_.Exception.Message; DurationMs = 0 }
        }
    }
    return (Invoke-ChildCommand -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds -Environment $Environment)
}

function Get-SystemSummary {
    param([string]$OutputDirectory)
    $items = @()
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $caption = Protect-DiagnosticText ([string]$os.Caption)
        $version = Protect-DiagnosticText ([string]$os.Version)
        $items += New-ProbeResult -Name 'Windows' -Status '正常' -Detail "$caption $version"
    } catch {
        $items += New-ProbeResult -Name 'Windows' -Status '无法检查' -Detail '无法读取 Windows 版本元数据。'
    }
    try {
        $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { '非 x64' }
        $archStatus = if ($arch -eq 'x64') { '正常' } else { '警告' }
        $items += New-ProbeResult -Name '系统架构' -Status $archStatus -Detail $arch
    } catch { $items += New-ProbeResult -Name '系统架构' -Status '无法检查' -Detail '无法判断系统架构。' }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $items += New-ProbeResult -Name '管理员权限' -Status (if ($isAdmin) { '警告' } else { '正常' }) -Detail (if ($isAdmin) { '当前为管理员；工具本身不会申请或使用提权。' } else { '普通用户权限。' })
    } catch { $items += New-ProbeResult -Name '管理员权限' -Status '无法检查' -Detail '无法判断当前权限。' }
    try {
        $driveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($OutputDirectory))
        $drive = New-Object IO.DriveInfo($driveRoot)
        $freeGb = [Math]::Round($drive.AvailableFreeSpace / 1GB, 2)
        $diskStatus = if ($freeGb -ge 5) { '正常' } else { '警告' }
        $items += New-ProbeResult -Name '可用磁盘空间' -Status $diskStatus -Detail ("{0} GB" -f $freeGb)
    } catch { $items += New-ProbeResult -Name '可用磁盘空间' -Status '无法检查' -Detail '无法读取输出目录所在磁盘的可用空间。' }
    return $items
}

function Get-ToolInventory {
    param([scriptblock]$Resolver, [scriptblock]$Invoker, [int]$TimeoutSeconds = 15)
    $tools = @(
        [pscustomobject]@{ DisplayName = 'Hermes'; Name = 'hermes'; Arguments = @('--version') },
        [pscustomobject]@{ DisplayName = 'Python'; Name = 'python'; Arguments = @('--version') },
        [pscustomobject]@{ DisplayName = 'uv'; Name = 'uv'; Arguments = @('--version') },
        [pscustomobject]@{ DisplayName = 'Node.js'; Name = 'node'; Arguments = @('--version') },
        [pscustomobject]@{ DisplayName = 'Git'; Name = 'git'; Arguments = @('--version') },
        [pscustomobject]@{ DisplayName = 'ffmpeg'; Name = 'ffmpeg'; Arguments = @('-version') },
        [pscustomobject]@{ DisplayName = 'ripgrep'; Name = 'rg'; Arguments = @('--version') }
    )
    $results = @()
    foreach ($definition in $tools) {
        $displayName = [string]$definition.DisplayName
        $name = [string]$definition.Name
        $arguments = [string[]]$definition.Arguments
        $executable = Resolve-Executable -Name $name -Resolver $Resolver
        if ($null -eq $executable) {
            $results += New-ProbeResult -Name $displayName -Status '未安装' -Detail '未找到可执行文件。'
            continue
        }
        $probe = Invoke-ConfiguredCommand -FilePath ([string]$executable.Path) -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds -Invoker $Invoker
        if ($probe.TimedOut) {
            $results += New-ProbeResult -Name $displayName -Status '无法检查' -Detail '版本命令超时。' -DurationMs ([int]$probe.DurationMs)
        } elseif (-not $probe.Succeeded) {
            $results += New-ProbeResult -Name $displayName -Status '无法检查' -Detail '版本命令执行失败。' -DurationMs ([int]$probe.DurationMs)
        } else {
            $versionText = [string]$probe.StdOut
            if ([string]::IsNullOrWhiteSpace($versionText)) { $versionText = [string]$probe.StdErr }
            $versionText = ($versionText -split "`r?`n")[0].Trim()
            $results += New-ProbeResult -Name $displayName -Status '正常' -Detail (Protect-DiagnosticText $versionText) -DurationMs ([int]$probe.DurationMs)
        }
    }
    return $results
}

function New-IsolatedHermesHome {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $candidate = Join-Path $tempRoot ('xq-hermes-doctor-' + [Guid]::NewGuid().ToString('N'))
    $created = New-Item -ItemType Directory -Path $candidate -Force -ErrorAction Stop
    $full = [IO.Path]::GetFullPath($created.FullName)
    if (-not $full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Isolated directory escaped the temporary root.' }
    if (($created.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Isolated directory is a reparse point.' }
    return $full
}

function Remove-OwnedTemporaryDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $full = [IO.Path]::GetFullPath($item.FullName)
        $rootWithSeparator = $tempRoot.TrimEnd('\') + '\'
        $leaf = Split-Path -Leaf $full
        $ownedPrefix = 'xq-hermes-doctor-'
        if ($full.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase) -and
            $leaf.StartsWith($ownedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Get-HermesSummary {
    param(
        [Parameter(Mandatory = $true)]$HermesExecutable,
        [ValidateSet('Isolated')][string]$SafeDoctorMode = 'Isolated',
        [scriptblock]$Invoker,
        [int]$TimeoutSeconds = 15
    )
    if ($SafeDoctorMode -cne 'Isolated') {
        throw 'Only isolated doctor mode is supported.'
    }
    $results = @()
    $version = Invoke-ConfiguredCommand -FilePath ([string]$HermesExecutable.Path) -ArgumentList @('--version') -TimeoutSeconds $TimeoutSeconds -Invoker $Invoker
    if ($version.TimedOut) {
        $results += New-ProbeResult -Name 'Hermes 版本' -Status '无法检查' -Detail 'hermes --version 超时。' -DurationMs ([int]$version.DurationMs)
    } elseif (-not $version.Succeeded) {
        $results += New-ProbeResult -Name 'Hermes 版本' -Status '无法检查' -Detail 'hermes --version 执行失败。' -DurationMs ([int]$version.DurationMs)
    } else {
        $versionText = [string]$version.StdOut
        if ([string]::IsNullOrWhiteSpace($versionText)) { $versionText = [string]$version.StdErr }
        $results += New-ProbeResult -Name 'Hermes 版本' -Status '正常' -Detail (Protect-DiagnosticText (($versionText -split "`r?`n")[0].Trim())) -DurationMs ([int]$version.DurationMs)
    }

    $isolatedHome = $null
    try {
        $isolatedHome = New-IsolatedHermesHome
        $isolatedParent = Split-Path -Parent $isolatedHome
        $isolatedDrive = [IO.Path]::GetPathRoot($isolatedHome)
        $isolatedDriveName = $isolatedDrive.TrimEnd('\')
        $isolatedHomePart = $isolatedHome.Substring($isolatedDriveName.Length)
        $childEnvironment = @{
            HERMES_HOME = $isolatedHome
            # Hermes releases that derive their default home from platform
            # variables must still resolve inside the same owned temp tree.
            LOCALAPPDATA = $isolatedParent
            APPDATA = $isolatedParent
            USERPROFILE = $isolatedHome
            HOMEDRIVE = $isolatedDriveName
            HOMEPATH = $isolatedHomePart
        }
        $doctor = Invoke-ConfiguredCommand -FilePath ([string]$HermesExecutable.Path) -ArgumentList @('doctor') -TimeoutSeconds $TimeoutSeconds -Environment $childEnvironment -Invoker $Invoker
        if ($doctor.TimedOut) {
            $results += New-ProbeResult -Name 'Hermes doctor（隔离）' -Status '无法检查' -Detail 'doctor 超时；未读取真实 Hermes Home。' -DurationMs ([int]$doctor.DurationMs)
        } elseif (-not $doctor.Succeeded) {
            $detail = Get-SafeDiagnosticSnippet ([string]$doctor.StdOut + [Environment]::NewLine + [string]$doctor.StdErr)
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'doctor 返回失败；未读取真实 Hermes Home。' }
            $results += New-ProbeResult -Name 'Hermes doctor（隔离）' -Status '警告' -Detail ($detail.Trim() + ' 未检查真实账号与用户配置。') -DurationMs ([int]$doctor.DurationMs)
        } else {
            $detail = Get-SafeDiagnosticSnippet ([string]$doctor.StdOut)
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'doctor 已完成。' }
            $results += New-ProbeResult -Name 'Hermes doctor（隔离）' -Status '正常' -Detail ($detail.Trim() + ' 未检查真实账号与用户配置。') -DurationMs ([int]$doctor.DurationMs)
        }
    } catch {
        $results += New-ProbeResult -Name 'Hermes doctor（隔离）' -Status '无法检查' -Detail '无法创建受控临时 Hermes Home；未读取真实 Hermes Home。'
    } finally {
        Remove-OwnedTemporaryDirectory -Path $isolatedHome
    }
    return $results
}

function Get-HermesHomeMetadata {
    param([string]$HermesHomePath)
    if ([string]::IsNullOrWhiteSpace($HermesHomePath)) {
        try { $HermesHomePath = Join-Path ([Environment]::GetEnvironmentVariable('LOCALAPPDATA')) 'hermes' } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($hermesHomePath)) { return New-ProbeResult -Name 'Hermes Home 元数据' -Status '未安装' -Detail 'LOCALAPPDATA 不可用。' }
    try {
        $root = Get-Item -LiteralPath $hermesHomePath -Force -ErrorAction Stop
        if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return New-ProbeResult -Name 'Hermes Home 元数据' -Status '无法检查' -Detail 'Hermes Home 是 reparse point，未跟随。' }
        $total = [Int64]0
        $stack = New-Object System.Collections.Stack
        $stack.Push($root.FullName)
        $scanWatch = [Diagnostics.Stopwatch]::StartNew()
        while ($stack.Count -gt 0) {
            # A damaged or unusually large cache must not make a support report
            # hang indefinitely. Small test fixtures and normal installations get
            # an exact total; a bounded scan is reported as a warning.
            if ($scanWatch.Elapsed.TotalSeconds -ge 5) {
                return New-ProbeResult -Name 'Hermes Home 元数据' -Status '警告' -Detail '目录过大或访问缓慢；已停止元数据扫描，未读取文件内容。'
            }
            $current = [string]$stack.Pop()
            foreach ($entry in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($entry.PSIsContainer) { $stack.Push($entry.FullName) }
                else { $total += [Int64]$entry.Length }
            }
        }
        $sizeMb = [Math]::Round($total / 1MB, 2)
        return New-ProbeResult -Name 'Hermes Home 元数据' -Status '正常' -Detail ("目录存在；总大小 {0} MB；未读取文件内容，未跟随 reparse point。" -f $sizeMb)
    } catch [System.Management.Automation.ItemNotFoundException] {
        return New-ProbeResult -Name 'Hermes Home 元数据' -Status '未安装' -Detail '目录不存在。'
    } catch [System.UnauthorizedAccessException] {
        return New-ProbeResult -Name 'Hermes Home 元数据' -Status '无法检查' -Detail '访问被拒绝；未读取文件内容。'
    } catch {
        return New-ProbeResult -Name 'Hermes Home 元数据' -Status '无法检查' -Detail '无法读取目录元数据；未读取文件内容。'
    }
}

function Get-GatewayState {
    param([scriptblock]$Probe)
    if ($null -ne $Probe) {
        try {
            $raw = & $Probe
            if ([string]$raw -match '(?i)running|运行') { return New-ProbeResult -Name 'Gateway 状态' -Status '正常' -Detail '运行' }
            if ([string]$raw -match '(?i)stopped|stop|停止') { return New-ProbeResult -Name 'Gateway 状态' -Status '正常' -Detail '停止' }
        } catch { return New-ProbeResult -Name 'Gateway 状态' -Status '无法检查' -Detail '无法检查；未执行启停操作。' }
        return New-ProbeResult -Name 'Gateway 状态' -Status '无法检查' -Detail '状态值无法归一化；未保留原始输出。'
    }
    try {
        $running = $false
        foreach ($processName in @('hermes-gateway', 'hermes_gateway')) {
            if ($null -ne (Get-Process -Name $processName -ErrorAction SilentlyContinue)) { $running = $true; break }
        }
        if ($running) { return New-ProbeResult -Name 'Gateway 状态' -Status '正常' -Detail '运行' }
        return New-ProbeResult -Name 'Gateway 状态' -Status '正常' -Detail '停止'
    } catch { return New-ProbeResult -Name 'Gateway 状态' -Status '无法检查' -Detail '无法检查；未执行启停操作。' }
}

function Format-ProbeResult {
    param($Result)
    $detail = Protect-DiagnosticText ([string]$Result.Detail)
    return ('[{0}] {1}: {2}' -f $Result.Status, $Result.Name, $detail)
}

function Write-DiagnosticReport {
    param([Parameter(Mandatory = $true)][string]$OutputDirectory, [Parameter(Mandatory = $true)][string]$Text)
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $OutputDirectory ('Hermes-Diagnostic-' + $stamp + '.txt')
    $suffix = 1
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $OutputDirectory ('Hermes-Diagnostic-' + $stamp + '-' + $suffix + '.txt')
        $suffix++
    }
    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($path, $Text, $utf8)
    return $path
}

function Invoke-HermesXQDiagnose {
    [CmdletBinding()]
    param(
        [string]$OutputDirectory,
        [ValidateSet('Isolated')][string]$SafeDoctorMode = 'Isolated',
        [ValidateRange(1, 300)][int]$CommandTimeoutSeconds = 15,
        [scriptblock]$CommandInvoker,
        [scriptblock]$ExecutableResolver,
        [scriptblock]$GatewayProbe,
        [string]$HermesHomePath,
        [scriptblock]$HermesHomeMetadataProbe
    )
    try {
        if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
            $OutputDirectory = Read-Host '请输入用于保存诊断报告的文件夹路径（不会默认写入未知位置）'
        }
        if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw '必须明确指定 OutputDirectory。' }
        $resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
        $allResults = @()
        $allResults += Get-SystemSummary -OutputDirectory $resolvedOutput
        $allResults += Get-ToolInventory -Resolver $ExecutableResolver -Invoker $CommandInvoker -TimeoutSeconds $CommandTimeoutSeconds
        $hermes = Resolve-Executable -Name 'hermes' -Resolver $ExecutableResolver
        if ($null -ne $hermes) {
            $allResults += Get-HermesSummary -HermesExecutable $hermes -SafeDoctorMode $SafeDoctorMode -Invoker $CommandInvoker -TimeoutSeconds $CommandTimeoutSeconds
        }
        if ($null -ne $HermesHomeMetadataProbe) {
            try { $allResults += (& $HermesHomeMetadataProbe $HermesHomePath) }
            catch { $allResults += New-ProbeResult -Name 'Hermes Home 元数据' -Status '无法检查' -Detail '无法读取目录元数据；未读取文件内容。' }
        } else {
            $allResults += Get-HermesHomeMetadata -HermesHomePath $HermesHomePath
        }
        $allResults += Get-GatewayState -Probe $GatewayProbe

        $lines = @(
            'XQ Hermes Agent Windows Kit - 本地只读诊断报告',
            ('生成时间（UTC）: ' + (Get-Date).ToUniversalTime().ToString('o')),
            '采集策略: 只读；不联网；不上传；不修复；不提权。',
            'Doctor 模式: Isolated（未检查真实账号与用户配置）',
            ''
        )
        foreach ($result in $allResults) { $lines += (Format-ProbeResult -Result $result) }
        $lines += ''
        $lines += '说明: 报告仅包含本机状态摘要；未采集密钥、会话正文、日志、用户文件或凭据。'
        $report = Protect-DiagnosticText (($lines -join [Environment]::NewLine))
        $report = Protect-DiagnosticText $report
        if (Test-HighConfidenceSecret -Text $report) {
            $report = "XQ Hermes Agent Windows Kit - 本地只读诊断报告`r`n生成失败：安全过滤器检测到未能确认已脱敏的敏感内容。未写入原始诊断输出。"
        }
        $path = Write-DiagnosticReport -OutputDirectory $resolvedOutput -Text $report
        # Keep the function's return value a numeric process status; the path is
        # user-facing CLI output and therefore does not pollute Pester assertions.
        Write-Information -MessageData $path -InformationAction Continue
        return 0
    } catch {
        Write-Error ('诊断报告未生成：' + (Protect-DiagnosticText $_.Exception.Message))
        return 1
    }
}

# Dot-sourcing exposes the functions for Pester; executing the file runs the CLI.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-HermesXQDiagnose -OutputDirectory $OutputDirectory -SafeDoctorMode $SafeDoctorMode -CommandTimeoutSeconds $CommandTimeoutSeconds -CommandInvoker $CommandInvoker -ExecutableResolver $ExecutableResolver -GatewayProbe $GatewayProbe)
}

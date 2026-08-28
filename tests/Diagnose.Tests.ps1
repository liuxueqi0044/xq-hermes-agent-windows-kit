Describe 'Hermes-XQ-Diagnose' {
    BeforeEach {
        $diagnoseScript = Join-Path $PSScriptRoot '..\tools\Hermes-XQ-Diagnose.ps1'
        . (Resolve-Path -LiteralPath $diagnoseScript).Path
    }

    It '未安装 Hermes 时仍生成完整报告' {
        $out = Join-Path $TestDrive 'missing'
        $resolver = { param($name) $null }
        $invoker = { throw '未找到的命令不应被执行' }

        $result = Invoke-HermesXQDiagnose -OutputDirectory $out -HermesHomePath (Join-Path $out 'hermes') -ExecutableResolver $resolver -CommandInvoker $invoker
        $result | Should -Be 0
        $report = Get-ChildItem -LiteralPath $out -Filter 'Hermes-Diagnostic-*.txt' | Select-Object -First 1
        $report | Should -Not -BeNullOrEmpty
        $text = Get-Content -LiteralPath $report.FullName -Raw -Encoding UTF8
        $text | Should -Match 'Hermes 版本|Hermes:'
        $text | Should -Match '未安装'
    }

    It '隔离 doctor、不读取真实 Home，并脱敏敏感输出' {
        $out = Join-Path $TestDrive 'isolated'
        $seen = New-Object 'System.Collections.Generic.List[object]'
        $fakePath = Join-Path $TestDrive 'fake-hermes.exe'
        $resolver = {
            param($name)
            if ($name -eq 'hermes') { return [pscustomobject]@{ Name = 'hermes'; Path = $fakePath } }
            return $null
        }
        $invoker = {
            param($file, $arguments, $timeout, $environment)
            if ($null -ne $environment) { [void]$seen.Add($environment) }
            if ($arguments -contains 'doctor') {
                return [pscustomobject]@{
                    Succeeded = $true; TimedOut = $false; ExitCode = 0
                    StdOut = 'email=person@example.com api_key=sk-test-1234567890ABCDEF token=Bearer abcdefghijklmnop'
                    StdErr = ''; Error = ''; DurationMs = 2
                }
            }
            return [pscustomobject]@{
                Succeeded = $true; TimedOut = $false; ExitCode = 0
                StdOut = 'Hermes Agent 0.20.6'; StdErr = ''; Error = ''; DurationMs = 1
            }
        }

        $result = Invoke-HermesXQDiagnose -OutputDirectory $out -HermesHomePath (Join-Path $out 'hermes') -ExecutableResolver $resolver -CommandInvoker $invoker
        $result | Should -Be 0
        $seen.Count | Should -BeGreaterThan 0
        $seen[0].HERMES_HOME | Should -Match 'xq-hermes-doctor-'
        $seen[0].HERMES_HOME | Should -Not -Be ([Environment]::GetEnvironmentVariable('LOCALAPPDATA') + '\hermes')
        ($seen[0].HOMEDRIVE + $seen[0].HOMEPATH) | Should -Not -Be ([IO.Path]::GetPathRoot($seen[0].HERMES_HOME))
        $seen[0].HOMEPATH | Should -Match 'xq-hermes-doctor-'
        $report = Get-ChildItem -LiteralPath $out -Filter 'Hermes-Diagnostic-*.txt' | Select-Object -First 1
        $text = Get-Content -LiteralPath $report.FullName -Raw -Encoding UTF8
        $text | Should -Not -Match 'person@example.com|sk-test-|Bearer abcdefghijklmnop|abcdefghijklmnop'
        $text | Should -Match '<REDACTED>'
        $text | Should -Match '未检查真实账号与用户配置'
    }

    It '外部命令超时时继续生成报告' {
        $out = Join-Path $TestDrive 'timeout'
        $fakePath = Join-Path $TestDrive 'fake-hermes.exe'
        $resolver = { param($name) if ($name -eq 'hermes') { [pscustomobject]@{ Name = 'hermes'; Path = $fakePath } } }
        $invoker = {
            param($file, $arguments, $timeout, $environment)
            [pscustomobject]@{ Succeeded = $false; TimedOut = $true; ExitCode = $null; StdOut = ''; StdErr = ''; Error = ''; DurationMs = 10 }
        }

        $result = Invoke-HermesXQDiagnose -OutputDirectory $out -HermesHomePath (Join-Path $out 'hermes') -ExecutableResolver $resolver -CommandInvoker $invoker -CommandTimeoutSeconds 1
        $result | Should -Be 0
        $report = Get-ChildItem -LiteralPath $out -Filter 'Hermes-Diagnostic-*.txt' | Select-Object -First 1
        $text = Get-Content -LiteralPath $report.FullName -Raw -Encoding UTF8
        $text | Should -Match '超时'
        $text | Should -Match 'Gateway 状态'
    }

    It '最终报告包含四态之一且中文为 UTF-8' {
        $out = Join-Path $TestDrive 'utf8'
        $resolver = { param($name) $null }
        Invoke-HermesXQDiagnose -OutputDirectory $out -HermesHomePath (Join-Path $out 'hermes') -ExecutableResolver $resolver | Should -Be 0
        $report = Get-ChildItem -LiteralPath $out -Filter 'Hermes-Diagnostic-*.txt' | Select-Object -First 1
        $bytes = [IO.File]::ReadAllBytes($report.FullName)
        $bytes.Length | Should -BeGreaterThan 3
        $text = [IO.File]::ReadAllText($report.FullName, (New-Object Text.UTF8Encoding -ArgumentList $false))
        $text | Should -Match '正常|警告|未安装|无法检查'
    }

    It '脱敏函数覆盖 key、Bearer、Cookie、密码、邮箱、URL 凭据和长串' {
        $raw = "api_key=abc123 token: xyz`nCookie: sid=sid123; secondary=secondSecret`npassword=letmein`nAuthorization: Bearer foo@example.com`nhttps://user:pass@example.test ZxA9qwertyUIOP1234567890abcdefgh"
        $safe = Protect-DiagnosticText $raw
        $safe | Should -Not -Match 'abc123|xyz|sid123|secondSecret|letmein|foo@example.com|user:pass@'
        $safe | Should -Match '<REDACTED>'
    }

    It 'Hermes Home 元数据只读长度且不跟随 reparse point' {
        $hermesFixtureHome = Join-Path $TestDrive 'metadata-home'
        New-Item -ItemType Directory -Path $hermesFixtureHome -Force | Out-Null
        $fixture = Join-Path $PSScriptRoot 'fixtures\diagnose\metadata-fixture.txt'
        Copy-Item -LiteralPath $fixture -Destination (Join-Path $hermesFixtureHome 'payload.txt')
        Set-Content -LiteralPath (Join-Path $hermesFixtureHome '.env') -Value 'api_key=must-not-be-read' -NoNewline
        Mock Get-Content { throw '诊断工具不得读取文件内容' }

        $result = Get-HermesHomeMetadata -HermesHomePath $hermesFixtureHome
        $result.Status | Should -Be '正常'
        $result.Detail | Should -Match '总大小'
        Should -Invoke Get-Content -Times 0 -Exactly

        # Symlink creation requires Developer Mode/admin on some Windows hosts;
        # skip this part when the fixture environment does not permit it.
        $target = Join-Path $TestDrive 'metadata-target.txt'
        Set-Content -LiteralPath $target -Value 'target-content' -NoNewline
        $link = Join-Path $hermesFixtureHome 'reparse-link.txt'
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
            $again = Get-HermesHomeMetadata -HermesHomePath $hermesFixtureHome
            $again.Detail | Should -Match '总大小'
        } catch {
            Set-ItResult -Skipped -Because '当前测试环境不支持创建 SymbolicLink'
        }
    }
}

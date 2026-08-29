$ErrorActionPreference = 'Stop'

Describe 'M7/M8 CI and release pipeline policy' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidateWorkflow = Get-Content (Join-Path $script:RepoRoot '.github/workflows/validate.yml') -Raw
        $script:BuildWorkflow = Get-Content (Join-Path $script:RepoRoot '.github/workflows/build-package.yml') -Raw
        . (Join-Path $script:RepoRoot 'ci/Validate-CI.ps1')
        $script:Lock = Get-Content (Join-Path $script:RepoRoot 'ci/tool-versions.json') -Raw | ConvertFrom-Json
    }

    It 'has a PR and push validation workflow' {
        $script:ValidateWorkflow | Should -Match '(?m)^on:\s*'
        $script:ValidateWorkflow | Should -Match '(?m)^\s+pull_request:\s*$'
        $script:ValidateWorkflow | Should -Match '(?m)^\s+push:\s*$'
    }

    It 'runs validation on a Windows runner with read-only contents permission' {
        $script:ValidateWorkflow | Should -Match 'runs-on:\s*windows-latest'
        $script:ValidateWorkflow | Should -Match '(?ms)^permissions:\s*\r?\n\s+contents:\s*read'
    }

    It 'pins every action to a complete commit SHA' {
        $checks = Test-CiWorkflowPolicy -Path (Join-Path $script:RepoRoot '.github/workflows/validate.yml')
        ($checks | Where-Object rule -eq 'third-party-actions-use-full-commit-sha').passed | Should -BeTrue
        $script:ValidateWorkflow | Should -Not -Match '(?im)uses:\s*[^\s@]+@(main|master|latest|v\d)'
    }

    It 'does not use pull_request_target or access repository secrets' {
        $script:ValidateWorkflow | Should -Not -Match 'pull_request_target'
        $script:ValidateWorkflow | Should -Not -Match '\$\{\{\s*secrets\.'
    }

    It 'locks Pester and PSScriptAnalyzer versions' {
        $script:Lock.tools.Pester.version | Should -Be '5.7.1'
        $script:Lock.tools.PSScriptAnalyzer.version | Should -Be '1.25.0'
        $script:Lock.tools.Pester.packageSha256 | Should -Be '4a27904c6814a5fbe4758f8e49861f6a1994aee77b71165a5c43c0371ba6c580'
        $script:Lock.tools.PSScriptAnalyzer.packageSha256 | Should -Be '14e634c828eb98efb9f40b2918ba90f139ed5eccdf663a2a747736d996995d60'
        $script:ValidateWorkflow | Should -Match 'Install-LockedTools\.ps1'
        $installer = Get-Content (Join-Path $script:RepoRoot 'ci/Install-LockedTools.ps1') -Raw
        $installer | Should -Match 'DirectorySeparatorChar'
        $installer | Should -Match 'xq-tool-download-'
    }

    It 'keeps validation offline and never acquires the formal installer' {
        $script:ValidateWorkflow | Should -Not -Match 'Fetch-OfficialRelease|Resolve-OfficialRelease|Hermes-Setup\.exe.*(curl|wget|Invoke-WebRequest)'
        $script:ValidateWorkflow | Should -Match 'Run offline M1-M10 test suites'
        $script:ValidateWorkflow | Should -Not -Match 'Invoke-ScriptAnalyzer[^\r\n]+-Severity\s+Error(?:\s|$)'
    }

    It 'uploads reports with a pinned upload action even after failure' {
        $script:ValidateWorkflow | Should -Match '(?ms)if:\s*always\(\).*?uses:\s*actions/upload-artifact@[0-9a-f]{40}'
    }

    It 'is manually dispatched and not PR-triggered for formal packaging' {
        $script:BuildWorkflow | Should -Match '(?m)^\s+workflow_dispatch:\s*$'
        $script:BuildWorkflow | Should -Not -Match '(?m)^\s+pull_request:\s*$'
        $checks = Test-CiWorkflowPolicy -Path (Join-Path $script:RepoRoot '.github/workflows/build-package.yml')
        ($checks | Where-Object rule -eq 'dispatch-only').passed | Should -BeTrue
    }

    It 'uses a protected approval environment before release' {
        $script:BuildWorkflow | Should -Match 'environment:\s*release-approval'
        $script:BuildWorkflow | Should -Match 'Recheck all release gates after environment approval'
    }

    It 'requires the formal manifest before installer acquisition' {
        $script:BuildWorkflow | Should -Match 'Validate formal manifest before acquiring installer'
        $script:BuildWorkflow | Should -Match 'Assert-XqManifest .* -Formal'
    }

    It 'keeps formal installer acquisition out of validate workflow' {
        $script:BuildWorkflow | Should -Match 'Acquire verified official installer'
        $script:ValidateWorkflow | Should -Not -Match 'official installer|Fetch-OfficialRelease|Hermes-Setup\.exe'
    }

    It 'requires all candidate evidence before creating a release' {
        foreach ($name in @('formal-manifest.json', 'tool-integrity.json', 'release-manifest.json', 'm1-m7.json', 'm1-m10.json', 'candidate.json', 'signature-report.json', 'm6-source.json', 'm6-staging.json', 'm6-zip.json', 'm6-evidence.json', 'governance-gate.json', 'vm-acceptance.md', 'vm-acceptance.json')) {
            $script:BuildWorkflow | Should -Match ([regex]::Escape($name))
        }
        $script:BuildWorkflow | Should -Match 'Test-ReleaseEvidence.ps1'
        $script:BuildWorkflow | Should -Match 'Write-XqJsonAtomic'
        $script:BuildWorkflow | Should -Match 'DirectorySeparatorChar'
    }

    It 'runs the M6 source, staging, ZIP, and evidence gates with Defender enabled' {
        $script:BuildWorkflow | Should -Match 'TargetType Source'
        $script:BuildWorkflow | Should -Match 'TargetType Staging'
        $script:BuildWorkflow | Should -Match 'TargetType Zip'
        $script:BuildWorkflow | Should -Match 'TargetType Evidence'
        $script:BuildWorkflow | Should -Not -Match 'SkipDefender'
        $script:BuildWorkflow | Should -Match 'LicensePath'
        $script:BuildWorkflow | Should -Match 'staging-unpacked'
    }

    It 'grants contents write only to the release job' {
        $script:BuildWorkflow | Should -Match '(?ms)release:\s*\r?\n.*?permissions:\s*\r?\n\s+contents:\s*write'
        $script:BuildWorkflow | Should -Match '(?ms)^permissions:\s*\r?\n\s+contents:\s*read'
        $script:BuildWorkflow | Should -Not -Match 'write-all|read-all'
    }

    It 'creates a draft release and does not force overwrite assets' {
        $script:BuildWorkflow | Should -Match 'gh release create'
        $script:BuildWorkflow | Should -Match '\-\-draft'
        $script:BuildWorkflow | Should -Match '\-\-verify-tag'
        $script:BuildWorkflow | Should -Not -Match '\-\-(clobber|force|latest)'
    }

    It 'requires a pre-created immutable release tag' {
        $script:BuildWorkflow | Should -Match 'release_tag:'
        $script:BuildWorkflow | Should -Match 'verify-tag'
        $script:BuildWorkflow | Should -Match 'existing immutable'
        $script:BuildWorkflow | Should -Match 'gh release view'
        $script:BuildWorkflow | Should -Match 'fetch-depth: 0'
        (Get-Content (Join-Path $script:RepoRoot 'ci/Test-ReleaseEvidence.ps1') -Raw) | Should -Match 'git rev-parse'
    }

    It 'has the CI policy validator and reports structured checks' {
        $checks = Test-CiWorkflowPolicy -Path (Join-Path $script:RepoRoot '.github/workflows/validate.yml')
        @($checks).Count | Should -BeGreaterOrEqual 7
        $checks[0].PSObject.Properties.Name | Should -Contain 'passed'
        $checks[0].PSObject.Properties.Name | Should -Contain 'rule'
    }

    It 'rejects floating action refs with a nonzero policy result' {
        $bad = Join-Path $TestDrive 'floating.yml'
        $script:ValidateWorkflow.Replace('actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683', 'actions/checkout@main') | Set-Content -LiteralPath $bad -Encoding utf8
        $checks = Test-CiWorkflowPolicy -Path $bad
        ($checks | Where-Object rule -eq 'third-party-actions-use-full-commit-sha').passed | Should -BeFalse
    }

    It 'rejects a workflow with broad write permissions' {
        $bad = Join-Path $TestDrive 'broad-permissions.yml'
        @"
name: bad
on:
  push:
permissions: write-all
jobs:
  check:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
"@ | Set-Content -LiteralPath $bad -Encoding utf8
        $checks = Test-CiWorkflowPolicy -Path $bad
        ($checks | Where-Object rule -eq 'least-privilege-permissions').passed | Should -BeFalse
    }

    It 'rejects a floating tool lock rather than accepting latest' {
        $bad = Join-Path $TestDrive 'tool-versions.json'
        '{"tools":{"Pester":{"version":"latest"},"PSScriptAnalyzer":{"version":"1.25.0"}},"actions":{}}' | Set-Content -LiteralPath $bad -Encoding utf8
        (Test-CiToolVersionLock -Path $bad | Where-Object rule -eq 'locked-Pester').passed | Should -BeFalse
    }

    It 'hard-fails release evidence when required acceptance input is absent' {
        $root = Join-Path $TestDrive 'empty-evidence'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        { & (Join-Path $script:RepoRoot 'ci/Test-ReleaseEvidence.ps1') -EvidenceRoot $root } | Should -Throw
    }

    It 'defines offline JSON and text summary outputs in the unified runner' {
        $runner = Get-Content (Join-Path $script:RepoRoot 'tests/Run-All.ps1') -Raw
        $runner | Should -Match 'SummaryJsonPath'
        $runner | Should -Match 'SummaryTextPath'
        $runner | Should -Match "mode = 'offline'"
        $runner | Should -Match 'OutputFormat = .NUnitXml.'
    }

    It 'enables JaCoCo-compatible Pester coverage with an explicit honest threshold policy' {
        $runner = Get-Content (Join-Path $script:RepoRoot 'tests/Run-All.ps1') -Raw
        $runner | Should -Match 'CodeCoverage.Enabled = \$true'
        $runner | Should -Match "CodeCoverage.OutputFormat = 'JaCoCo'"
        $runner | Should -Match 'coverageThresholdStrategy'
        $script:BuildWorkflow | Should -Match 'm1-m10-coverage\.xml'
    }

    It 'auto-discovers future test suites and isolates Hermes home variables' {
        $runner = Get-Content (Join-Path $script:RepoRoot 'tests/Run-All.ps1') -Raw
        $runner | Should -Match "'\*\.Tests\.ps1'"
        $runner | Should -Match 'HERMES_HOME'
        $runner | Should -Match 'LOCALAPPDATA'
        $runner | Should -Match 'xq-hermes-tests-'
    }

    It 'uses explicit exit 1 on test failures' {
        $runner = Get-Content (Join-Path $script:RepoRoot 'tests/Run-All.ps1') -Raw
        $runner | Should -Match 'if \(\$failed -gt 0\) \{ exit 1 \}'
    }
}

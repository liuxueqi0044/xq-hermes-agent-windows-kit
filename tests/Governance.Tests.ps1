Describe 'M9/M10 governance and VM acceptance hard gates' {
    BeforeAll {
        $script:Repo = Split-Path -Parent $PSScriptRoot
        $script:AcceptanceValidator = Join-Path $script:Repo 'acceptance\Validate-VmAcceptance.ps1'
        $script:BaselineScript = Join-Path $script:Repo 'acceptance\New-VmBaseline.ps1'
        $script:DiffScript = Join-Path $script:Repo 'acceptance\Compare-VmBaseline.ps1'
        $script:GateScript = Join-Path $script:Repo 'governance\Invoke-ReleaseGate.ps1'
        $script:ReleaseValidator = Join-Path $script:Repo 'governance\Validate-ReleaseManifest.ps1'
        $script:ScopeScript = Join-Path $script:Repo 'governance\Compare-SupportScope.ps1'
        $script:ClaimScript = Join-Path $script:Repo 'governance\Scan-CommercialClaims.ps1'
        $script:LegalFixture = Join-Path $script:Repo 'tests\fixtures\governance\New-LegalAcceptance.ps1'
    }

    BeforeEach {
        $script:CaseRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:CaseRoot -Force | Out-Null
        $script:ManifestPath = Join-Path $script:CaseRoot 'product-manifest.json'
        '{"buildMode":"formal","productVersion":"1.2.3","hermesVersion":"0.20.6"}' | Set-Content -LiteralPath $script:ManifestPath -Encoding utf8NoBOM
        $script:RecordPath = Join-Path $script:CaseRoot 'vm-acceptance.json'
        $script:Commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $script:CandidatePath = Join-Path $script:CaseRoot 'candidate.zip'
        $script:ReleaseManifestPath = Join-Path $script:CaseRoot 'release-manifest.json'
        'candidate' | Set-Content -LiteralPath $script:CandidatePath -Encoding utf8NoBOM
        '{}' | Set-Content -LiteralPath $script:ReleaseManifestPath -Encoding utf8NoBOM
    }

    It 'rejects an acceptance record with missing steps' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $record = Get-Content $script:RecordPath -Raw | ConvertFrom-Json
        $record.steps = @()
        $record | ConvertTo-Json -Depth 20 | Set-Content $script:RecordPath -Encoding utf8NoBOM
        { & $script:AcceptanceValidator -AcceptancePath $script:RecordPath -ManifestPath $script:ManifestPath } | Should -Throw '*Required steps*'
    }

    It 'rejects a forged PASSED state from a development machine' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $record = Get-Content $script:RecordPath -Raw | ConvertFrom-Json
        $record.execution.isDevelopmentMachine = $true
        $record | ConvertTo-Json -Depth 20 | Set-Content $script:RecordPath -Encoding utf8NoBOM
        { & $script:AcceptanceValidator -AcceptancePath $script:RecordPath -ManifestPath $script:ManifestPath } | Should -Throw '*development machine*'
    }

    It 'requires independent evidence for the Chinese and English VM runs' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $record = Get-Content $script:RecordPath -Raw | ConvertFrom-Json
        $record.vmMatrix[1].machineEvidenceId = $record.vmMatrix[0].machineEvidenceId
        $record.vmMatrix[1].baselineEvidenceRef = $record.vmMatrix[0].baselineEvidenceRef
        $record | ConvertTo-Json -Depth 20 | Set-Content $script:RecordPath -Encoding utf8NoBOM
        { & $script:AcceptanceValidator -AcceptancePath $script:RecordPath -ManifestPath $script:ManifestPath } | Should -Throw '*independent machine and baseline evidence*'
    }

    It 'rejects a manifest hash mismatch' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        '{"buildMode":"formal","productVersion":"9.9.9"}' | Set-Content $script:ManifestPath -Encoding utf8NoBOM
        { & $script:AcceptanceValidator -AcceptancePath $script:RecordPath -ManifestPath $script:ManifestPath } | Should -Throw '*manifestSha256*'
    }

    It 'rejects expired evidence' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $record = Get-Content $script:RecordPath -Raw | ConvertFrom-Json
        $record.expiresAtUtc = '2026-08-01T00:00:00Z'
        $record | ConvertTo-Json -Depth 20 | Set-Content $script:RecordPath -Encoding utf8NoBOM
        { & $script:AcceptanceValidator -AcceptancePath $script:RecordPath -ManifestPath $script:ManifestPath -CurrentUtc ([datetime]'2026-08-29T00:00:00Z') } | Should -Throw '*expired*'
    }

    It 'rejects evidence when credentials were not revoked' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $record = Get-Content $script:RecordPath -Raw | ConvertFrom-Json
        $record.credentialRevocation.completed = $false
        $record | ConvertTo-Json -Depth 20 | Set-Content $script:RecordPath -Encoding utf8NoBOM
        { & $script:AcceptanceValidator -AcceptancePath $script:RecordPath -ManifestPath $script:ManifestPath } | Should -Throw '*revocation*'
    }

    It 'rejects evidence when VM rollback is not declared' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $record = Get-Content $script:RecordPath -Raw | ConvertFrom-Json
        $record.vmRollback.completed = $false
        $record | ConvertTo-Json -Depth 20 | Set-Content $script:RecordPath -Encoding utf8NoBOM
        { & $script:AcceptanceValidator -AcceptancePath $script:RecordPath -ManifestPath $script:ManifestPath } | Should -Throw '*rollback*'
    }

    It 'rejects a scope conflict between self-service and remote documents' {
        { & $script:ScopeScript -SelfServicePath (Join-Path $script:Repo 'tests\fixtures\governance\scope-conflict-self.md') -RemoteServicePath (Join-Path $script:Repo 'tests\fixtures\governance\scope-conflict-remote.md') } | Should -Throw '*SCOPE CHECK FAILED*'
    }

    It 'rejects prohibited commercial promises' {
        { & $script:ClaimScript -Path (Join-Path $script:Repo 'tests\fixtures\governance\invalid-claim.md') } | Should -Throw '*prohibited claim*'
    }

    It 'blocks a draft manifest before release' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $draft = '{"buildMode":"draft","productVersion":"1.2.3"}'
        $draft | Set-Content $script:ManifestPath -Encoding utf8NoBOM
        { & $script:GateScript -ManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -CandidateArtifactPath $script:CandidatePath -ReleaseDestinationPath (Join-Path $script:CaseRoot 'new.zip') -ReleaseManifestPath $script:ReleaseManifestPath } | Should -Throw '*not a formal build*'
    }

    It 'blocks an existing artifact to protect old releases' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $artifact = Join-Path $script:CaseRoot 'old.zip'
        'old' | Set-Content $artifact -Encoding utf8NoBOM
        { & $script:GateScript -ManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -CandidateArtifactPath $script:CandidatePath -ReleaseDestinationPath $artifact -ReleaseManifestPath $script:ReleaseManifestPath } | Should -Throw '*old artifacts*'
    }

    It 'blocks a template acceptance record' {
        $template = Join-Path $script:Repo 'acceptance\vm-acceptance-template.json'
        { & $script:AcceptanceValidator -AcceptancePath $template -ManifestPath $script:ManifestPath } | Should -Throw '*template*'
    }

    It 'blocks the M10 release manifest template in the standalone validator' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $template = Join-Path $script:Repo 'governance\release-manifest.template.json'
        { & $script:ReleaseValidator -ReleaseManifestPath $template -ProductManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -SupportScopePath (Join-Path $script:Repo 'manifest\support-scope.json') -CandidateArtifactPath $script:CandidatePath } | Should -Throw '*template*'
    }

    It 'accepts a synthetic shape only when it carries real VM human attestation' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $result = & $script:AcceptanceValidator -AcceptancePath $script:RecordPath -ManifestPath $script:ManifestPath
        $result.Valid | Should -BeTrue
        $result.State | Should -Be 'PASSED'
    }

    It 'collects a baseline through injected providers without system probes' {
        $out = Join-Path $script:CaseRoot 'before.json'
        $provider = @{ Services = { [pscustomobject]@{ Name = 'fixture'; State = 'Stopped' } }; ScheduledTasks = { @() }; StartupItems = { @() }; ListeningPorts = { @() }; UserPath = { 'C:\Fixture' }; RelatedDirectories = { @([pscustomobject]@{ Path = 'C:\Fixture'; Exists = $false }) }; Firewall = { @() }; Security = { @() }; OperatingSystem = { [pscustomobject]@{ Caption = 'Windows 11'; OSArchitecture = '64-bit' } } }
        & $script:BaselineScript -OutputPath $out -Provider $provider | Out-Null
        (Get-Content $out -Raw | ConvertFrom-Json).collectionMode | Should -Be 'injected-provider'
    }

    It 'redacts credential arguments and the user profile from VM baselines' {
        $out = Join-Path $script:CaseRoot 'redacted-baseline.json'
        $provider = @{ Services = { @() }; ScheduledTasks = { @() }; StartupItems = { @([pscustomobject]@{ Command = "fixture.exe --token syntheticSecret123456" }) }; ListeningPorts = { @() }; UserPath = { "$env:USERPROFILE\bin" }; RelatedDirectories = { @() }; Firewall = { @() }; Security = { @() }; OperatingSystem = { @() } }
        & $script:BaselineScript -OutputPath $out -Provider $provider | Out-Null
        $raw = Get-Content $out -Raw
        $raw | Should -Not -Match 'syntheticSecret123456'
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $raw | Should -Not -Match ([regex]::Escape($env:USERPROFILE)) }
        $raw | Should -Match '\[REDACTED\]|\[USERPROFILE\]'
    }

    It 'produces a structured before-after baseline diff' {
        $before = Join-Path $script:CaseRoot 'before.json'; $after = Join-Path $script:CaseRoot 'after.json'; $diff = Join-Path $script:CaseRoot 'diff.json'
        '{"services":[{"Name":"fixture","State":"Stopped"}]}' | Set-Content $before -Encoding utf8NoBOM
        '{"services":[{"Name":"fixture","State":"Running"}]}' | Set-Content $after -Encoding utf8NoBOM
        & $script:DiffScript -BeforePath $before -AfterPath $after -OutputPath $diff | Out-Null
        (Get-Content $diff -Raw | ConvertFrom-Json).changedCount | Should -BeGreaterThan 0
    }

    It 'rejects an invalid runtime commit match' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $record = Get-Content $script:RecordPath -Raw | ConvertFrom-Json
        $record.runtime.commit = ('b' * 40)
        $record | ConvertTo-Json -Depth 20 | Set-Content $script:RecordPath -Encoding utf8NoBOM
        { & $script:AcceptanceValidator -AcceptancePath $script:RecordPath -ManifestPath $script:ManifestPath } | Should -Throw '*Runtime commit*'
    }

    It 'requires a candidate artifact and release destination at parameter binding' {
        { & $script:GateScript -ManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -ReleaseManifestPath $script:ReleaseManifestPath } | Should -Throw
    }

    It 'rejects a release destination directory as an overwrite target' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        $destination = Join-Path $script:CaseRoot 'existing-directory'; New-Item -ItemType Directory -Path $destination | Out-Null
        { & $script:GateScript -ManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -CandidateArtifactPath $script:CandidatePath -ReleaseDestinationPath $destination -ReleaseManifestPath $script:ReleaseManifestPath } | Should -Throw '*old artifacts*'
    }

    It 'rejects a malformed formal manifest through the shared Common validator' {
        & $script:LegalFixture -ManifestPath $script:ManifestPath -OutputPath $script:RecordPath | Out-Null
        { & $script:GateScript -ManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -CandidateArtifactPath $script:CandidatePath -ReleaseDestinationPath (Join-Path $script:CaseRoot 'new.zip') -ReleaseManifestPath $script:ReleaseManifestPath } | Should -Throw '*formal validation*'
    }

    It 'rejects a release manifest that is already marked RELEASED' {
        '{"releaseStatus":"RELEASED"}' | Set-Content $script:ReleaseManifestPath -Encoding utf8NoBOM
        { & $script:GateScript -ManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -CandidateArtifactPath $script:CandidatePath -ReleaseDestinationPath (Join-Path $script:CaseRoot 'new.zip') -ReleaseManifestPath $script:ReleaseManifestPath } | Should -Throw '*status must be CANDIDATE*'
    }

    It 'rejects an artifact binding path mismatch' {
        '{"releaseStatus":"CANDIDATE","artifact":{"path":"other.zip"}}' | Set-Content $script:ReleaseManifestPath -Encoding utf8NoBOM
        { & $script:GateScript -ManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -CandidateArtifactPath $script:CandidatePath -ReleaseDestinationPath (Join-Path $script:CaseRoot 'new.zip') -ReleaseManifestPath $script:ReleaseManifestPath } | Should -Throw '*artifact.path*'
    }

    It 'rejects an acceptance binding path mismatch' {
        '{"releaseStatus":"CANDIDATE","acceptanceRecord":{"path":"other.json","state":"PASSED","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' | Set-Content $script:ReleaseManifestPath -Encoding utf8NoBOM
        { & $script:GateScript -ManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -CandidateArtifactPath $script:CandidatePath -ReleaseDestinationPath (Join-Path $script:CaseRoot 'new.zip') -ReleaseManifestPath $script:ReleaseManifestPath } | Should -Throw '*acceptanceRecord.path*'
    }

    It 'rejects a semver object that disagrees with productVersion' {
        '{"releaseStatus":"CANDIDATE","productVersion":"1.2.3","semver":{"major":1,"minor":2,"patch":4}}' | Set-Content $script:ReleaseManifestPath -Encoding utf8NoBOM
        { & $script:GateScript -ManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -CandidateArtifactPath $script:CandidatePath -ReleaseDestinationPath (Join-Path $script:CaseRoot 'new.zip') -ReleaseManifestPath $script:ReleaseManifestPath } | Should -Throw '*semver object*'
    }

    It 'rejects an unsupported scope that omits first-release exclusions' {
        '{"releaseStatus":"CANDIDATE","unsupported":[]}' | Set-Content $script:ReleaseManifestPath -Encoding utf8NoBOM
        { & $script:GateScript -ManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -CandidateArtifactPath $script:CandidatePath -ReleaseDestinationPath (Join-Path $script:CaseRoot 'new.zip') -ReleaseManifestPath $script:ReleaseManifestPath } | Should -Throw '*knownIssues and unsupported*'
    }

    It 'rejects a release tag that does not map the two manifest versions' {
        '{"releaseStatus":"CANDIDATE","releaseTag":"xq-v9.9.9-hermes-0.1.0"}' | Set-Content $script:ReleaseManifestPath -Encoding utf8NoBOM
        { & $script:GateScript -ManifestPath $script:ManifestPath -AcceptancePath $script:RecordPath -CandidateArtifactPath $script:CandidatePath -ReleaseDestinationPath (Join-Path $script:CaseRoot 'new.zip') -ReleaseManifestPath $script:ReleaseManifestPath } | Should -Throw '*releaseTag*'
    }
}

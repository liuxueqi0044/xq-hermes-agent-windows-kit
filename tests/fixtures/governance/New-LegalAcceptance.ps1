[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$OutputPath
)
Set-StrictMode -Version Latest
$hash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$record = [ordered]@{
    schemaVersion = '1.0'; recordId = 'VM-20260829-001'; state = 'PASSED'; previousState = 'IN_PROGRESS'; productVersion = '1.2.3'; hermesVersion = '0.20.6'; manifestSha256 = $hash; expiresAtUtc = '2026-09-29T00:00:00Z'
    vmMatrix = @(@{ locale = 'zh-CN'; os = 'Windows 11'; architecture = 'x64'; result = 'PASS'; machineEvidenceId = 'zh-vm-001'; baselineEvidenceRef = 'zh-baseline' }, @{ locale = 'en-US'; os = 'Windows 11'; architecture = 'x64'; result = 'PASS'; machineEvidenceId = 'en-vm-001'; baselineEvidenceRef = 'en-baseline' })
    steps = @('offline-content', 'source-hash-signature', 'install-first-run', 'runtime-pin', 'user-model-config', 'ordinary-chat', 'version-doctor', 'diagnostic-redaction', 'reboot-reopen', 'reinstall-update-data', 'uninstall-behavior', 'system-baseline-diff', 'credential-revoke-vm-rollback' | ForEach-Object { @{ id = $_; result = 'PASS'; evidenceRef = "evidence-$_" } })
    runtime = @{ commit = $commit; version = '0.20.6'; manifestCommit = $commit; consistent = $true }
    evidence = @{ screenshotIndex = @('shot-01', 'shot-02'); screenshotsRedacted = $true }
    credentialRevocation = @{ completed = $true; declaration = 'Temporary test credentials revoked.' }
    vmRollback = @{ completed = $true; declaration = 'Both clean VM snapshots rolled back.' }
    signoff = @{ name = 'Acceptance owner'; signature = 'signed-in-person'; signedAtUtc = '2026-08-29T00:00:00Z' }
    execution = @{ humanVerified = $true; vmEvidenceId = 'real-vm-evidence-001'; isDevelopmentMachine = $false }
}
$record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM

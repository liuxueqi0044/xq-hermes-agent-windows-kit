# M9 acceptance tooling

`New-VmBaseline.ps1` is read-only. It records service, scheduled-task, startup-item, listening-port, User PATH, relevant-directory existence, firewall, Defender/security and OS summaries. All local probes are bypassable with the `-Provider` hashtable for tests; supported keys are `Services`, `ScheduledTasks`, `StartupItems`, `ListeningPorts`, `UserPath`, `RelatedDirectories`, `Firewall`, `Security` and `OperatingSystem`.

`Compare-VmBaseline.ps1` writes a structured before/after diff. `Validate-VmAcceptance.ps1` treats JSON as authoritative and rejects templates, pending/failed steps, missing evidence and non-VM attestations. Markdown is presentation-only: `Invoke-ReleaseGate.ps1` requires a same-basename JSON sidecar.

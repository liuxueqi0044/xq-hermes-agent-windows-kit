# M9 acceptance status

Status: **PENDING REAL VM EXECUTION**

The repository contains the read-only baseline collector, before/after diff, structured JSON schema, template, validator and release gate. No development-machine run can create a `PASSED` record. Final acceptance is waiting for human execution on isolated clean Windows 11 x64 Chinese (`zh-CN`) and English (`en-US`) VMs with temporary test credentials, redacted screenshots, credential revocation and VM snapshot rollback evidence.

The release gate must remain blocked until that evidence is supplied as a validated `vm-acceptance.json` (the Markdown record is presentation-only and requires the same-basename JSON sidecar).

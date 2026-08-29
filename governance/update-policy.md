# Update policy

An upstream update creates a new candidate with a new SemVer/build identity. It never replaces or mutates an old ZIP. Re-run source locking, hash/signature verification, content and security checks, package checks and both-language clean-VM acceptance before release. Document compatibility, known issues and rollback/withdrawal decisions.

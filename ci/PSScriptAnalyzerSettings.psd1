@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # Existing kit scripts intentionally use aliases in user-facing output
        # and compatibility shims for Windows PowerShell 5.1.
        'PSAvoidUsingWriteHost',
        'PSUseApprovedVerbs'
    )
}

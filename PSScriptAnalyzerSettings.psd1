@{
    # PSScriptAnalyzer configuration for this repo.
    # Run: Invoke-ScriptAnalyzer -Path scripts -Settings PSScriptAnalyzerSettings.psd1 -Recurse
    Severity = @('Error', 'Warning')

    # Rules intentionally excluded, with justification:
    ExcludeRules = @(
        # This is an interactive console utility. Write-Host is used deliberately for
        # colored, human-facing status output (progress, mode banner, summaries). Its
        # output is UX, not data on the pipeline, so Write-Information/Write-Output would
        # degrade the experience (no color, hidden unless -InformationAction Continue).
        'PSAvoidUsingWriteHost',

        # A few best-effort blocks (TLS 1.2 enablement, optional Retry-After / date /
        # status-code parsing) intentionally swallow failures because a parse miss must
        # not abort the run; the code falls back to safe defaults. Failing hard there
        # would be worse than ignoring the exception.
        'PSAvoidUsingEmptyCatchBlock'
    )
}

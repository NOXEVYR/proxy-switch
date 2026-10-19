# Explicit single-process diagnostic. Dot-sourcing this module does not open any process.
# ExpectedCreationTicks uses StartTime.ToUniversalTime().Ticks, not a Win32 FILETIME.
function Get-ProcessProxyEnvironmentObservation {
    param([int]$ProcessId,[string]$ExpectedPath,[long]$ExpectedCreationTicks)
    try {
        if(-not ('LocalProxySwitch.ProcessProxyEnvironment' -as [type])) {
            Add-Type -Path (Join-Path $PSScriptRoot 'ProcessProxyEnvironment.cs') -ErrorAction Stop
        }
        [LocalProxySwitch.ProcessProxyEnvironment]::Observe($ProcessId,$ExpectedPath,$ExpectedCreationTicks)
    } catch {
        # Compilation/runtime failures never expose exception text or get interpreted as absence.
        [pscustomobject]@{State='Unknown';ReasonCode='ReaderUnavailable';Architecture='Unknown';ProcessId=$ProcessId;CreationTicks=0;Variables=@();NoProxyPresent=$null;NoProxyBroadBypass=$null}
    }
}

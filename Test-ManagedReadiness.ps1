$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-managed-readiness-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$script:Profiles.Routing.Adapter='standalone'
Write-LocalJson (Get-IndependentSessionPath) @{OwnerPID=$PID;OwnerStart=(Get-ProcessStartTicks $PID);SupervisorPID=$PID;SupervisorStart=(Get-ProcessStartTicks $PID);Started='fixture'}
function Get-GatewayLifecycle {[pscustomobject]@{phase='ready'}}
function Restore-IndependentSession {throw 'Unexpected restore of a live fixture'}
function Enable-IndependentGateway {throw 'Unexpected start of an existing fixture'}
$script:Calls=0;$script:Checks=0;$script:AlwaysFail=$false
function Check($Value,$Message){if(-not $Value){throw $Message};$script:Checks++}
function Invoke-AppRouter($Request,[int]$TimeoutMilliseconds){
 $script:Calls++
 if($script:AlwaysFail -or $script:Calls -lt 3){throw 'PRIVATE_CONTROLLER_DETAIL'}
 [pscustomobject]@{available=$true;rulesAvailable=$true;defaultLoaded=$true}
}
$result=Ensure-ManagedGateway
Check ($script:Calls -eq 3 -and $result.defaultLoaded) 'Readiness tolerates transient read-only controller failures before reporting a usable entrance'
$script:Calls=0;$script:AlwaysFail=$true;$clock=[Diagnostics.Stopwatch]::StartNew();$failure=''
try{Ensure-ManagedGateway|Out-Null}catch{$failure=$_.Exception.Message}
Check ($failure -match '尚未就绪' -and $failure -notmatch 'PRIVATE_CONTROLLER' -and $clock.Elapsed.TotalSeconds -ge 11 -and $clock.Elapsed.TotalSeconds -lt 16) 'Persistent readiness failure uses one bounded deadline and safe actionable error'
Check ($script:Calls -gt 1 -and $script:Calls -lt 80) 'Read-only readiness retry is bounded and does not busy-loop'
function Get-RecoveryOwnerState {return 'unknown'}
$failure='';try{Ensure-ManagedGateway|Out-Null}catch{$failure=$_.Exception.Message}
Check ($failure -match '身份.*未知' -and $failure -notmatch 'Unexpected') 'Unknown owner identity cannot authorize restoring or replacing an existing session'
Write-Output ('PASS: '+$script:Checks+' managed readiness checks; isolated data, no engine or Windows writes.')

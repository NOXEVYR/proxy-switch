$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-recovery-consistency-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$script:Checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:Checks++}
function Use-ChangeLock([scriptblock]$Action){& $Action}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$script:TcpAvailable;Rows=@()}}
function Test-RecoveryEndpoint {return $false} # Old active-probe result, deliberately untrustworthy.
$script:TcpAvailable=$true
$target=[pscustomobject]@{Flags=3;Server='127.0.0.1:18790';Bypass='localhost'}
$before=[pscustomobject]@{Flags=15;Server='127.0.0.1:19001';Bypass='custom-bypass'}
$oldEnv=[pscustomobject]@{HTTP_PROXY=$null;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='localhost'}
$targetEnv=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:18790';HTTPS_PROXY='http://127.0.0.1:18790';ALL_PROXY='http://127.0.0.1:18790';NO_PROXY='localhost'}
$session=[pscustomobject]@{BeforeSystem=$before;BeforeEnv=$oldEnv;TargetSystem=$target;TargetEnv=$targetEnv}
$plan=New-ExitRecoveryPlan $session $target $targetEnv
Check ($plan.System.Flags -eq 13 -and $plan.System.Bypass -eq 'custom-bypass') 'Stopping a dead original manual proxy preserves PAC and autodetect flags'
foreach($complex in @('http=127.0.0.1:19001;https=127.0.0.1:19002','proxy.example.invalid:8080')){
 $session.BeforeSystem=[pscustomobject]@{Flags=3;Server=$complex;Bypass='custom'}
 $plan=New-ExitRecoveryPlan $session $target $targetEnv
 Check (Test-SameSnapshot $plan.System $session.BeforeSystem) 'Complex and remote settings are restored without declaring them dead'
}
$session.BeforeSystem=$before;$script:TcpAvailable=$false
$script:System=$target;$script:Environment=$targetEnv;$script:Writes=0
function Get-SystemSnapshot {$script:System}
function Get-UserProxyEnv {$script:Environment}
function Set-SystemSnapshot($Value){$script:Writes++;$script:System=$Value}
function Set-UserProxyEnv($Value){$script:Writes++;$script:Environment=$Value}
function Get-ItemPropertyValue {param($LiteralPath,$Name,$ErrorAction);throw 'No OS registration in fixture'}
function Remove-ItemProperty {throw 'No OS registration may be changed'}
[void][IO.Directory]::CreateDirectory((Join-Path $qa 'gateway'))
Write-LocalJson (Get-IndependentSessionPath) $session
$failure='';try{Restore-IndependentSession}catch{$failure=$_.Exception.Message}
Check ($failure -match '未知' -and $script:Writes -eq 0 -and (Test-Path (Get-IndependentSessionPath)) -and -not (Test-Path (Join-Path $qa 'gateway/stop'))) 'Unknown old endpoint retains session and core without writing Windows or claiming successful recovery'
$session.BeforeSystem=$target;$session.BeforeEnv=$targetEnv
$plan=New-ExitRecoveryPlan $session $target $targetEnv
Check (($plan.System.Flags -band 2) -eq 0 -and -not $plan.Environment.HTTPS_PROXY) 'Own retiring entrance is removed even when general TCP observation is unavailable'
$session.BeforeSystem=[pscustomobject]@{Flags=1;Server='';Bypass='localhost'};$session.BeforeEnv=$oldEnv|ConvertTo-Json|ConvertFrom-Json
$session.BeforeEnv.HTTPS_PROXY='http://127.0.0.1:19001'
Write-LocalJson (Get-IndependentSessionPath) $session
$failure='';try{Restore-IndependentSession}catch{$failure=$_.Exception.Message}
Check ($failure -match '未知' -and $script:Writes -eq 0) 'Unknown inherited environment endpoint fails before changing either system or environment'
$script:TcpAvailable=$true
Restore-IndependentSession
Check (-not (Test-Path (Get-IndependentSessionPath)) -and (Test-Path (Join-Path $qa 'gateway/stop')) -and -not $script:Environment.HTTPS_PROXY) 'Fresh proof of a dead endpoint permits a later bounded recovery attempt'
$tcp=[pscustomobject]@{Available=$true;Rows=@([pscustomobject]@{State='Listen';LocalAddress='127.0.0.1';LocalPort=19001;OwningProcess=2147483647})}
Check ($null -eq (Get-LocalEndpointObservation '127.0.0.1:19001' $tcp).Ready) 'Network repair also keeps unreadable listener ownership unknown instead of authorizing cleanup'
$tcp.Rows[0].OwningProcess=$PID;$tcp.Rows[0].LocalAddress='::1'
Check ((Get-LocalEndpointObservation '127.0.0.1:19001' $tcp).Ready -eq $false) 'IPv6-only listener does not validate an IPv4 endpoint in diagnosis'
$tcp.Rows[0].LocalAddress='::'
Check ($null -eq (Get-LocalEndpointObservation '127.0.0.1:19001' $tcp).Ready) 'Unknown IPv6 dual-stack mode cannot authorize IPv4 cleanup'
Write-Output ('PASS: '+$script:Checks+' recovery consistency checks; isolated snapshots only.')

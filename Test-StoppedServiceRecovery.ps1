$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-stopped-service-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$script:checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++}
function Throws([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed 'Unsafe or stale operation is refused'}
function Use-ChangeLock([scriptblock]$Action){& $Action}
function Get-ClientInterference {[pscustomobject]@{Tun=$false;Guard=$false;SystemProxy=$true}}
Write-LocalJson $script:ConfigPath @{Version=3;Profiles=@(@{Id='up';Name='Up';Host='127.0.0.1';Port=19001;Protocol='http'},@{Id='owned';Name='Owned';Host='127.0.0.1';Port=18790;Protocol='http';CorePath='C:\Fixture\core.exe'});Routing=@{Adapter='standalone';ProfileId='owned';UnifiedMode='gateway'}}
$script:sys=[pscustomobject]@{Flags=3;Server='127.0.0.1:19001';Bypass='external.local'}
$script:envs=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:18790';HTTPS_PROXY='http://127.0.0.1:18790';ALL_PROXY='http://127.0.0.1:18790';NO_PROXY='custom.local'}
function Get-SystemSnapshot {$script:sys}
function Get-UserProxyEnv {$script:envs}
function Set-SystemSnapshot {throw 'Must preserve the external system proxy'}
function Set-UserProxyEnv($Value,$ExpectedBefore){Check (Test-SameEnv $ExpectedBefore $script:envs) 'Restore carries a fresh environment CAS';$script:envs=$Value}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$true;Rows=@([pscustomobject]@{State='Listen';LocalAddress='127.0.0.1';LocalPort=19001;OwningProcess=$PID})}}
function Get-Listener {param($Profile,$TcpRows);if($Profile.Port -eq 19001){[pscustomobject]@{PID=$PID}}}
function Get-ItemPropertyValue {param($LiteralPath,$Name,$ErrorAction);throw 'No isolated RunOnce value'}
function Remove-ItemProperty {throw 'No registry mutation'}
$ticks=Get-ProcessStartTicks $PID
$empty=[pscustomobject]@{HTTP_PROXY=$null;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='custom.local'}
$session=[pscustomobject]@{Version=1;Started='fixture-service';OwnerPID=$PID;OwnerStart=$ticks;SupervisorPID=2147483646;SupervisorStart='1';CorePID=2147483647;CoreStart='1';BeforeSystem=@{Flags=1;Server='';Bypass='before.local'};TargetSystem=@{Flags=3;Server='127.0.0.1:18790';Bypass='before.local'};BeforeEnv=$empty;TargetEnv=$script:envs}
$trackedPath=Join-Path $qa 'gateway\process.json'
[void][IO.Directory]::CreateDirectory((Split-Path $trackedPath))
Write-LocalJson (Get-IndependentSessionPath) $session
Write-LocalJson $trackedPath @{supervisor=$session.SupervisorPID;supervisorStartTicks=$session.SupervisorStart;core=$session.CorePID;coreStartTicks=$session.CoreStart}
Check ((Get-IndependentStoppedServiceState $session) -eq 'stopped') 'Recorded supervisor and latest child are confirmed stopped'
$d=Get-NetworkDiagnosis
Check ($d.OwnerState -eq 'alive' -and $d.RepairAction -eq 'recover-stopped-service' -and $d.Issues.Code -contains 'stopped-service-session') 'A living UI with stopped service is repairable without abandoned-owner fiction'
$fixed=Repair-NetworkDiagnosis $d.Revision
Check (-not (Test-Path (Get-IndependentSessionPath)) -and -not $script:envs.HTTP_PROXY -and $script:sys.Server -eq '127.0.0.1:19001' -and $script:envs.NO_PROXY -eq 'custom.local') 'Actual graceful restore clears owned dead variables and preserves third-party proxy/bypass'
Check (@(Get-ChildItem (Join-Path $qa 'backups') -Filter 'gateway-exit-*.json').Count -eq 1) 'Completed residual session is archived'
Write-LocalJson (Get-IndependentSessionPath) $session
Write-LocalJson $trackedPath @{supervisor=$session.SupervisorPID;supervisorStartTicks=$session.SupervisorStart;core=$PID;coreStartTicks=$ticks}
Check ((Get-IndependentStoppedServiceState $session) -eq 'alive' -and (Get-NetworkDiagnosis).RepairAction -ne 'recover-stopped-service') 'Latest live replacement child blocks cleanup despite original child being stopped'
Write-LocalJson $trackedPath @{supervisor=$session.SupervisorPID;supervisorStartTicks='other-session';core=$session.CorePID;coreStartTicks=$session.CoreStart}
Check ((Get-IndependentStoppedServiceState $session) -eq 'unknown') 'Mismatched supervisor generation is unknown'
[IO.File]::WriteAllText($trackedPath,'{broken')
Check ((Get-IndependentStoppedServiceState $session) -eq 'unknown') 'Unreadable tracked process record cannot authorize cleanup'
[IO.File]::Delete($trackedPath)
Check ((Get-IndependentStoppedServiceState $session) -eq 'unknown' -and (Get-NetworkDiagnosis).RepairAction -ne 'recover-stopped-service') 'Missing latest child record preserves the session despite stopped original PID'
Write-LocalJson $trackedPath @{supervisor=$session.SupervisorPID;supervisorStartTicks=$session.SupervisorStart;core=$session.CorePID;coreStartTicks=$session.CoreStart}
$session.SupervisorStart='';Check ((Get-IndependentStoppedServiceState $session) -eq 'unknown') 'Missing identity stays unknown';$session.SupervisorStart='1'
$session.SupervisorPID=$PID;$session.SupervisorStart=$ticks
Write-LocalJson $trackedPath @{supervisor=$PID;supervisorStartTicks=$ticks;core=$session.CorePID;coreStartTicks=$session.CoreStart}
Check ((Get-IndependentStoppedServiceState $session) -eq 'alive') 'Live supervisor recovery window is preserved'
$session.SupervisorStart='1';Write-LocalJson $trackedPath @{supervisor=$PID;supervisorStartTicks='1';core=$session.CorePID;coreStartTicks=$session.CoreStart}
Check ((Get-IndependentStoppedServiceState $session) -eq 'stopped') 'PID reuse is distinguished by creation ticks without terminating the reused process'
Write-LocalJson (Get-IndependentSessionPath) $session
$d=Get-NetworkDiagnosis;$script:sys.Bypass='external-edit';Throws {Repair-NetworkDiagnosis $d.Revision}
Check ((Test-Path (Get-IndependentSessionPath)) -and $script:sys.Bypass -eq 'external-edit') 'Revision change preserves current settings and session'
$session|Add-Member NoteProperty PreserveWindowsSettings $true
$session|Add-Member NoteProperty OwnGatewayEndpoint '127.0.0.1:18790'
Write-LocalJson (Get-IndependentSessionPath) $session
Check ((Get-NetworkDiagnosis).Issues.Code -notcontains 'system-entry-overridden') 'Third-party baseline change in program-only coexistence is not mislabeled as overridden global ownership'
Write-Output ('PASS: '+$script:checks+' stopped-service diagnosis and real graceful residual recovery assertions; Windows writes are isolated fixtures, no application is stopped.')

$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-NetworkDiagnosis-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$script:checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++}
function Use-ChangeLock([scriptblock]$Action){& $Action}
function Get-ClientInterference {[pscustomobject]@{Running=$false;Tun=$false;Guard=$false;SystemProxy=$false}}
$config=[pscustomobject]@{Version=3;Profiles=@(@{Id='up';Name='Up';Host='127.0.0.1';Port=19001;Protocol='http';AutoPort=$false},@{Id='owned';Name='Owned';Host='127.0.0.1';Port=18790;Protocol='http';AutoPort=$false;CorePath='C:\Fixture\core.exe'});Routing=@{Adapter='standalone';ProfileId='owned';UnifiedMode='gateway';Failover=@{Enabled=$true;Order=@('up');AllowDirect=$false}}}
Write-LocalJson $script:ConfigPath $config
$script:sys=[pscustomobject]@{Flags=3;Server='127.0.0.1:19001';Bypass='localhost'}
$script:envs=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:18790';HTTPS_PROXY='http://127.0.0.1:18790';ALL_PROXY='http://127.0.0.1:18790';NO_PROXY='custom.local'}
$script:ready=@(19001);$script:available=$true;$script:writes=0;$script:usable=$true;$script:probes=0
function Get-SystemSnapshot {$script:sys}
function Get-UserProxyEnv {$script:envs}
function Set-SystemSnapshot($Value){$script:writes++;$script:sys=$Value}
function Set-UserProxyEnv($Value){$script:writes++;$script:envs=$Value}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$script:available;Rows=@()}}
function Get-Listener {param($Profile,$TcpRows);if($Profile.Port -in $script:ready){[pscustomobject]@{PID=1}}}
function Test-ProxyRoute {param($Key,[switch]$Fast);[pscustomobject]@{Usable=$script:usable}}
function Test-RecoveryEndpoint($Endpoint){$Endpoint -match ':19001$'}
function Get-ItemPropertyValue {param($LiteralPath,$Name,$ErrorAction);throw 'No isolated RunOnce registration'}
function Remove-ItemProperty {throw 'No user registry writes allowed'}
function Test-NetworkTargets($Profile){$script:probes++;@([pscustomobject]@{Name='Fixture';Stage='https-response';HttpCode=403;AuthenticationVerified=$false})}
$d=Get-NetworkDiagnosis
Check ($d.Issues.Code -contains 'environment-entry-down' -and $d.RepairAction -eq 'align-environment') 'dead variables produce an explicit repair plan'
Check ($script:writes -eq 0 -and $script:probes -eq 0) 'ordinary diagnosis neither mutates settings nor sends site requests'
$null=Get-NetworkDiagnosis -Probe
Check ($script:probes -eq 1) 'explicit probe is opt-in'
Check ((Get-NetworkDiagnosis -Probe).Message -match '错误响应') 'HTTP 403 is not described as target success'
$script:available=$false;$unknown=Get-NetworkDiagnosis
Check ($unknown.Issues.Code -contains 'observation-unknown' -and -not $unknown.RepairAction) 'failed observation cannot authorize alignment'
$script:available=$true;$script:ready=@();$down=Get-NetworkDiagnosis
Check ($down.Issues.Code -contains 'system-entry-down' -and $down.RepairAction -eq 'repair-dead-entry') 'dead system upstream cannot authorize alignment'
$script:ready=@(19001);$d=Get-NetworkDiagnosis
$script:envs.NO_PROXY='changed';$rejected=$false
try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$rejected=$true}
Check ($rejected -and $script:writes -eq 0) 'configuration drift rejects an old repair plan'
$d=Get-NetworkDiagnosis;$script:usable=$false;$rejected=$false
try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$rejected=$true}
Check ($rejected -and $script:writes -eq 0) 'failed real-route precheck leaves environment untouched'
$script:usable=$true;$fixed=Repair-NetworkDiagnosis $d.Revision
Check ($script:envs.HTTP_PROXY -eq 'http://127.0.0.1:19001' -and $script:envs.NO_PROXY -match '^changed') 'alignment preserves custom bypass and uses current system route'
Check (Test-Path $fixed.Backup) 'repair creates a recoverable local backup'
Check ($fixed.Diagnosis.Issues.Count -eq 0 -and -not $fixed.Diagnosis.RepairAction) 'post-repair report clears resolved local findings'
Check ($script:sys.Server -eq '127.0.0.1:19001') 'alignment preserves the system endpoint'
Check (-not (Test-Path $script:StatePath)) 'environment-only repair does not invent a selection record on a new installation'
$savedEnv=$script:envs|ConvertTo-Json|ConvertFrom-Json
$targetEnv=New-EnvTarget $savedEnv 'up'
$beforeSystem=$script:sys|ConvertTo-Json|ConvertFrom-Json
$script:sysWrites=0
function Set-SystemSnapshot($Value){$script:sysWrites++;$script:sys=$Value}
function Set-UserProxyEnv($Value){$script:envs=$Value;$script:sys=[pscustomobject]@{Flags=3;Server='127.0.0.1:20000';Bypass='external'};$script:envs.HTTP_PROXY='http://127.0.0.1:20000'}
$rejected=$false;try{Invoke-ProxyTransaction $beforeSystem $targetEnv $null $beforeSystem $savedEnv -EnvironmentOnly|Out-Null}catch{$rejected=$true}
Check ($rejected -and $script:sysWrites -eq 0 -and $script:sys.Server -eq '127.0.0.1:20000' -and $script:envs.HTTP_PROXY -eq 'http://127.0.0.1:20000') 'concurrent external change survives environment-only failure without a system setter'
$script:sys=$beforeSystem;$script:envs=$savedEnv
function Set-SystemSnapshot($Value){$script:writes++;$script:sys=$Value}
function Set-UserProxyEnv($Value){$script:writes++;$script:envs=$Value}
$session=[pscustomobject]@{OwnerPID=2147483647;OwnerStart='1';Started='old-session';BeforeSystem=$script:sys;BeforeEnv=$script:envs;TargetSystem=@{Flags=3;Server='127.0.0.1:18790';Bypass='localhost'};TargetEnv=@{HTTP_PROXY='http://127.0.0.1:18790';HTTPS_PROXY='http://127.0.0.1:18790';ALL_PROXY='http://127.0.0.1:18790';NO_PROXY='localhost'}}
[void][IO.Directory]::CreateDirectory((Join-Path $qa 'gateway'))
Write-LocalJson (Get-IndependentSessionPath) $session
$d=Get-NetworkDiagnosis
Check ($d.RepairAction -eq 'recover-session' -and $d.OwnerState -eq 'stopped') 'abandoned previous owner is diagnosed even when manual network repair is complete'
$oldWrites=$script:writes;$fixed=Repair-NetworkDiagnosis $d.Revision
Check (-not (Test-Path (Get-IndependentSessionPath)) -and $script:writes -eq $oldWrites) 'stale session is archived without overwriting a completed external repair'
$session.OwnerPID=$PID;$session.OwnerStart=Get-ProcessStartTicks $PID;Write-LocalJson (Get-IndependentSessionPath) $session
$d=Get-NetworkDiagnosis
Check ($d.OwnerState -eq 'alive' -and $d.RepairAction -ne 'recover-session') 'live owner cannot be offered abandoned-session recovery'
$rejected=$false;try{Restore-IndependentSession -ExpectedSession $session.Started -AbandonedOnly}catch{$rejected=$true}
Check ($rejected -and (Test-Path (Get-IndependentSessionPath))) 'recovery rechecks owner identity inside the mutation lock'
$session.OwnerStart='';Write-LocalJson (Get-IndependentSessionPath) $session
$d=Get-NetworkDiagnosis
Check ($d.OwnerState -eq 'unknown' -and -not $d.RepairAction) 'missing owner evidence cannot authorize recovery or alignment'
[IO.File]::WriteAllText((Get-IndependentSessionPath),'{broken')
$d=Get-NetworkDiagnosis
Check ($d.Issues.Code -contains 'session-unreadable' -and -not $d.RepairAction) 'corrupt session is preserved and diagnosed'
# Real close handler, synthetic event, no form or app manipulation.
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'ProxyWindow.ps1'),[ref]$tokens,[ref]$errors)
$handler=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-FlowWindowClose'},$true)
. ([scriptblock]::Create($handler.Extent.Text))
Add-Type -AssemblyName System.Windows.Forms
$script:Worker=$null;$script:ExitRequested=$true;$PreviewPath='';$SmokeTest=$false;$Demo=$false
$session.OwnerPID=2147483647;$session.OwnerStart='1';Write-LocalJson (Get-IndependentSessionPath) $session
$close=[pscustomobject]@{CloseReason=[Windows.Forms.CloseReason]::ApplicationExitCall;Cancel=$false}
Invoke-FlowWindowClose $close
Check (-not $close.Cancel -and -not (Test-Path (Get-IndependentSessionPath))) 'a new UI explicitly exiting now recovers the abandoned old session'
# Execute the actual logon branch with transient errors; no OS registration is used.
Write-LocalJson (Get-IndependentSessionPath) $session
$watch=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'GatewayWatchdog.ps1'));$watch=$watch.Substring($watch.IndexOf('$path=Get-IndependentSessionPath'))
$RecoverOnly=$true;$script:attempts=0
function Restore-IndependentSession {param($ExpectedSession,[switch]$AbandonedOnly);$script:attempts++;if($script:attempts -lt 3){throw 'transient'};if(-not $AbandonedOnly){throw 'identity guard missing'}}
function Start-Sleep {param($Seconds,$Milliseconds)}
& ([scriptblock]::Create($watch))
Check ($script:attempts -eq 3) 'logon recovery retries two transient failures and completes on the third attempt'
$session.OwnerPID=$PID;$session.OwnerStart=Get-ProcessStartTicks $PID;Write-LocalJson (Get-IndependentSessionPath) $session
$script:attempts=0;& ([scriptblock]::Create($watch))
Check ($script:attempts -eq 0) 'delayed logon recovery does not stop a current live UI'
Write-Output ('PASS: '+$script:checks+' network diagnosis and repair checks; isolated data and Windows-setting stubs only.')

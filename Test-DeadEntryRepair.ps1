$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-DeadEntry-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$script:checks=0
function Check($v,$m){if(-not $v){throw $m};$script:checks++;Write-Output ('PASS: '+$m)}
function Use-ChangeLock([scriptblock]$Action){& $Action}
$config=[pscustomobject]@{Version=3;Profiles=@(@{Id='a';Name='Removed A';Host='127.0.0.1';Port=19001;Protocol='http';AutoPort=$false},@{Id='b';Name='B';Host='127.0.0.1';Port=19002;Protocol='http';AutoPort=$false},@{Id='owned';Name='Owned';Host='127.0.0.1';Port=18790;Protocol='http';AutoPort=$false;CorePath='C:\Fixture\core.exe'});Routing=@{Adapter='standalone';ProfileId='owned';UnifiedMode='gateway';Failover=@{Enabled=$true;Order=@('b','a');AllowDirect=$false}}}
Write-LocalJson $script:ConfigPath $config
Write-LocalJson $script:StatePath @{Key='a'}
Write-LocalJson (Join-Path $qa 'app-rules.json') @{version=3;installed=$true;entries=@(@{path='C:\Fixture\App.exe';route='b'});defaultRoute='a'}
$script:sys=[pscustomobject]@{Flags=3;Server='127.0.0.1:19001';Bypass='custom.local'}
$script:envs=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:19001';HTTPS_PROXY='http://127.0.0.1:19002';ALL_PROXY='socks5://localhost:19003';NO_PROXY='custom.local'}
$script:ready=@(19002);$script:available=$true;$script:guard=$false;$script:writes=0;$script:usable=$false;$script:probes=@();$script:race='';$script:handoff=$null
function Get-SystemSnapshot {$script:sys}
function Get-UserProxyEnv {$script:envs}
function Set-SystemSnapshot($Value){$script:writes++;$script:sys=$Value}
function Set-UserProxyEnv($Value){$script:writes++;$script:envs=$Value}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$script:available;Rows=@()}}
function Get-Listener {param($Profile,$TcpRows);if($Profile.Port -in $script:ready){[pscustomobject]@{PID=1}}}
function Get-ClientInterference {[pscustomobject]@{Running=$true;Tun=$false;Guard=$script:guard;SystemProxy=$true}}
function Test-ProxyRoute {param($Key,[switch]$Fast);$script:probes+=@($Key);switch($script:race){'config'{$script:sys.Bypass='external'};'guard'{$script:guard=$true};'port'{$script:ready+=19001}};[pscustomobject]@{Usable=$script:usable}}
function Enable-IndependentGateway {param($OwnerPID,$InitialRoute,[switch]$RepairEntry,$RepairRevision);Assert-NetworkRepairCurrent $RepairRevision;$script:handoff=[pscustomobject]@{Route=$InitialRoute;RepairEntry=[bool]$RepairEntry};[pscustomobject]@{Message='fixture handoff';Backup='fixture'}}
$d=Get-NetworkDiagnosis
Check ($d.RepairAction -eq 'repair-dead-entry' -and $script:probes.Count -eq 0 -and $script:writes -eq 0) 'passive dead-entry diagnosis creates an explicit plan without probes or writes'
$selection=[IO.File]::ReadAllText($script:StatePath);$rules=[IO.File]::ReadAllText((Join-Path $qa 'app-rules.json'))
$savedSystem=$script:sys|ConvertTo-Json|ConvertFrom-Json;$savedEnv=$script:envs|ConvertTo-Json|ConvertFrom-Json
$fixed=Repair-NetworkDiagnosis $d.Revision
Check (($script:sys.Flags -band 2) -eq 0 -and $script:sys.Server -eq '' -and $script:sys.Bypass -eq 'custom.local') 'no usable backup clears only the dead manual system entry'
Check (-not $script:envs.HTTP_PROXY -and -not $script:envs.ALL_PROXY -and $script:envs.HTTPS_PROXY -eq 'http://127.0.0.1:19002' -and $script:envs.NO_PROXY -eq 'custom.local') 'only proven dead environment endpoints cleared; healthy proxy and bypass preserved'
Check ((Test-Path $fixed.Backup) -and [IO.File]::ReadAllText($script:StatePath) -ceq $selection -and [IO.File]::ReadAllText((Join-Path $qa 'app-rules.json')) -ceq $rules) 'backup exists and original selection and program rules are byte-identical'
Check ($fixed.Message -match '仍需验证') 'clearing stale settings never claims target connectivity'
$script:sys=$savedSystem;$script:envs=$savedEnv;$script:usable=$true;$d=Get-NetworkDiagnosis;$beforeWrites=$script:writes
$null=Repair-NetworkDiagnosis $d.Revision
Check ($script:handoff.Route -eq 'b' -and $script:handoff.RepairEntry -and $script:writes -eq $beforeWrites) 'healthy B is delegated to verified gateway migration, not written directly as system proxy'
Check ($script:probes -notcontains 'owned' -and $script:probes -notcontains 'a') 'does not probe own gateway or known closed port'
$script:sys.Server='localhost:19999';$d=Get-NetworkDiagnosis
Check ($d.RepairAction -eq 'repair-dead-entry') 'uninstalled and removed profile can still be repaired from simple loopback endpoint'
$script:ready+=19999;function Test-NetworkTargets {throw 'Unknown endpoint must not be actively probed'};$d=Get-NetworkDiagnosis -Probe
Check ($d.SystemKey -eq 'Other' -and -not $d.RepairAction) 'live unconfigured endpoint remains diagnostic-only without probing an unknown profile'
$script:ready=@(19002)
foreach($address in @('proxy.example:8080','http=127.0.0.1:19001;https=127.0.0.1:19002','http://user:secret@localhost:19001','http://localhost:19001/path')){$script:sys.Server=$address;Check ((Get-NetworkDiagnosis).RepairAction -ne 'repair-dead-entry') 'complex, remote or credential-bearing endpoint is not guessed as dead'}
$script:sys.Server='127.0.0.1:19001';$script:available=$false
Check (-not (Get-NetworkDiagnosis).RepairAction) 'unknown TCP observation cannot authorize cleanup'
$script:available=$true;$script:guard=$true;$d=Get-NetworkDiagnosis
Check ($d.Issues.Code -contains 'external-proxy-control' -and -not $d.RepairAction) 'external guard explicitly reported and no entry takeover offered'
$script:guard=$false
foreach($race in @('config','guard','port')){
 $d=Get-NetworkDiagnosis;$script:race=$race;$script:usable=$false;$beforeWrites=$script:writes;$failed=$false
 try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$failed=$true}
 Check ($failed -and $beforeWrites -eq $script:writes) ('concurrent '+$race+' change prevents writes')
 $script:race='';$script:guard=$false;$script:ready=@(19002)
}
$d=Get-NetworkDiagnosis;Write-LocalJson (Join-Path $qa 'app-rules.json') @{changed=$true};$failed=$false
try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$failed=$true}
Check $failed 'rule changes invalidate repair preview'
$script:usable=$false;$d=Get-NetworkDiagnosis
function Set-SystemSnapshot($Value){$script:writes++;$script:sys=[pscustomobject]@{Flags=3;Server='127.0.0.1:19998';Bypass='external'};throw 'concurrent external setter'}
$failed=$false;try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$failed=$true}
Check ($failed -and $script:sys.Server -eq '127.0.0.1:19998' -and $script:envs.HTTP_PROXY -eq $savedEnv.HTTP_PROXY) 'failed write restores owned environment while preserving external system change'
$session=@{OwnerPID=$PID;OwnerStart=(Get-ProcessStartTicks $PID);Started='active';TargetSystem=@{Flags=3;Server='127.0.0.1:18790';Bypass=''}}
Write-LocalJson (Get-IndependentSessionPath) $session
$d=Get-NetworkDiagnosis
Check ($d.Issues.Code -contains 'system-entry-overridden' -and $d.RepairAction -ne 'repair-dead-entry') 'active session diversion is reported without bypassing its lifecycle'
Write-Output ('PASS: '+$script:checks+' dead-entry repair checks; isolated settings only.')

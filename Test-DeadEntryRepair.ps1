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
function Set-UserProxyEnv($Value,$ExpectedBefore){$script:writes++;$script:envs=$Value}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$script:available;Rows=@($script:ready|ForEach-Object {[pscustomobject]@{State='Listen';LocalAddress='127.0.0.1';LocalPort=$_;OwningProcess=$PID}})}}
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
Remove-Item -LiteralPath (Get-IndependentSessionPath)
$script:sys=[pscustomobject]@{Flags=3;Server='127.0.0.1:19001';Bypass='custom.local'}
$script:envs=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:19001';HTTPS_PROXY='http://127.0.0.1:19002';ALL_PROXY='socks5://localhost:19003';NO_PROXY='custom.local'}
$script:ready=@(19002);$script:guard=$false;$script:usable=$false;$script:tcpReads=0
function Set-SystemSnapshot($Value){$script:writes++;$script:sys=$Value}
function Get-TcpObservationSnapshot {
 $script:tcpReads++;if($script:tcpReads -eq 5){$script:ready+=19003}
 [pscustomobject]@{Available=$true;Rows=@($script:ready|ForEach-Object {[pscustomobject]@{State='Listen';LocalAddress='127.0.0.1';LocalPort=$_;OwningProcess=$PID}})}
}
$d=Get-NetworkDiagnosis;$beforeWrites=$script:writes;$failed=$false
try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$failed=$true}
Check ($failed -and $script:writes -eq $beforeWrites -and $script:envs.ALL_PROXY -eq 'socks5://localhost:19003') 'system dead-entry cleanup rechecks each planned environment removal when another local variable listener recovers'
# Direct Windows state with stale child/terminal variables is a distinct repair.
$script:sys=[pscustomobject]@{Flags=1;Server='';Bypass='preserved-bypass'}
$script:envs=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:19999';HTTPS_PROXY='http://127.0.0.1:19002';ALL_PROXY='socks5://localhost:19003';NO_PROXY='custom.local, *'}
$script:ready=@(19002);$script:guard=$false;$script:tun=$false;$script:available=$true;$script:tcpReads=0;$script:freshRace='';$script:unknownOwner=@()
function Get-ClientInterference {[pscustomobject]@{Running=$true;Tun=$script:tun;Guard=$script:guard;SystemProxy=$false}}
function Get-Listener {param($Profile,$TcpRows);if($Profile.Port -in $script:ready -and $Profile.Port -notin $script:unknownOwner){[pscustomobject]@{PID=1}}}
function Get-TcpObservationSnapshot {
 $script:tcpReads++
 if($script:tcpReads -eq 3){
  switch($script:freshRace){
   'port'{$script:ready+=19999}
   'unknown'{$script:ready+=19999;$script:unknownOwner=@(19999)}
   'tcp'{$script:available=$false}
   'guard'{$script:guard=$true}
   'tun'{$script:tun=$true}
   'environment'{$script:envs.HTTP_PROXY='http://127.0.0.1:19002'}
   'bypass'{$script:envs.NO_PROXY='external.local'}
   'system'{$script:sys=[pscustomobject]@{Flags=3;Server='127.0.0.1:19002';Bypass='external'}}
   'rules'{Write-LocalJson (Join-Path $qa 'app-rules.json') @{external=$true}}
   'selection'{Write-LocalJson $script:StatePath @{Key='b';external=$true}}
   'session'{Write-LocalJson (Get-IndependentSessionPath) @{Started='new-session'}}
  }
 }
 [pscustomobject]@{Available=$script:available;Rows=@($script:ready|ForEach-Object {[pscustomobject]@{State='Listen';LocalAddress='127.0.0.1';LocalPort=$_;OwningProcess=$PID}})}
}
function Set-SystemSnapshot {throw 'Environment-only repair must never invoke a Windows proxy setter'}
function Set-UserProxyEnv($Value,$ExpectedBefore){$script:writes++;$script:envs=$Value}
$d=Get-NetworkDiagnosis
Check ($d.RepairAction -eq 'clear-dead-environment' -and $d.Issues.Code -contains 'environment-entry-down' -and @($d.Endpoints.Port) -contains 19999 -and @($d.EnvironmentEndpoints|Where-Object Ready -eq $false).Count -eq 2) 'unregistered stale loopback variables are diagnosed individually while Windows is direct'
$originalSystem=$script:sys|ConvertTo-Json -Compress;$originalEnvironment=$script:envs|ConvertTo-Json|ConvertFrom-Json
$rulesPath=Join-Path $qa 'app-rules.json';$websitePath=Join-Path $qa 'website-canary.json'
Write-LocalJson $websitePath @{siteRules=@(@{host='fixture.invalid';route='Direct'})}
$selection=[IO.File]::ReadAllText($script:StatePath);$rules=[IO.File]::ReadAllText($rulesPath);$website=[IO.File]::ReadAllText($websitePath)
$script:tcpReads=0;$beforeProbes=$script:probes.Count;$fixed=Repair-NetworkDiagnosis $d.Revision
Check (-not $script:envs.HTTP_PROXY -and -not $script:envs.ALL_PROXY -and $script:envs.HTTPS_PROXY -ceq $originalEnvironment.HTTPS_PROXY -and $script:envs.NO_PROXY -ceq $originalEnvironment.NO_PROXY) 'environment-only repair clears only dead endpoints and preserves live variables and broad bypass byte-for-byte'
Check (($script:sys|ConvertTo-Json -Compress) -ceq $originalSystem -and [IO.File]::ReadAllText($script:StatePath) -ceq $selection -and [IO.File]::ReadAllText($rulesPath) -ceq $rules -and [IO.File]::ReadAllText($websitePath) -ceq $website) 'environment-only repair leaves system, selection, program and website canaries unchanged'
$backup=Get-Content -LiteralPath $fixed.Backup -Raw -Encoding UTF8|ConvertFrom-Json
Check ((Test-SameEnv $backup.Environment $originalEnvironment) -and $script:probes.Count -eq $beforeProbes -and $fixed.Diagnosis.Issues.Code -contains 'environment-bypass-all' -and $fixed.Message -match '不代表') 'cleanup has a recoverable complete backup, sends no requests, and retains bypass warning and acceptance limits'
# Races injected between preview and the final fresh listener observation.
foreach($race in @('port','unknown','tcp','guard','tun','environment','bypass','system','rules','selection','session')){
 $script:sys=$originalSystem|ConvertFrom-Json;$script:envs=$originalEnvironment|ConvertTo-Json|ConvertFrom-Json
 $script:ready=@(19002);$script:unknownOwner=@();$script:available=$true;$script:guard=$false;$script:tun=$false
 [IO.File]::WriteAllText($rulesPath,$rules);[IO.File]::WriteAllText($script:StatePath,$selection)
 if(Test-Path -LiteralPath (Get-IndependentSessionPath)){Remove-Item -LiteralPath (Get-IndependentSessionPath)}
 $script:freshRace='';$d=Get-NetworkDiagnosis;$script:tcpReads=0;$script:freshRace=$race;$beforeWrites=$script:writes;$failed=$false
 try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$failed=$true}
 Check ($failed -and $script:writes -eq $beforeWrites) ('fresh '+$race+' interference prevents environment cleanup without any setter')
 if($race -eq 'environment'){Check ($script:envs.HTTP_PROXY -eq 'http://127.0.0.1:19002') 'a newer live environment address survives the rejected cleanup'}
 if($race -eq 'bypass'){Check ($script:envs.NO_PROXY -eq 'external.local') 'a newer user bypass survives the rejected cleanup'}
}
$script:freshRace='';$script:tcpReads=0;$script:guard=$false;$script:tun=$false;$script:available=$true
if(Test-Path -LiteralPath (Get-IndependentSessionPath)){Remove-Item -LiteralPath (Get-IndependentSessionPath)}
$script:sys=$originalSystem|ConvertFrom-Json;$script:envs=$originalEnvironment|ConvertTo-Json|ConvertFrom-Json
$script:ready=@(19002);$script:unknownOwner=@(19002)
$d=Get-NetworkDiagnosis;$script:tcpReads=0;$fixed=Repair-NetworkDiagnosis $d.Revision
Check (-not $script:envs.HTTP_PROXY -and -not $script:envs.ALL_PROXY -and $script:envs.HTTPS_PROXY -ceq $originalEnvironment.HTTPS_PROXY -and $fixed.Diagnosis.Issues.Code -contains 'environment-entry-unknown') 'cleanup can remove proven dead variables while preserving an independent unknown listener variable'
foreach($control in @('guard','tun','session')){
 $script:envs=$originalEnvironment|ConvertTo-Json|ConvertFrom-Json;$script:unknownOwner=@();$script:guard=($control -eq 'guard');$script:tun=($control -eq 'tun')
 if($control -eq 'session'){Write-LocalJson (Get-IndependentSessionPath) @{OwnerPID=$PID;OwnerStart=(Get-ProcessStartTicks $PID);Started='active-env';TargetSystem=$script:sys}}
 $d=Get-NetworkDiagnosis;$beforeWrites=$script:writes;$failed=$false;try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$failed=$true}
 Check (-not $d.RepairAction -and $failed -and $script:writes -eq $beforeWrites) ('pre-existing '+$control+' refuses variable cleanup and does not compete for settings')
 if(Test-Path -LiteralPath (Get-IndependentSessionPath)){Remove-Item -LiteralPath (Get-IndependentSessionPath)}
}
$script:guard=$false;$script:tun=$false;$script:envs=$originalEnvironment|ConvertTo-Json|ConvertFrom-Json
$d=Get-NetworkDiagnosis;$script:tcpReads=0;$script:injectedEnvWrite=0
function Set-UserProxyEnv($Value,$ExpectedBefore){$script:injectedEnvWrite++;$script:writes++;$script:envs=$Value|ConvertTo-Json|ConvertFrom-Json;if($script:injectedEnvWrite -eq 1){$script:envs.HTTP_PROXY='http://127.0.0.1:19002'}}
$failed=$false;try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$failed=$true}
Check ($failed -and $script:injectedEnvWrite -eq 2 -and $script:envs.HTTP_PROXY -eq 'http://127.0.0.1:19002' -and $script:envs.ALL_PROXY -ceq $originalEnvironment.ALL_PROXY -and $script:envs.NO_PROXY -ceq $originalEnvironment.NO_PROXY -and [IO.File]::ReadAllText($script:StatePath) -ceq $selection) 'post-write external environment change survives actual transaction rollback while owned values and original selection are restored'
function Set-UserProxyEnv($Value,$ExpectedBefore){$script:writes++;$script:envs=$Value}
foreach($value in @('http://user:secret@localhost:19999','http://localhost:19999/path','http=127.0.0.1:19999;https=127.0.0.1:19003','http://proxy.example.invalid:19999')){
 $script:envs=[pscustomobject]@{HTTP_PROXY=$value;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='localhost'}
 $d=Get-NetworkDiagnosis -Probe
 Check (-not $d.RepairAction -and -not $d.EnvironmentEndpoints.Count -and $d.Message -notmatch 'secret|proxy.example|/path' -and $script:probes.Count -eq $beforeProbes) 'complex, remote and credential-bearing variables are neither probed, leaked nor offered cleanup'
}
$script:envs=[pscustomobject]@{HTTP_PROXY='http://localhost:19999';HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='localhost'}
$script:ready=@(19999);$script:unknownOwner=@(19999);$d=Get-NetworkDiagnosis
Check (-not $d.RepairAction -and $d.Issues.Code -contains 'environment-entry-unknown' -and $d.Issues.Code -notcontains 'environment-entry-down') 'unknown unregistered listener ownership never authorizes environment cleanup'
# Retain the real production setter's algorithm and replace only its OS adapter.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class FlowSwitchEnvironmentWriteRaceFixture {
 public static Dictionary<string,string> Values=new Dictionary<string,string>();
 public static List<string> Writes=new List<string>();
 public static string Trigger, Changed, External;
 public static bool Inject, RollbackRace;
 public static string GetEnvironmentVariable(string name,string target){return Values.ContainsKey(name)?Values[name]:null;}
 public static void SetEnvironmentVariable(string name,string value,string target){
  // PowerShell 5.1 may bind $null to an empty .NET string; Windows removes both.
  if(value=="") value=null;
  Values[name]=value;Writes.Add(name);
  if(Inject && name==Trigger && value==null){Inject=false;Values[Changed]=External;}
  if(RollbackRace && name=="HTTP_PROXY" && value=="http://127.0.0.1:19999"){
   RollbackRace=false;Values["HTTPS_PROXY"]="http://127.0.0.1:19004";
  }
 }
}
'@
$tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'ProxyBackend.ps1'),[ref]$tokens,[ref]$parseErrors)
$setter=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-UserProxyEnv'},$true)
. ([scriptblock]::Create($setter.Extent.Text.Replace('[Environment]','[FlowSwitchEnvironmentWriteRaceFixture]')))
function Get-UserProxyEnv {
 $values=[ordered]@{};foreach($name in $script:ProxyNames){$values[$name]=[FlowSwitchEnvironmentWriteRaceFixture]::GetEnvironmentVariable($name,'User')};[pscustomobject]$values
}
function Reset-UserEnvironmentWriteFixture {
 [FlowSwitchEnvironmentWriteRaceFixture]::Values.Clear();[FlowSwitchEnvironmentWriteRaceFixture]::Writes.Clear()
 foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){[FlowSwitchEnvironmentWriteRaceFixture]::Values[$name]='http://127.0.0.1:19999'}
 [FlowSwitchEnvironmentWriteRaceFixture]::Values['NO_PROXY']='custom.local, *'
 [FlowSwitchEnvironmentWriteRaceFixture]::Inject=$false;[FlowSwitchEnvironmentWriteRaceFixture]::RollbackRace=$false
}
$script:ready=@(19002);$script:unknownOwner=@();$script:guard=$false;$script:tun=$false;$script:available=$true;$script:freshRace=''
$script:sys=$originalSystem|ConvertFrom-Json
foreach($race in @(@('HTTP_PROXY','ALL_PROXY','http://127.0.0.1:19002'),@('HTTP_PROXY','HTTPS_PROXY','http://127.0.0.1:19002'),@('HTTPS_PROXY','NO_PROXY','external.local'))){
 Reset-UserEnvironmentWriteFixture
 $d=Get-NetworkDiagnosis;$script:tcpReads=0
 [FlowSwitchEnvironmentWriteRaceFixture]::Trigger=$race[0];[FlowSwitchEnvironmentWriteRaceFixture]::Changed=$race[1];[FlowSwitchEnvironmentWriteRaceFixture]::External=$race[2];[FlowSwitchEnvironmentWriteRaceFixture]::Inject=$true
 $failed=$false;try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$failed=$true}
 $after=Get-UserProxyEnv
 Check ($failed -and [string]$after.($race[1]) -ceq $race[2]) ('real setter preserves external '+$race[1]+' changed during the earlier '+$race[0]+' field write')
 $restored=$true;foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){if($name -ne $race[1] -and $after.$name -cne 'http://127.0.0.1:19999'){$restored=$false}}
 Check ($restored -and ($script:sys|ConvertTo-Json -Compress) -ceq $originalSystem -and [IO.File]::ReadAllText($script:StatePath) -ceq $selection) 'actual multi-field setter conflict restores owned earlier fields and preserves system and selection'
}
Reset-UserEnvironmentWriteFixture
$d=Get-NetworkDiagnosis;$script:tcpReads=0
[FlowSwitchEnvironmentWriteRaceFixture]::Trigger='HTTP_PROXY';[FlowSwitchEnvironmentWriteRaceFixture]::Changed='ALL_PROXY';[FlowSwitchEnvironmentWriteRaceFixture]::External='http://127.0.0.1:19002';[FlowSwitchEnvironmentWriteRaceFixture]::Inject=$true;[FlowSwitchEnvironmentWriteRaceFixture]::RollbackRace=$true
$message='';try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$message=$_.Exception.Message}
$after=Get-UserProxyEnv
Check ($message -match '回滚未完成' -and $after.HTTP_PROXY -eq 'http://127.0.0.1:19999' -and $after.HTTPS_PROXY -eq 'http://127.0.0.1:19004' -and $after.ALL_PROXY -eq 'http://127.0.0.1:19002') 'a second external field change during actual rollback is preserved and reported as incomplete recovery'
Reset-UserEnvironmentWriteFixture
$d=Get-NetworkDiagnosis;$script:tcpReads=0;$fixed=Repair-NetworkDiagnosis $d.Revision
$after=Get-UserProxyEnv
Check (-not $after.HTTP_PROXY -and -not $after.HTTPS_PROXY -and -not $after.ALL_PROXY -and $after.NO_PROXY -ceq 'custom.local, *' -and [FlowSwitchEnvironmentWriteRaceFixture]::Writes.Count -eq 3 -and (Test-Path $fixed.Backup)) 'actual setter still completes ordinary cleanup without rewriting unchanged NO_PROXY'
Reset-UserEnvironmentWriteFixture
$expected=Get-UserProxyEnv;$target=[pscustomobject]@{HTTP_PROXY=$null;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY=$expected.NO_PROXY}
[FlowSwitchEnvironmentWriteRaceFixture]::Values['HTTP_PROXY']='http://127.0.0.1:19002'
$failed=$false;try{Set-UserProxyEnv $target -ExpectedBefore $expected}catch{$failed=$true}
Check ($failed -and [FlowSwitchEnvironmentWriteRaceFixture]::Writes.Count -eq 0 -and [FlowSwitchEnvironmentWriteRaceFixture]::Values['HTTP_PROXY'] -eq 'http://127.0.0.1:19002') 'direct setter validates explicit expected ownership before its first differing write'
Reset-UserEnvironmentWriteFixture
[FlowSwitchEnvironmentWriteRaceFixture]::Trigger='HTTP_PROXY';[FlowSwitchEnvironmentWriteRaceFixture]::Changed='ALL_PROXY';[FlowSwitchEnvironmentWriteRaceFixture]::External='http://127.0.0.1:19002';[FlowSwitchEnvironmentWriteRaceFixture]::Inject=$true
$failed=$false;try{Set-UserProxyEnv $target}catch{$failed=$true}
Check ($failed -and [FlowSwitchEnvironmentWriteRaceFixture]::Values['ALL_PROXY'] -eq 'http://127.0.0.1:19002') 'legacy setter call captures expected before state and does not leave the whole batch unguarded'
Write-Output ('PASS: '+$script:checks+' dead-entry repair checks; isolated settings only.')

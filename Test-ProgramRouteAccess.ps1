$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-route-access-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
. (Join-Path $PSScriptRoot 'ProgramRouteAccess.ps1')
. (Join-Path $PSScriptRoot 'ProgramFamilyTracking.ps1')
$script:checks=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Throws([scriptblock]$Action,[string]$Pattern){$message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message};Check ($message -match $Pattern) ('Expected '+$Pattern+', got '+$message)}
function Use-ChangeLock([scriptblock]$Action){& $Action}
function Get-SystemSnapshot {Copy-RoutingSnapshot $script:Windows}
function Get-UserProxyEnv {Copy-RoutingSnapshot $script:UserEnv}
function Set-SystemSnapshot($Value){
 $script:NativeWrites++
 if($script:ExternalNative){$script:ExternalNative=$false;$script:Windows=[pscustomobject]@{Flags=3;Server='127.0.0.1:19999';Bypass='outside'};return}
 if($script:RollbackNativeFail -and $Value.Server -eq '127.0.0.1:57777'){throw 'Synthetic restore failed'}
 $script:Windows=Copy-RoutingSnapshot $Value
 if($script:FailAfterNative){$script:FailAfterNative=$false;$script:UserEnv.HTTP_PROXY='http://127.0.0.1:19999';if($script:OutsideAfterNative){[IO.File]::AppendAllText((Get-IndependentSessionPath),' ')}}
}
function Set-UserProxyEnv($Value,$ExpectedBefore=$null){
 Check (Test-SameEnv $ExpectedBefore $script:UserEnv) 'Environment write binds a fresh expected snapshot'
 $script:EnvWrites++;$script:UserEnv=Copy-RoutingSnapshot $Value
}
function Get-ClientInterference {[pscustomobject]@{Tun=$script:Tun;Guard=$script:Guard;SystemProxy=$true}}
function Get-RecoveryOwnerState($Session){if($script:OwnerUnknown){return 'unknown'};'alive'}
function Test-SessionProcess {return (-not $script:CoreUnknown)}
function Get-GatewayLifecycle {[pscustomobject]@{supervisor=888;phase=$(if($script:Stopped){'stopped'}else{'ready'});attempt=0;updatedAt=[DateTime]::UtcNow.ToString('o')}}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=(-not $script:UnknownTcp);Rows=@([pscustomobject]@{State='Listen';LocalAddress='127.0.0.1';LocalPort=18790;OwningProcess=999})}}
function Get-Listener {if(-not $script:PortUnknown){[pscustomobject]@{PID=999;Name='test-core'}}}
function Test-ProxyRoute {param($Key,[switch]$Fast);$script:Probes++;if($script:MemberDuringProbe){$script:MemberDuringProbe=$false;$script:Rows[1].StartTime=$birth.AddSeconds(40)};[pscustomobject]@{Usable=(-not $script:ProbeFail)}}
function Get-ProcessInventory {if($script:InventoryFail){throw 'Synthetic inventory unavailable'};@($script:Rows)}
function Ensure-ManagedGateway {throw 'Must not start or migrate service'}
function Install-ProgramProxyShortcut {throw 'Must not bind launcher'}
$script:Profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(
 @{Id='gateway';Name='Gateway';Protocol='http';Host='127.0.0.1';Port=18790;CorePath='C:\Test\core.exe'},
 @{Id='a';Name='A';Protocol='http';Host='127.0.0.1';Port=18791},
 @{Id='b';Name='B';Protocol='http';Host='127.0.0.1';Port=18792},
 @{Id='vpn';Name='365';Protocol='http';Host='127.0.0.1';Port=57777}
 );Routing=@{Adapter='standalone';ProfileId='gateway';UnifiedMode='gateway'}})
$script:StateFile=Join-Path $qa 'app-rules.json'
function Invoke-AppRouter($Request,[int]$TimeoutMilliseconds=55000){
 $state=Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8|ConvertFrom-Json
 if($Request.action -eq 'replace'){
  Check ($Request.expectedStateHash -ceq (Read-RuleMaintenanceFile $script:StateFile).TextHash) 'Rules replace binds exact prior state bytes'
  if($script:RejectCas){throw 'Synthetic CAS conflict'}
  $script:Replaces++;$script:LastRequest=$Request
  $state.entries=@($Request.entries);$state.defaultRoute=$Request.defaultRoute
  foreach($field in @('programIngresses','siteRules')){if($Request.ContainsKey($field)){$state.$field=@($Request[$field])}}
  Write-LocalJson $script:StateFile $state
  if($script:MemberDuringLoad){$script:MemberDuringLoad=$false;$script:Rows[1].StartTime=$birth.AddSeconds(45)}
  if($script:TunDuringLoad){$script:TunDuringLoad=$false;$script:Tun=$true}
  return [pscustomobject]@{ok=$true;stateHash=(Read-RuleMaintenanceFile $script:StateFile).TextHash}
 }
 $entries=@($state.entries|ForEach-Object {$entry=Copy-RoutingSnapshot $_;$entry|Add-Member NoteProperty loaded (-not ($script:RejectLoad -and $script:Replaces -gt 0));$entry|Add-Member NoteProperty effectiveRoute $(if($script:EntryBlocked -and $script:Replaces -gt 0){'Blocked'}else{$entry.route});$entry})
 [pscustomobject]@{available=(-not $script:Offline);mode='rule';rulesAvailable=$true;defaultLoaded=$true;defaultRoute=$state.defaultRoute;effectiveDefaultRoute=$(if($script:BlockedDefault){'Blocked'}else{'b'});entries=$entries;programIngresses=$state.programIngresses;siteRulesLoaded=(-not $script:SiteUnknown)}
}
$install=Join-Path $qa 'game';[void][IO.Directory]::CreateDirectory($install)
$app=Join-Path $install 'Game.exe';$worker=Join-Path $install 'QtWebEngineProcess.exe';$conflict=Join-Path $install 'Helper.exe';$other=Join-Path $qa 'Other.exe'
foreach($path in @($app,$worker,$conflict,$other)){[IO.File]::WriteAllText($path,('fixture '+$path))}
$app,$worker,$conflict,$other=@(@($app,$worker,$conflict,$other)|ForEach-Object {(Get-ProgramIdentityDescriptor $_ (New-ProgramIdentityContext -Packages @())).CanonicalPath})
$birth=[DateTime]::UtcNow.AddMinutes(-1)
function Row([int]$Id,[int]$Parent,[string]$Path,[int]$Age=0){[pscustomobject]@{Id=$Id;ParentId=$Parent;Path=$Path;PathStatus='Available';ProcessName=[IO.Path]::GetFileNameWithoutExtension($Path);StartTime=$birth.AddSeconds($Age)}}
function Reset-Fixture {
 [LocalProxySwitch.ProgramFamilyTracker]::Clear((Get-ProgramFamilyTrackingScope $app))
 $script:Rows=@((Row 100 1 $app),(Row 101 100 $worker 1),(Row 102 100 $conflict 2))
 $script:Windows=[pscustomobject]@{Flags=3;Server='127.0.0.1:57777';Bypass='external-bypass'}
 $script:UserEnv=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:57777';HTTPS_PROXY='http://127.0.0.1:57777';ALL_PROXY='http://127.0.0.1:57777';NO_PROXY='external-no-proxy'}
 $targetSystem=[pscustomobject]@{Flags=3;Server='127.0.0.1:18790';Bypass='old-bypass'}
 $targetEnv=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:18790';HTTPS_PROXY='http://127.0.0.1:18790';ALL_PROXY='http://127.0.0.1:18790';NO_PROXY='old-no-proxy'}
 Write-LocalJson (Get-IndependentSessionPath) ([pscustomobject]@{Version=1;Started='test-session';OwnerPID=777;OwnerStart='1';SupervisorPID=888;SupervisorStart='2';CorePID=999;CoreStart='3';BeforeSystem=[pscustomobject]@{Flags=1;Server='';Bypass='original-bypass'};BeforeEnv=[pscustomobject]@{HTTP_PROXY=$null;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='original-no-proxy'};TargetSystem=$targetSystem;TargetEnv=$targetEnv})
 Write-LocalJson (Join-Path $qa 'gateway\process.json') @{supervisor=888;supervisorStartTicks='2';core=999;coreStartTicks='3'}
 Write-LocalJson $script:ConfigPath $script:Profiles
 Write-LocalJson $script:StateFile @{version=3;installed=$true;entries=@(@{path=$app;route='Direct'},@{path=$conflict;route='b'});defaultRoute='a';programIngresses=@(@{id=('1'*32);path=$other;port=19080;route='b'});siteRules=@(@{id=('2'*32);scope='global';type='domain';domain='example.com';route='b'})}
 Write-LocalJson (Join-Path $qa 'program-proxies.json') @{version=1;entries=@(@{path=$other;route='b';adapter='chromium'})}
 Save-Selection ([pscustomobject]@{Key='gateway';NetworkKey='a';Note='preserve bytes'})
 $script:Replaces=0;$script:NativeWrites=0;$script:EnvWrites=0;$script:Probes=0
 foreach($name in @('Tun','Guard','Stopped','UnknownTcp','PortUnknown','OwnerUnknown','InventoryFail','ProbeFail','MemberDuringProbe','MemberDuringLoad','TunDuringLoad','CoreUnknown','RejectCas','RejectLoad','Offline','BlockedDefault','EntryBlocked','SiteUnknown','ExternalNative','RollbackNativeFail','FailAfterNative','OutsideAfterNative')){Set-Variable -Name $name -Value $false -Scope Script}
}
Reset-Fixture
$revision=Get-NetworkRepairRevision (Get-SystemSnapshot) (Get-UserProxyEnv);$plan=Get-ProgramRouteAccessPlan $app 'Direct'
Check $plan.CanApply ('Ready standalone preview allowed: '+$plan.BlockedReason)
Check ($plan.SystemNeedsAccess -and $plan.EnvironmentNeedsAccess -and $plan.EffectiveDefaultRoute -eq 'b') 'Preview discloses global access and actual backup B'
Check (($plan.FamilyPlan.Members|Where-Object Path -eq $app).DisplayAction -eq '所选程序将修改' -and $plan.FamilyPlan.ConflictCount -eq 1) 'Root explicit action is separate from preserved child conflict count'
Check ($script:NativeWrites -eq 0 -and $script:EnvWrites -eq 0 -and $script:Replaces -eq 0 -and $script:Probes -eq 0) 'Preview has no writes, service starts or external probes'
Check ($revision -ceq (Get-NetworkRepairRevision (Get-SystemSnapshot) (Get-UserProxyEnv))) 'Preview leaves every bound setting unchanged'
Throws {Set-ProgramRouteAccess $plan} '确认'
$selection=(Read-RuleMaintenanceFile $script:StatePath).Hash;$before=Get-RoutingSnapshot
$result=Set-ProgramRouteAccess $plan -Confirmed;$after=Get-RoutingSnapshot
Check ($script:Replaces -eq 1 -and $result.AddedCount -eq 1 -and $script:Probes -eq 0) 'Direct plus missing child in one rules transaction without foreign-site gating'
Check ($script:Windows.Server -eq '127.0.0.1:18790' -and $script:UserEnv.HTTP_PROXY -eq 'http://127.0.0.1:18790') '365 access explicitly returns to flow'
Check (($after.entries|Where-Object path -eq $worker).route -eq 'Direct' -and ($after.entries|Where-Object path -eq $conflict).route -eq 'b') 'Verified Qt child gains Direct; conflicting helper retains B'
Check ($after.defaultRoute -eq 'a' -and $after.programIngresses[0].route -eq 'b' -and $after.siteRules[0].route -eq 'b' -and $after.launchEntries[0].route -eq 'b') 'Default preference, other ingress, sites and launch modes retained'
Check ((Read-RuleMaintenanceFile $script:StatePath).Hash -ceq $selection) 'Selection byte image preserved'
Check (-not $script:LastRequest.resetDefaultSelection -and -not $script:LastRequest.ContainsKey('resetIngressSelections')) 'No unrelated default or program selector reset'
$claim=(Get-ProgramRouteAccessSession).Session
Check ($claim.BeforeSystem.Server -eq '127.0.0.1:57777' -and $claim.BeforeEnv.NO_PROXY -eq 'external-no-proxy' -and $claim.TargetSystem.Bypass -eq 'external-bypass') 'Renewed recovery ownership captures true outside baseline and target bypass'
function Get-RecoveryEndpointState {return 'alive'}
$exit=New-ExitRecoveryPlan $claim $script:Windows $script:UserEnv
Check ($exit.System.Server -eq '127.0.0.1:57777' -and $exit.Environment.NO_PROXY -eq 'external-no-proxy') 'Exit restores new 365 baseline and external NO_PROXY, never stale session targets'
Check ($result.Message -match '未验证登录' -and (Test-Path -LiteralPath $result.Backup)) 'Success includes login boundary and a private rollback backup'
Throws {Set-ProgramRouteAccess $plan -Confirmed} '已改变'

Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Follow';Check ($plan.FamilyPlan.MissingCount -eq 0 -and ($plan.FamilyPlan.Members|Where-Object Path -eq $worker).DisplayAction -eq '保留现状') 'Follow display never promises child Direct repair';Set-ProgramRouteAccess $plan -Confirmed|Out-Null
Check (@((Get-RoutingSnapshot).entries|Where-Object path -eq $app).Count -eq 0) 'Follow removes only root dedicated path'
Check (@((Get-RoutingSnapshot).entries|Where-Object path -eq $worker).Count -eq 0 -and ((Get-RoutingSnapshot).entries|Where-Object path -eq $conflict).route -eq 'b') 'Follow does not invent child Follow/Direct rules or clear a conflict'
Reset-Fixture;$script:Rows[1].StartTime=[DateTime]::MinValue;$plan=Get-ProgramRouteAccessPlan $app 'Direct';Set-ProgramRouteAccess $plan -Confirmed|Out-Null
Check (@((Get-RoutingSnapshot).entries|Where-Object path -eq $worker).Count -eq 0) 'Unknown child evidence never grants mutation'

foreach($flag in @('Tun','Guard','Stopped','UnknownTcp','PortUnknown','OwnerUnknown','InventoryFail','Offline','CoreUnknown')){
 Reset-Fixture;Set-Variable -Name $flag -Value $true -Scope Script;$plan=Get-ProgramRouteAccessPlan $app 'Direct'
 Check (-not $plan.CanApply -and $plan.BlockedReason) ($flag+' blocks unsupported or unknown observation')
 Throws {Set-ProgramRouteAccess $plan -Confirmed} '未|无法|改变|失败|开启'
 Check ($script:Replaces -eq 0 -and $script:NativeWrites -eq 0 -and $script:EnvWrites -eq 0) ($flag+' refusal leaves Windows and rules untouched')
}
Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Direct';$plan.CreatedAt=[DateTime]::UtcNow.AddMinutes(-3).ToString('o');Throws {Set-ProgramRouteAccess $plan -Confirmed} '过期'
Reset-Fixture;$script:Windows=[pscustomobject]@{Flags=11;Server='localhost:18790';Bypass='outside'};Check (-not (Get-ProgramRouteAccessPlan $app 'Direct').CanApply) 'Own entry with mixed PAC flags refuses unsafe pre-write recovery ownership'
Reset-Fixture;$script:Windows.Flags=13;$plan=Get-ProgramRouteAccessPlan $app 'Direct';Check ($plan.CanApply -and $plan.Impact -match 'PAC/自动检测') 'External PAC mode explicitly shows its transition to manual flow access'
Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Direct';$script:Windows.Bypass='changed';Throws {Set-ProgramRouteAccess $plan -Confirmed} '已改变'
Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Direct';$script:Rows[1].StartTime=$birth.AddSeconds(40);Throws {Set-ProgramRouteAccess $plan -Confirmed} '成员或文件身份'
Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'a';$script:MemberDuringProbe=$true;Throws {Set-ProgramRouteAccess $plan -Confirmed} '成员或文件身份'
Reset-Fixture;$script:BlockedDefault=$true;$plan=Get-ProgramRouteAccessPlan $app 'Direct';Check ($plan.CanApply -and $plan.Impact -match '默认代理出口已暂停') 'Explicit Direct remains usable while default is blocked, with honest scope'
$result=Set-ProgramRouteAccess $plan -Confirmed;Check ($result.EffectiveDefaultRoute -eq 'Blocked' -and $result.Message -match '其他跟随程序尚未恢复' -and (Get-RoutingSnapshot).defaultRoute -eq 'a') 'Direct application preserves blocked default and refuses broad recovery claims'
Check (-not (Get-ProgramRouteAccessPlan $app 'Follow').CanApply) 'Follow cannot route to a blocked default'
Reset-Fixture;$script:BlockedDefault=$true;$plan=Get-ProgramRouteAccessPlan $app 'b';Check $plan.CanApply 'Independent proxy B can be previewed despite blocked default A'
$result=Set-ProgramRouteAccess $plan -Confirmed;Check ($script:Probes -eq 1 -and ((Get-RoutingSnapshot).entries|Where-Object path -eq $app).route -eq 'b' -and (Get-RoutingSnapshot).defaultRoute -eq 'a') 'Healthy B explicit line works without repairing or resetting the blocked default'
Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'b';$before=Get-RoutingSnapshot;$script:EntryBlocked=$true;Throws {Set-ProgramRouteAccess $plan -Confirmed} '程序实际出口尚未就绪'
Check (Test-SameRouting $before (Get-RoutingSnapshot)) 'Loaded but blocked actual program exit refuses and rolls its path rule back'
Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Direct';$state=Get-RoutingSnapshot;$script:TunDuringLoad=$true;Throws {Set-ProgramRouteAccess $plan -Confirmed} '检查期间.*TUN'
Check ($script:NativeWrites -eq 0 -and $script:EnvWrites -eq 0 -and (Test-SameRouting $state (Get-RoutingSnapshot))) 'TUN enabled during reload refuses before native writes and restores rules'
Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Direct';$state=Get-RoutingSnapshot;$script:MemberDuringLoad=$true;Throws {Set-ProgramRouteAccess $plan -Confirmed} '载入期间进程成员'
Check (Test-SameRouting $state (Get-RoutingSnapshot)) 'Family replacement during controller reload rolls rules back before native writes'
Check ($script:NativeWrites -eq 0 -and $script:EnvWrites -eq 0) 'Slow reload cannot apply stale process authorization to Windows access'
Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'a';$script:ProbeFail=$true;Throws {Set-ProgramRouteAccess $plan -Confirmed} '目标代理检测未通过'
Check ($script:Replaces -eq 0 -and $script:NativeWrites -eq 0) 'Failed upstream preserves network and rules'
Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Direct';$state=Get-RoutingSnapshot;$script:RejectCas=$true;Throws {Set-ProgramRouteAccess $plan -Confirmed} 'CAS conflict'
Check (Test-SameRouting $state (Get-RoutingSnapshot)) 'CAS refusal preserves complete routing'
foreach($failure in @('RejectLoad','SiteUnknown','ExternalNative')){
 Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Direct';$state=Get-RoutingSnapshot;$originalSession=(Read-RuleMaintenanceFile (Get-IndependentSessionPath)).Hash
 Set-Variable -Name $failure -Value $true -Scope Script
 Throws {Set-ProgramRouteAccess $plan -Confirmed} '未载入|网站规则|写入后校验失败'
 Check (Test-SameRouting $state (Get-RoutingSnapshot)) ($failure+' rolls routing back')
 if($failure -eq 'ExternalNative'){
  Check ($script:Windows.Server -eq '127.0.0.1:19999') 'Outside system change survives rollback'
  Check ((Get-ProgramRouteAccessSession).Session.BeforeSystem.Server -eq '127.0.0.1:57777') 'Prepared recovery claim remains with an honest outside baseline after external native change'
 }else{Check ((Read-RuleMaintenanceFile (Get-IndependentSessionPath)).Hash -ceq $originalSession) ($failure+' never falsely claims session ownership')}
}

$realWriter=(Get-Item Function:Set-RuleMaintenanceFile).ScriptBlock
try{
 function Set-RuleMaintenanceFile($Original,[byte[]]$Bytes,[bool]$Remove){
  if($Original.Path -eq (Get-IndependentSessionPath)){
   if($script:FailSessionWrite){throw 'Synthetic session commit failure'}
   if($script:OutsideSession){$script:OutsideSession=$false;[IO.File]::AppendAllText($Original.Path,' ')}
  }
  & $realWriter $Original $Bytes $Remove
  if($Original.Path -eq (Get-IndependentSessionPath) -and $script:FailAfterClaim){
   $script:FailAfterClaim=$false
   if($script:OutsideAfterClaim){[IO.File]::AppendAllText($Original.Path,' ')}
   $script:UserEnv.HTTP_PROXY='http://127.0.0.1:19999'
  }
 }
 foreach($flag in @('FailSessionWrite','OutsideSession')){
  Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Direct';$state=Get-RoutingSnapshot;Set-Variable -Name $flag -Value $true -Scope Script
  Throws {Set-ProgramRouteAccess $plan -Confirmed} 'session commit failure|changed'
  Check ($script:Windows.Server -eq '127.0.0.1:57777' -and (Test-SameRouting $state (Get-RoutingSnapshot))) ($flag+' record failure rolls network and rules back')
  Set-Variable -Name $flag -Value $false -Scope Script
 }
 Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Direct';$state=Get-RoutingSnapshot;$script:FailAfterNative=$true;$script:OutsideAfterNative=$true
 Throws {Set-ProgramRouteAccess $plan -Confirmed} '外部再次修改入口|归属记录写后核验失败|写入后校验失败'
 Check ($script:UserEnv.HTTP_PROXY -eq 'http://127.0.0.1:19999' -and (Test-SameRouting $state (Get-RoutingSnapshot))) 'Post-claim outside environment survives rollback with routing restored'
 Check ([IO.File]::ReadAllText((Get-IndependentSessionPath)).EndsWith(' ')) 'Outside session rewrite is preserved after post-claim failure'
 $script:OutsideAfterClaim=$false
 Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Direct';$script:FailAfterNative=$true;$script:RollbackNativeFail=$true
 Throws {Set-ProgramRouteAccess $plan -Confirmed} '回滚未完成'
 Check ($script:Windows.Server -eq '127.0.0.1:18790' -and (Get-ProgramRouteAccessSession).Session.TargetSystem.Bypass -eq 'external-bypass') 'Partial native rollback retains new recovery claim for still-live flow reference'
}finally{Set-Item Function:Set-RuleMaintenanceFile $realWriter}

Reset-Fixture;$original=(Get-ProgramRouteAccessSession).Session
$same=[pscustomobject]@{Flags=11;Server='localhost:18790';Bypass='outside-new-bypass'}
$vars=Copy-RoutingSnapshot $original.TargetEnv;$vars.HTTP_PROXY='http://localhost:18790';$vars.NO_PROXY='outside-new-no-proxy'
$new=New-ProgramRouteAccessSession $original $same $vars ([pscustomobject]@{Flags=3;Server='127.0.0.1:18790';Bypass=$same.Bypass}) (New-EnvTarget $vars 'gateway')
Check ($new.BeforeSystem.Flags -eq 9 -and $new.BeforeSystem.Server -eq '' -and $new.BeforeSystem.Bypass -eq 'outside-new-bypass') 'Semantic own alias retains external PAC bits and bypass while restoring original manual bit'
Check ($null -eq $new.BeforeEnv.HTTP_PROXY -and $new.BeforeEnv.NO_PROXY -eq 'outside-new-no-proxy') 'Own localhost alias retains original variable baseline and external NO_PROXY'
$inactive=[pscustomobject]@{Flags=1;Server='127.0.0.1:18790';Bypass='inactive'}
$new=New-ProgramRouteAccessSession $original $inactive $vars $same $vars
Check ($new.BeforeSystem.Server -eq '127.0.0.1:18790' -and $new.BeforeSystem.Flags -eq 1) 'Inactive manual server is not treated as a current own reference'
Reset-Fixture;$original=(Get-ProgramRouteAccessSession).Session;$current=[pscustomobject]@{Flags=3;Server='localhost:18790';Bypass='outside-own-bypass'}
$vars=Copy-RoutingSnapshot $original.TargetEnv;$vars.HTTP_PROXY='http://localhost:18790';$vars.NO_PROXY='outside-own-no-proxy'
$targets=New-ProgramRouteAccessTargets $current $vars 'gateway';$prepared=New-ProgramRouteAccessSession $original $current $vars $targets.System $targets.Environment
$restore=New-ExitRecoveryPlan $prepared $current $vars
Assert-IndependentStopUnreferenced $restore.System $restore.Environment @('127.0.0.1:18790')
Check ($restore.System.Flags -eq 1 -and $restore.System.Bypass -eq 'outside-own-bypass' -and $restore.Environment.NO_PROXY -eq 'outside-own-no-proxy') 'Prepared-only recovery safely clears own aliases while retaining external bypass fields'
Check ($targets.System.Server -eq 'localhost:18790' -and $targets.Environment.HTTP_PROXY -eq 'http://localhost:18790') 'Already verified own alias spellings remain unchanged in native targets'
Reset-Fixture;$script:UserEnv.HTTP_PROXY='http://[::1]:18790';Check (-not (Get-ProgramRouteAccessPlan $app 'Direct').CanApply) 'Unproven IPv6 own alias blocks unsafe claim instead of guessing a dual-stack listener'
Reset-Fixture;$plan=Get-ProgramRouteAccessPlan $app 'Direct';$script:Profiles.Routing.Adapter='other';$unsupported=Get-ProgramRouteAccessPlan $app 'Direct'
Check (-not $unsupported.CanApply) 'Unsupported mode is blocked without migration'
$script:Profiles.Routing.Adapter='standalone'
Reset-Fixture;$state=Get-Content $script:StateFile -Raw -Encoding UTF8|ConvertFrom-Json;$state.programIngresses+=@([pscustomobject]@{id=('3'*32);path=$app;port=19081;route='b'});Write-LocalJson $script:StateFile $state
Check (-not (Get-ProgramRouteAccessPlan $app 'Direct').CanApply) 'Existing managed root is not converted into engine path mode'
Write-Output ('PASS: '+$script:checks+' program route access checks; real file identity/family/CAS, isolated state and Windows writes stubbed. No real game login or third-party tunnel acceptance.')

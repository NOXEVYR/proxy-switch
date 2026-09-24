$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-family-rules-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
. (Join-Path $PSScriptRoot 'ProgramFamilyRouting.ps1')
. (Join-Path $PSScriptRoot 'ProgramFamilyTracking.ps1')
$script:checks=0;$script:Replaces=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Throws([scriptblock]$Action,[string]$Pattern){$message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message};Check ($message -match $Pattern) ('Expected '+$Pattern+', got '+$message)}
function Use-ChangeLock([scriptblock]$Action){& $Action}
function Get-SystemSnapshot {[pscustomobject]@{Flags=3;Server='127.0.0.1:18790';Bypass='localhost'}}
function Get-UserProxyEnv {[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:18790';HTTPS_PROXY='http://127.0.0.1:18790';ALL_PROXY='http://127.0.0.1:18790';NO_PROXY='localhost'}}
function Set-SystemSnapshot {throw 'Must not change Windows'}
function Set-UserProxyEnv {throw 'Must not change Windows'}
function Ensure-ManagedGateway {throw 'Must not start or migrate a gateway'}
function Install-ProgramProxyShortcut {throw 'Must not change launchers'}
function Test-ProxyRoute {param($Key,[switch]$Fast);[pscustomobject]@{Usable=(-not $script:RejectProbe)}}
function Get-ProcessInventory {if($script:FailObservation){throw 'Synthetic unavailable inventory'};@($script:Rows)}
$script:Profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(
 @{Id='gateway';Name='Gateway';Protocol='http';Host='127.0.0.1';Port=18790;CorePath='C:\Test\core.exe'},
 @{Id='a';Name='A';Protocol='http';Host='127.0.0.1';Port=18791},
 @{Id='b';Name='B';Protocol='http';Host='127.0.0.1';Port=18792}
);Routing=@{Adapter='standalone';ProfileId='gateway';UnifiedMode='gateway'}})
Write-LocalJson $script:ConfigPath $script:Profiles
$script:StateFile=Join-Path $qa 'app-rules.json'
function Invoke-AppRouter($Request,[int]$TimeoutMilliseconds=55000){
 $state=Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8|ConvertFrom-Json
 if($Request.action -eq 'replace'){
  Check ($Request.expectedStateHash -ceq (Read-RuleMaintenanceFile $script:StateFile).TextHash) 'Batch mutation binds to exact prior engine bytes'
  if($script:RejectCas){$script:RejectCas=$false;throw 'Synthetic CAS conflict'}
  $script:Replaces++;$script:LastRequest=$Request
  if($script:ConcurrentLaunchEdit){
   $script:ConcurrentLaunchEdit=$false
   Write-LocalJson (Join-Path $qa 'program-proxies.json') @{version=1;entries=@(@{path=$unrelated;route='a';adapter='chromium'})}
  }
  $state.entries=@($Request.entries);$state.defaultRoute=$Request.defaultRoute
  foreach($field in @('programIngresses','siteRules')){if($Request.ContainsKey($field)){$state.$field=@($Request[$field])}}
  Write-LocalJson $script:StateFile $state
  return [pscustomobject]@{ok=$true;stateHash=(Read-RuleMaintenanceFile $script:StateFile).TextHash}
 }
 if($script:ChangeDuringCheck){$script:ChangeDuringCheck=$false;$script:Rows=@($script:Rows|Where-Object Id -ne 102)}
 $entries=@($state.entries|ForEach-Object {$entry=Copy-RoutingSnapshot $_;$entry|Add-Member NoteProperty loaded (-not $script:RejectReadback);$entry})
 [pscustomobject]@{available=(-not $script:Offline);mode='rule';rulesAvailable=$true;defaultLoaded=$true;entries=$entries;programIngresses=$state.programIngresses;siteRulesLoaded=$true}
}
$install=Join-Path $qa 'game';$childDirectory=Join-Path $install 'login';$external=Join-Path $qa 'other-install'
foreach($directory in @($install,$childDirectory,$external)){[void][IO.Directory]::CreateDirectory($directory)}
$app=Join-Path $install 'Game.exe';$worker=Join-Path $childDirectory 'QtWebEngineProcess.exe';$conflict=Join-Path $install 'Helper.exe';$unrelated=Join-Path $install 'Unused.exe';$outside=Join-Path $external 'QtWebEngineProcess.exe';$second=Join-Path $childDirectory 'worker.exe'
foreach($path in @($app,$worker,$conflict,$unrelated,$outside,$second)){[IO.File]::WriteAllText($path,('identity fixture '+$path))}
# Hosted runners can expose TEMP through an 8.3 alias such as RUNNER~1. The
# production preview deliberately treats saved alias paths as conflicts. This
# fixture tests normal coverage, so its process rows and saved records must use
# the actual file paths returned by the same OS identity reader.
$fixtureAliasCount=0
$app,$worker,$conflict,$unrelated,$outside,$second=@(@($app,$worker,$conflict,$unrelated,$outside,$second)|ForEach-Object {
    $identity=Get-ProgramIdentityDescriptor $_ (New-ProgramIdentityContext -Packages @())
    if(-not $identity.Exists -or -not $identity.FileId -or -not $identity.CanonicalPath){throw 'Fixture executable identity could not be verified.'}
    if($_ -ine $identity.CanonicalPath){$fixtureAliasCount++}
    $identity.CanonicalPath
})
$birth=[DateTime]::UtcNow.AddMinutes(-1)
function ProcessRow([int]$Id,[int]$ParentId,[string]$Path,[int]$Age=0){[pscustomobject]@{Id=$Id;ParentId=$ParentId;Path=$Path;PathStatus='Available';ProcessName=[IO.Path]::GetFileNameWithoutExtension($Path);StartTime=$birth.AddSeconds($Age)}}
function Reset-Fixture {
 [LocalProxySwitch.ProgramFamilyTracker]::Clear((Get-ProgramFamilyTrackingScope $app))
 $script:Rows=@((ProcessRow 100 1 $app),(ProcessRow 101 100 $worker 1),(ProcessRow 102 100 $conflict 2),(ProcessRow 103 1 $unrelated 1),(ProcessRow 104 100 $outside 1),(ProcessRow 105 101 $second 2))
 Write-LocalJson $script:StateFile @{version=3;installed=$true;entries=@(@{path=$app;route='Direct'},@{path=$conflict;route='b'});defaultRoute='a';programIngresses=@(@{id=('1'*32);path=$unrelated;port=19080;route='b'});siteRules=@(@{id=('2'*32);scope='global';type='domain';domain='example.com';route='b'})}
 Write-LocalJson (Join-Path $qa 'program-proxies.json') @{version=1;entries=@(@{path=$unrelated;route='b';adapter='chromium'})}
 $script:Replaces=0;$script:RejectReadback=$false;$script:Offline=$false;$script:RejectProbe=$false;$script:FailObservation=$false;$script:RejectCas=$false;$script:ConcurrentLaunchEdit=$false
}
Reset-Fixture
$initial=(Get-RuleMaintenanceSnapshot '').Fingerprint
$plan=Get-ProgramFamilyRoutePlan $app 'Direct'
$fixtureSummary=[ordered]@{CanonicalizedPaths=$fixtureAliasCount;Members=$plan.Members.Count;Missing=$plan.MissingCount;Covered=$plan.CoveredCount;Conflicts=$plan.ConflictCount;UnknownIds=@($plan.UnknownIds);Rows=@($plan.Members|ForEach-Object {[ordered]@{Name=$_.Name;State=$_.State;FileIdentityAvailable=[bool]$_.FileId;PIDs=@($_.Processes.Id)}})}|ConvertTo-Json -Depth 5 -Compress
Check ($plan.Members.Count -eq 4 -and $plan.MissingCount -eq 2 -and $plan.CoveredCount -eq 1 -and $plan.ConflictCount -eq 1) ('Preview classifies verified root, descendants, coverage and conflicting dedicated routes; fixture='+$fixtureSummary)
Check ($plan.Members.Path -notcontains $outside -and $plan.Members.Path -notcontains $unrelated) 'Unrelated same-directory executable and external same-name child are excluded'
Check ((Get-RuleMaintenanceSnapshot '').Fingerprint -ceq $initial) 'Preview is read-only across engine, launches, shortcuts and profiles'
Check (@($plan.Members|Where-Object {-not $_.FileId -or -not $_.Processes[0].StartTicks}).Count -eq 0) 'Every preview row includes verified physical file and creation-time evidence'
Throws {Set-ProgramFamilyRoute $plan} '确认'
$result=Set-ProgramFamilyRoute $plan -Confirmed
$after=Get-RoutingSnapshot
Check ($result.AddedCount -eq 2 -and $script:Replaces -eq 1) 'Two missing descendants are applied in exactly one engine CAS transaction'
Check (($after.entries|Where-Object path -eq $worker).route -eq 'Direct' -and ($after.entries|Where-Object path -eq $conflict).route -eq 'b') 'Missing login worker gains Direct while a helper dedicated route remains intact'
Check ($after.defaultRoute -eq 'a' -and $after.siteRules[0].route -eq 'b' -and $after.programIngresses[0].route -eq 'b' -and $after.launchEntries[0].route -eq 'b') 'Default, website, managed entrance and legacy launch choices are preserved'
Check (-not $script:LastRequest.ContainsKey('resetIngressSelections') -and -not $script:LastRequest.resetDefaultSelection) 'Family repairs do not reset unrelated failover selectors'
Check (Test-Path -LiteralPath $result.Backup) 'A local rollback backup is produced for the transaction'
Throws {Set-ProgramFamilyRoute $plan -Confirmed} '配置已改变'
Throws {Get-ProgramFamilyRoutePlan $app 'Follow'} '有效上游'

Reset-Fixture;$plan=Get-ProgramFamilyRoutePlan $app 'Direct';$before=Get-RoutingSnapshot
$state=Get-Content $script:StateFile -Raw -Encoding UTF8|ConvertFrom-Json;$state.entries[1].route='a';Write-LocalJson $script:StateFile $state
Throws {Set-ProgramFamilyRoute $plan -Confirmed} '配置已改变'
Check ($script:Replaces -eq 0 -and ((Get-RoutingSnapshot).entries|Where-Object path -eq $conflict).route -eq 'a') 'A concurrent dedicated route edit is never overwritten'
Reset-Fixture;$plan=Get-ProgramFamilyRoutePlan $app 'Direct'
$script:Rows[1].StartTime=$birth.AddSeconds(15)
Throws {Set-ProgramFamilyRoute $plan -Confirmed} '身份已改变'
Check ($script:Replaces -eq 0) 'Reused PID with new creation time invalidates preview'
Reset-Fixture;$plan=Get-ProgramFamilyRoutePlan $app 'Direct'
$savedWorker=$worker+'.original';[IO.File]::Move($worker,$savedWorker);[IO.File]::WriteAllText($worker,'replacement')
try{Throws {Set-ProgramFamilyRoute $plan -Confirmed} '身份已改变';Check ($script:Replaces -eq 0) 'Replaced executable invalidates physical identity even at the same path'}
finally{[IO.File]::Delete($worker);[IO.File]::Move($savedWorker,$worker)}
Reset-Fixture;$plan=Get-ProgramFamilyRoutePlan $app 'Direct';$plan.CreatedAt=[DateTime]::UtcNow.AddMinutes(-3).ToString('o')
Throws {Set-ProgramFamilyRoute $plan -Confirmed} '过期'
Reset-Fixture;$plan=Get-ProgramFamilyRoutePlan $app 'Direct';$plan.Route='a'
Throws {Set-ProgramFamilyRoute $plan -Confirmed} '身份已改变'
Reset-Fixture;$plan=Get-ProgramFamilyRoutePlan $app 'Direct';$script:ChangeDuringCheck=$true
Throws {Set-ProgramFamilyRoute $plan -Confirmed} '检查期间'
Check ($script:Replaces -eq 0) 'A family change during slow controller checks prevents the write'
Reset-Fixture;$plan=Get-ProgramFamilyRoutePlan $app 'Direct';$script:Offline=$true
Throws {Set-ProgramFamilyRoute $plan -Confirmed} '引擎尚未运行'
Check ($script:Replaces -eq 0) 'An offline engine is reported without automatically starting or migrating it'
Reset-Fixture;$plan=Get-ProgramFamilyRoutePlan $app 'Direct';$before=Get-RoutingSnapshot;$script:RejectReadback=$true
Throws {Set-ProgramFamilyRoute $plan -Confirmed} '未载入'
Check (Test-SameRouting $before (Get-RoutingSnapshot)) 'Partial loaded-state failure rolls the complete routing snapshot back'
Reset-Fixture;$plan=Get-ProgramFamilyRoutePlan $app 'Direct';$before=Get-RoutingSnapshot;$script:RejectCas=$true
Throws {Set-ProgramFamilyRoute $plan -Confirmed} 'CAS conflict'
Check (Test-SameRouting $before (Get-RoutingSnapshot)) 'Engine CAS rejection leaves the original batch unchanged'
Reset-Fixture;$plan=Get-ProgramFamilyRoutePlan $app 'Direct'
$changedProfiles=Copy-RoutingSnapshot $script:Profiles;$changedProfiles.Profiles[1].Port=19891;Write-LocalJson $script:ConfigPath $changedProfiles
Throws {Set-ProgramFamilyRoute $plan -Confirmed} '配置已改变'
Check ($script:Replaces -eq 0) 'Profile endpoint changes invalidate the complete preview revision'
Write-LocalJson $script:ConfigPath $script:Profiles
Reset-Fixture
$state=Get-Content $script:StateFile -Raw -Encoding UTF8|ConvertFrom-Json
$state.programIngresses+=@([pscustomobject]@{id=('3'*32);path=$worker;port=19081;route='Follow'})
Write-LocalJson $script:StateFile $state
$reserved=Get-ProgramFamilyRoutePlan $app 'Direct'
Check (($reserved.Members|Where-Object Path -eq $worker).State -eq 'Conflict') 'An existing managed Follow entrance is an explicit choice and is preserved'
Set-ProgramFamilyRoute $reserved -Confirmed|Out-Null
Check (((Get-RoutingSnapshot).programIngresses|Where-Object path -eq $worker).route -eq 'Follow' -and @((Get-RoutingSnapshot).entries|Where-Object path -eq $worker).Count -eq 0) 'A conflicting managed entrance never acquires a competing path rule'
Reset-Fixture
Write-LocalJson (Join-Path $qa 'program-proxies.json') @{version=1;entries=@(@{path=$worker;route='Direct';adapter='chromium'})}
$legacy=Get-ProgramFamilyRoutePlan $app 'Direct'
Check (($legacy.Members|Where-Object Path -eq $worker).State -eq 'Conflict') 'An existing legacy launcher is retained even when its route matches, instead of silently mixing modes'
Reset-Fixture
$state=Get-Content $script:StateFile -Raw -Encoding UTF8|ConvertFrom-Json
$state.entries[0]|Add-Member NoteProperty identity ([pscustomobject]@{FileId='different-physical-file'})
Write-LocalJson $script:StateFile $state
$identityConflict=Get-ProgramFamilyRoutePlan $app 'Direct'
Check (($identityConflict.Members|Where-Object Path -eq $app).State -eq 'Conflict') 'A saved identity for a replaced file requires separate maintenance instead of automatic trust'
Reset-Fixture;$script:FailObservation=$true
Throws {Get-ProgramFamilyRoutePlan $app 'Direct'} '进程身份读取失败'
Reset-Fixture;$script:Rows[1].StartTime=[DateTime]::MinValue
$partial=Get-ProgramFamilyRoutePlan $app 'Direct'
Check ($partial.UnknownIds -contains 101 -and $partial.Members.Path -notcontains $worker -and $partial.Members.Path -notcontains $second) 'Unknown child creation evidence cannot authorize it or its descendants'
Reset-Fixture;$script:Rows=@()
$empty=Get-ProgramFamilyRoutePlan $app 'Direct'
Check (-not $empty.CanApply -and $empty.Members.Count -eq 0) 'A stopped game never causes directory-wide guessed rules'
# The rule-only transaction must leave launch files outside its write set, including
# a real isolated-file edit by another writer while the engine request is in flight.
Reset-Fixture;$plan=Get-ProgramFamilyRoutePlan $app 'Direct';$script:ConcurrentLaunchEdit=$true;$script:LaunchWrites=0
$originalLaunchWriter=(Get-Item Function:Set-ProgramLaunchEntries).ScriptBlock
function Set-ProgramLaunchEntries($Entries){$script:LaunchWrites++;& $originalLaunchWriter $Entries}
try{
 $result=Set-ProgramFamilyRoute $plan -Confirmed
 Check ($result.AddedCount -eq 2 -and $script:LaunchWrites -eq 0) 'Adding family path rules never invokes the unrelated launch-record writer'
 Check (((Get-RoutingSnapshot).launchEntries|Where-Object path -eq $unrelated).route -eq 'a') 'A concurrent isolated-file launch selection edit survives a successful family repair'
}finally{Set-Item Function:Set-ProgramLaunchEntries $originalLaunchWriter}
Write-Output ('PASS: '+$script:checks+' family routing checks; real file identities, synthetic process/control snapshots, isolated data, and no Windows/network changes.')

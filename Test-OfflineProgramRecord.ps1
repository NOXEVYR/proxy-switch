$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-offline-record-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$script:checks=0;$script:lockDepth=0;$script:lockChecks=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Throws([scriptblock]$Action,[string]$Pattern){$message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message};Check ($message -match $Pattern) ('Expected '+$Pattern+'; got '+$message)}
function Set-SystemSnapshot {throw 'Windows writes forbidden'}
function Set-UserProxyEnv {throw 'Environment writes forbidden'}
function Start-ManagedProgram {throw 'Application starts forbidden'}
function Use-ChangeLock([scriptblock]$Action){$script:lockDepth++;try{& $Action}finally{$script:lockDepth--}}
$oldFull='FlowSwitch.OfflineTest_1.0.0.0_x64__8wekyb3d8bbwe';$newFull='FlowSwitch.OfflineTest_2.0.0.0_x64__8wekyb3d8bbwe'
$oldExe=Join-Path $qa ('WindowsApps\'+$oldFull+'\app\client.exe');$newRoot=Join-Path $qa ('WindowsApps\'+$newFull);$newExe=Join-Path $newRoot 'app\client.exe'
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($newExe));[IO.File]::WriteAllText($newExe,'inert package identity fixture')
foreach($name in @('resources.pak','chrome_100_percent.pak')){[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($newExe)) $name),'fixture')}
$script:packages=@([pscustomobject]@{InstallLocation=$newRoot;PackageFullName=$newFull;PackageFamilyName=[LocalProxySwitch.ProgramFileIdentity]::FamilyFromFullName($newFull);Verified=$true})
$realContext=${function:New-ProgramIdentityContext}
function New-ProgramIdentityContext($Processes=@(),$Packages=$null,[switch]$RefreshPackages){& $realContext -Processes $Processes -Packages $script:packages}
$identity=Get-ProgramIdentityDescriptor $newExe (New-ProgramIdentityContext)
$identity=$identity|ConvertTo-Json|ConvertFrom-Json;$identity.Path=$oldExe;$identity.PackageFullName=$oldFull
$script:processes=@([pscustomobject]@{Id=101;ParentId=1;Path=$newExe;PathStatus='Available';StartTime=[DateTime]::UtcNow.AddMinutes(-1);ProcessName='client';MainWindowHandle=[IntPtr]1})
$script:tcpRows=@();$script:tcpAvailable=$true;$script:pidState='stopped'
function Get-ProcessInventory {param([int]$Id=0);@($script:processes)}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$script:tcpAvailable;Rows=@($script:tcpRows)}}
function Get-RecoveryOwnerState {$script:pidState}
$realLockAssertion=${function:Assert-RuleMaintenanceNodeLocks}
Throws {& $realLockAssertion $null} '共享锁'
function Assert-RuleMaintenanceNodeLocks($Locks){if($Locks -cne 'held-fixture'){throw 'Missing specialized lock proof'};$script:lockChecks++}
function Invoke-AppRouter($Request){
    if($Request.action -cne 'program-record-offline'){throw 'No controller operation permitted'}
    Invoke-ProgramOfflineRecordWorker $Request.plan 'held-fixture'
}
$script:case=0
function New-Case {
    $script:case++;$script:DataRoot=Join-Path $qa ('data-'+$script:case);$script:ConfigPath=Join-Path $script:DataRoot 'config.json'
    [void][IO.Directory]::CreateDirectory((Join-Path $script:DataRoot 'gateway'))
    $script:Profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(
        @{Id='gateway';Name='Own';Protocol='http';Host='127.0.0.1';Port=18790;CorePath=(Join-Path $qa 'own-core.exe')},
        @{Id='a';Name='A';Protocol='http';Host='127.0.0.1';Port=21001}
    );Routing=@{Adapter='standalone';ProfileId='gateway';UnifiedMode='gateway'}})
    Write-LocalJson $script:ConfigPath $script:Profiles
    Write-LocalJson (Join-Path $script:DataRoot 'app-rules.json') @{version=3;installed=$true;metadata='keep-state';entries=@(@{path='C:\Unrelated\other.exe';route='Direct';metadata='keep-entry'});defaultRoute='a';programIngresses=@(@{id=('a'*32);path=$oldExe;identity=$identity;port=19080;route='a';metadata='keep-ingress'});siteRules=@(@{id=('b'*32);scope='global';type='domain';domain='example.invalid';route='Direct'})}
    Write-LocalJson (Join-Path $script:DataRoot 'gateway\process.json') @{supervisor=2147483646;supervisorStartTicks='1';core=2147483647;coreStartTicks='1'}
    Write-LocalJson (Join-Path $script:DataRoot 'selection.json') @{Key='a';private='selection unchanged'}
    [IO.File]::WriteAllText((Join-Path $script:DataRoot 'gateway\runtime.yaml'),'previous stopped runtime, retain exact bytes')
    $script:pidState='stopped';$script:tcpRows=@();$script:tcpAvailable=$true
    $script:processes=@([pscustomobject]@{Id=101;ParentId=1;Path=$newExe;PathStatus='Available';StartTime=[DateTime]::UtcNow.AddMinutes(-1);ProcessName='client';MainWindowHandle=[IntPtr]1})
    $script:processes+=@([pscustomobject]@{Id=$PID;ParentId=1;Path=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe');PathStatus='Available';StartTime=[DateTime]::UtcNow;ProcessName='powershell';MainWindowHandle=[IntPtr]::Zero})
}
function State {Get-Content (Join-Path $script:DataRoot 'app-rules.json') -Raw|ConvertFrom-Json}
New-Case
$before=Get-RuleMaintenanceSnapshot $oldExe;$service=Get-RuleMaintenanceServiceObservation $before
Check ($service.State -eq 'stopped') 'unavailable controller is replaced by positive stopped PID/process/TCP evidence'
$plan=Get-ProgramRuleRepairPlan $oldExe
Check ($plan.Version -eq 2 -and $plan.Execution -eq 'saved-only' -and $plan.Action -eq 'repair-path' -and $plan.Impact -match '尚未载入') 'offline repair plan claims rules loaded or does not bind explicit execution scope'
Check ((Get-RuleMaintenanceSnapshot $oldExe).Fingerprint -ceq $before.Fingerprint) 'offline preview writes local state'
$protected=Get-RuleMaintenanceServiceObservation $before
$result=Repair-ProgramRule $plan;$after=State
Check ($after.programIngresses[0].path -ieq $newExe -and $after.programIngresses[0].identity.PackageVerified -and $after.programIngresses[0].id -eq ('a'*32) -and $after.programIngresses[0].port -eq 19080 -and $after.programIngresses[0].route -eq 'a') 'offline migration loses verified identity, ingress ID, stable port or chosen route'
Check ($after.defaultRoute -eq 'a' -and $after.entries[0].path -eq 'C:\Unrelated\other.exe' -and $after.siteRules[0].domain -eq 'example.invalid' -and $after.metadata -eq 'keep-state' -and $after.programIngresses[0].metadata -eq 'keep-ingress') 'offline migration overwrites unrelated policy or metadata'
Check ($result.Execution -eq 'saved-only' -and -not $result.RulesLoaded -and -not $result.Removed -and (Test-Path $result.Backup) -and $result.Message -match '尚未载入') 'offline result lacks backup or falsely claims forwarding started'
Check ((Get-RuleMaintenanceServiceObservation (Get-RuleMaintenanceSnapshot $newExe)).Fingerprint -ceq $protected.Fingerprint -and $script:lockDepth -eq 0 -and $script:lockChecks -gt 0) 'offline repair changes protected runtime/selection or skips locked worker scope'
New-Case;$plan=Get-ProgramOfflineReleasePlan $oldExe;$before=State
Throws {Remove-ProgramOfflineRule $plan} '明确确认'
$result=Remove-ProgramOfflineRule $plan -Confirmed;$after=State
Check ($result.Removed -and -not $result.RulesLoaded -and @($after.programIngresses).Count -eq 0 -and $after.defaultRoute -eq $before.defaultRoute -and ($after.entries|ConvertTo-Json -Compress) -ceq ($before.entries|ConvertTo-Json -Compress) -and ($after.siteRules|ConvertTo-Json -Compress) -ceq ($before.siteRules|ConvertTo-Json -Compress)) 'release-system removes unrelated/default/site policy or masquerades as Follow'
Check ($result.Message -match 'Windows 系统代理保持原样' -and $result.Impact -match '不是') 'release-system does not explain unchanged Windows proxy and distinct Follow semantics'
foreach($running in @($true,$false)){
    New-Case;$state=State;$state.programIngresses[0].path=$newExe;$state.programIngresses[0].PSObject.Properties.Remove('identity');Write-LocalJson (Join-Path $script:DataRoot 'app-rules.json') $state
    if(-not $running){$script:processes=@($script:processes|Where-Object Id -ne 101)}
    $release=Get-ProgramOfflineReleasePlan $newExe;$result=Remove-ProgramOfflineRule $release -Confirmed
    Check ($result.Removed -and @((State).programIngresses).Count -eq 0) 'valid current executable with a verified file identity cannot release a stopped saved route when running or idle'
}
New-Case;$script:processes=@()
Throws {Get-ProgramOfflineReleasePlan $oldExe} '停止证据未知'
New-Case;$state=State;$state.siteRules[0].scope=('a'*32);Write-LocalJson (Join-Path $script:DataRoot 'app-rules.json') $state
Throws {Get-ProgramOfflineReleasePlan $oldExe} '网站例外'
New-Case;Write-LocalJson (Join-Path $script:DataRoot 'program-proxies.json') @{version=1;entries=@(@{path=$oldExe;route='a';adapter='chromium'})}
Throws {Get-ProgramOfflineReleasePlan $oldExe} '启动代理'
New-Case;Write-LocalJson (Join-Path $script:DataRoot 'program-shortcuts.json') @{version=1;entries=@(@{program=$oldExe;shortcut=(Join-Path $qa 'native.lnk')})}
Throws {Get-ProgramOfflineReleasePlan $oldExe} '快捷方式'
New-Case;$plan=Get-ProgramRuleRepairPlan $oldExe;$plan.Version=1
Throws {Repair-ProgramRule $plan} '明确的离线'
New-Case;$plan=Get-ProgramOfflineReleasePlan $oldExe;$plan.Action='repair-path'
Throws {Remove-ProgramOfflineRule $plan -Confirmed} '明确确认'
New-Case;$plan=Get-ProgramRuleRepairPlan $oldExe;$plan.CreatedAt=[DateTime]::UtcNow.AddMinutes(-3).ToString('o')
Throws {Repair-ProgramRule $plan} '过期'
New-Case;$plan=Get-ProgramRuleRepairPlan $oldExe;$script:Profiles.Profiles[1].Name='external edit';Write-LocalJson $script:ConfigPath $script:Profiles
Throws {Repair-ProgramRule $plan} '已经变化'
New-Case;$plan=Get-ProgramOfflineReleasePlan $oldExe;$script:pidState='alive'
Throws {Remove-ProgramOfflineRule $plan -Confirmed} '明确停止'
New-Case;$script:pidState='unknown'
Throws {Get-ProgramRuleRepairPlan $oldExe} '停止证据未知'
New-Case;$script:tcpAvailable=$false
Throws {Get-ProgramOfflineReleasePlan $oldExe} '停止证据未知'
foreach($state in @('Listen','Established','SynSent')){
    New-Case;$script:tcpRows=@([pscustomobject]@{State=$state;LocalAddress='127.0.0.1';LocalPort=$(if($state -eq 'Listen'){19080}else{50000});RemoteAddress='127.0.0.1';RemotePort=19080})
    Throws {Get-ProgramOfflineReleasePlan $oldExe} '明确停止'
}
New-Case;$script:processes+=@([pscustomobject]@{Id=202;ProcessName='own-core';Path='';PathStatus='AccessDenied'})
Throws {Get-ProgramRuleRepairPlan $oldExe} '停止证据未知'
New-Case;[IO.File]::WriteAllText((Join-Path $script:DataRoot 'gateway\supervisor.lock'),'corrupt')
Throws {Get-ProgramRuleRepairPlan $oldExe} '停止证据未知'
New-Case;$state=State;$state.programIngresses[0].PSObject.Properties.Remove('identity');Write-LocalJson (Join-Path $script:DataRoot 'app-rules.json') $state
Throws {Get-ProgramRuleRepairPlan $oldExe} '唯一 Windows 包身份'
New-Case;$plan=Get-ProgramRuleRepairPlan $oldExe
Write-LocalJson (Join-Path $script:DataRoot 'selection.json') @{Key='Direct';private='new external choice'}
Throws {Repair-ProgramRule $plan} '已经变化'
New-Case;$plan=Get-ProgramRuleRepairPlan $oldExe;$beforeHash=(Get-RuleMaintenanceSnapshot $oldExe).Files['app-rules.json'].Hash
$realExchange=${function:Set-RuleMaintenanceFile};$script:inject='selection';$script:injected=$false
function Set-RuleMaintenanceFile($Before,[byte[]]$Bytes,[bool]$Remove=$false){
    Check ($script:lockDepth -gt 0) 'specialized write does not hold Use-ChangeLock'
    & $realExchange $Before $Bytes $Remove
    if(-not $script:injected -and [IO.Path]::GetFileName($Before.Path) -eq 'app-rules.json'){
        $script:injected=$true
        if($script:inject -eq 'selection'){Write-LocalJson (Join-Path $script:DataRoot 'selection.json') @{Key='Direct';private='external choice preserved'}}
        else{[IO.File]::WriteAllText($Before.Path,'external policy content')}
    }
}
Throws {Repair-ProgramRule $plan} '回滚'
Check ((Get-RuleMaintenanceSnapshot $oldExe).Files['app-rules.json'].Hash -ceq $beforeHash -and (Get-Content (Join-Path $script:DataRoot 'selection.json') -Raw|ConvertFrom-Json).Key -eq 'Direct') 'post-write verification failure does not roll back owned state or overwrites external selection'
New-Case;$plan=Get-ProgramRuleRepairPlan $oldExe;$script:inject='policy';$script:injected=$false
Throws {Repair-ProgramRule $plan} '保留外部修改'
Check ([IO.File]::ReadAllText((Join-Path $script:DataRoot 'app-rules.json')) -ceq 'external policy content') 'rollback overwrites externally changed program policy'
${function:Set-RuleMaintenanceFile}=$realExchange
Write-Output ('PASS: '+$script:checks+' offline program-record assertions; isolated package/process/TCP fixtures, no Windows writes, app starts or controller requests.')
$resolved=[IO.Path]::GetFullPath($qa);$prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('FlowSwitch-offline-record-')){Remove-Item -LiteralPath $resolved -Recurse -Force}

$ErrorActionPreference='Stop'
$script:Checks=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
$qa=Join-Path $env:TEMP ('FlowSwitch-route-dispatch-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qa)
. (Join-Path $PSScriptRoot 'ProgramIdentity.ps1')
$script:ActualIdentityContext=(Get-Item Function:New-ProgramIdentityContext).ScriptBlock
$script:ActualPathEquivalent=(Get-Item Function:Test-ProgramPathEquivalent).ScriptBlock
# Execute the actual UI request functions and worker AST. The fixture supplies
# only backend observations/mutations; no UI process or Windows settings change.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'ProxyWindow.ps1'),[ref]$tokens,[ref]$errors)
Check (-not $errors) 'UI source parses before extracting production dispatch'
$matches=@($ast.FindAll({param($node)
 $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$code' -and $node.Right.Extent.Text -match 'param\(\$Root,\$Kind'
},$true))
Check ($matches.Count -eq 1) 'One actual background worker is selected'
$source=$matches[0].Right.Extent.Text;$worker=[scriptblock]::Create($source.Substring(1,$source.Length-2))
foreach($name in @('Request-ApplicationRoute','Request-ProgramRouteAccess')){
 $found=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
 Check ($found.Count -eq 1) ('Actual request function selected: '+$name)
 . ([scriptblock]::Create($found[0].Extent.Text))
}
$backend=@'
$script:Profiles=[pscustomobject]@{Version=3;Profiles=@();Routing=@{Adapter='standalone'}}
function Use-ChangeLock([scriptblock]$Action){$script:LockDepth++;try{& $Action}finally{$script:LockDepth--}}
function New-ProgramIdentityContext {
 Check ($script:LockDepth -gt 0) 'Fresh identity context is created inside the classification lock'
 $script:IdentityReads++;$script:DispatchIdentityContext=& $script:ActualIdentityContext -Packages @()
 $script:DispatchIdentityContext
}
function Test-ProgramPathEquivalent($Left,$Right,$Context){
 Check ($script:LockDepth -gt 0 -and [object]::ReferenceEquals($Context,$script:DispatchIdentityContext)) 'Physical equivalence uses the same fresh locked context'
 $script:EquivalenceReads++;& $script:ActualPathEquivalent $Left $Right $Context
}
function Get-ProgramProxyAdapter($Path){Check ($script:LockDepth -gt 0) 'Fresh adapter classification holds the shared change lock';$script:AdapterReads++;$script:Adapter}
function Get-RoutingSnapshot {
 Check ($script:LockDepth -gt 0) 'Fresh saved-rule classification holds the shared change lock'
 $script:SnapshotReads++;if($script:SnapshotFails){throw 'Fixture rule snapshot unavailable'}
 [pscustomobject]@{entries=$(if($script:HasEngine){@([pscustomobject]@{path=$script:SavedEnginePath;route='Direct'})}else{@()});programIngresses=$(if($script:HasManaged){@([pscustomobject]@{path='C:\Fixtures\game.exe';route='Direct';id='fixture'})}else{@()});launchEntries=@()}
}
function Get-ManagedProgramIngress($Path){if($script:HasManaged){[pscustomobject]@{path=$Path;id='fixture';route='Direct'}}}
function Get-ProgramLaunchEntries {@()}
function Get-ProgramRouteAccessPlan($Path,$Route){
 $script:Plans++;$script:LastPlanPath=$Path;$script:LastPlanRoute=$Route
 [pscustomobject]@{Version=1;CanApply=(-not $script:HasManaged);Path=$Path;Route=$Route;BlockedReason=$(if($script:HasManaged){'此程序使用固定程序入口或启动适配，不转换成引擎路径规则。'}else{''});FamilyPlan=@{Members=@()};Message='Fixture explicit preview';Impact='Fixture global access requires confirmation'}
}
function Set-ManagedApplicationRoute($Path,$Route){
 Check ($script:LockDepth -gt 0) 'Supported managed dispatch remains inside the classification lock'
 if($script:Adapter -ne 'chromium' -or ($script:HasEngine -and (& $script:ActualPathEquivalent $script:SavedEnginePath $Path $script:DispatchIdentityContext))){throw 'Unexpected managed conversion'}
 $script:ManagedWrites++;[pscustomobject]@{Path=$Path;Route=$Route;Message='Fixture supported managed choice';Backup='fixture-only'}
}
function Set-ProgramRouteAccess($Plan,[switch]$Confirmed){
 if(-not $Confirmed){throw 'Fixture requires explicit confirmation'}
 $script:Applies++;[pscustomobject]@{Message='Fixture confirmed application';Path=$Plan.Path;Route=$Plan.Route;Backup='fixture-only'}
}
function Set-ApplicationRoute {throw 'Unexpected legacy direct writer'}
function Set-SystemSnapshot {throw 'Must not write Windows'}
function Set-UserProxyEnv {throw 'Must not write Windows'}
function Ensure-ManagedGateway {throw 'Must not start service'}
function Get-TcpObservationSnapshot {if($script:RefreshFails){throw 'Fixture observation unavailable'};[pscustomobject]@{Rows=@();Available=$true}}
function Get-ApplicationRoutes {param($TcpRows,$TcpAvailable) [pscustomobject]@{Rows=@();Available=$true}}
function Get-ProxyStatus {param($Apps,$TcpRows,$TcpAvailable) [pscustomobject]@{Key='fixture'}}
'@
[IO.File]::WriteAllText((Join-Path $qa 'ProxyBackend.ps1'),$backend,(New-Object Text.UTF8Encoding($true)))
function Reset-Fixture {
 $script:Adapter='';$script:AdapterReads=0;$script:SnapshotReads=0;$script:IdentityReads=0;$script:EquivalenceReads=0;$script:DispatchIdentityContext=$null;$script:SavedEnginePath='C:\Fixtures\game.exe';$script:SnapshotFails=$false;$script:LockDepth=0;$script:Plans=0;$script:ManagedWrites=0;$script:Applies=0;$script:HasManaged=$false;$script:HasEngine=$false;$script:RefreshFails=$false;$script:Requests=@();$script:Activity=@()
 $script:AppTarget=[pscustomobject]@{Path='C:\Fixtures\game.exe';Mode='observe';RequiresRepair=$false}
}
function Start-Work($Kind,$Key){$script:Requests+=@([pscustomobject]@{Kind=$Kind;Key=$Key})}
function Write-Activity($Text){$script:Activity+=@($Text)}
function Run-Worker($Request){
 $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
 & $worker $qa $Request.Kind $Request.Key $qa $false $false @() $queue ([Threading.CancellationToken]::None)
}
function Choose([string]$Route){Request-ApplicationRoute $Route;Check ($script:Requests.Count -eq 1) 'One explicit selection schedules one worker';Run-Worker $script:Requests[0]}

Reset-Fixture;$reply=Choose 'Direct'
Check ($script:Requests[0].Kind -eq 'ManagedAppRoute') 'First ordinary program goes through fresh worker classification'
Check ($reply.OK -and $reply.Kind -eq 'ProgramAccessPlan' -and $reply.Result.CanApply -and $script:Plans -eq 1) 'Fresh unsupported game returns an explicit preview reply for UI confirmation'
Check ($script:ManagedWrites -eq 0 -and $script:Applies -eq 0) 'First game selection cannot silently mutate system or route state'
Check ($script:AdapterReads -eq 1 -and $script:LastPlanPath -eq $script:AppTarget.Path -and $script:LastPlanRoute -eq 'Direct') 'Fresh executable classification forwards the selected path and route'
Check ($script:SnapshotReads -eq 1 -and $script:LockDepth -eq 0) 'Classification reads current rules once and releases the shared lock'
Check ($script:IdentityReads -eq 1) 'Classification binds one fresh physical identity context'

Reset-Fixture;$script:Adapter='chromium';$reply=Choose 'proxy-b'
Check ($reply.OK -and $reply.Kind -eq 'ManagedAppRoute' -and $script:ManagedWrites -eq 1 -and $script:Plans -eq 0 -and $script:Applies -eq 0) 'Supported Chromium keeps the existing managed-route action'
Check ($reply.Result.Route -eq 'proxy-b') 'Supported managed action receives the requested target unchanged'

Reset-Fixture;$script:Adapter='chromium';$script:AppTarget.Mode='engine';$script:HasEngine=$true;$reply=Choose 'Direct'
Check ($script:Requests[0].Kind -eq 'ProgramAccessPlan' -and $reply.Kind -eq 'ProgramAccessPlan' -and $reply.OK) 'Existing engine rule is explicitly previewed even when the executable supports Chromium'
Check ($script:ManagedWrites -eq 0 -and $script:Plans -eq 1) 'Existing engine rule is never silently converted into a program ingress'

Reset-Fixture;$script:HasManaged=$true;$script:AppTarget.Mode='managed';$reply=Choose 'Direct'
Check ($reply.OK -and $reply.Kind -eq 'ProgramAccessPlan' -and -not $reply.Result.CanApply -and $reply.Result.BlockedReason -match '固定程序入口') 'Lost managed adapter returns an explicit protected refusal'
Check ($script:ManagedWrites -eq 0 -and $script:Applies -eq 0) 'Lost adapter preserves the existing managed mode and rules'

Reset-Fixture;$script:RefreshFails=$true;$reply=Choose 'Direct'
Check ($reply.OK -and $reply.Kind -eq 'ProgramAccessPlan' -and $reply.RefreshError -and $reply.Result.CanApply) 'Post-preview observation failure preserves the confirmation reply without inventing a successful mutation'
Check ($script:ManagedWrites -eq 0 -and $script:Applies -eq 0) 'Refresh failures cannot activate a preview'

Reset-Fixture;$reply=Choose 'Direct';$preview=$reply.Result
$confirmed=Run-Worker ([pscustomobject]@{Kind='ProgramAccessApply';Key=($preview|ConvertTo-Json -Depth 8 -Compress)})
Check ($confirmed.OK -and $confirmed.Kind -eq 'ProgramAccessApply' -and $script:Applies -eq 1 -and $script:ManagedWrites -eq 0) 'Only the separate confirmed UI action reaches the access apply contract'

Reset-Fixture;$script:AppTarget.RequiresRepair=$true;Request-ApplicationRoute 'Direct'
Check ($script:Requests.Count -eq 0 -and $script:Activity.Count -eq 1) 'Known identity repair prevents any selection worker from starting'
Reset-Fixture;$script:AppTarget.Mode='engine';Request-ApplicationRoute ''
Check ($script:Requests.Count -eq 0 -and $script:Activity.Count -eq 1) 'Existing engine preview rejects a missing target before scheduling work'

# A row can become stale while another window saves an engine rule. The worker
# must honor that fresh record rather than infer a migration from old row mode.
Reset-Fixture;$script:Adapter='chromium';$script:HasEngine=$true;$reply=Choose 'Direct'
Check ($reply.OK -and $reply.Kind -eq 'ProgramAccessPlan' -and $script:Plans -eq 1 -and $script:ManagedWrites -eq 0) 'Fresh engine record wins over a stale observed row and Chromium capability'
Reset-Fixture;$script:Adapter='chromium';$script:SnapshotFails=$true;$reply=Choose 'Direct'
Check (-not $reply.OK -and $reply.Error -match 'snapshot unavailable') 'Unknown fresh saved-rule snapshot refuses classification'
Check ($script:AdapterReads -eq 0 -and $script:ManagedWrites -eq 0 -and $script:Applies -eq 0 -and $script:Plans -eq 0 -and $script:LockDepth -eq 0) 'Failed saved-rule observation never guesses a mode or executes a mutation and always releases the lock'

$physical=Join-Path $qa 'Original Editor.exe';$alias=Join-Path $qa 'Editor Alias.exe';$different=Join-Path $qa 'Other Editor.exe'
[IO.File]::WriteAllText($physical,'public identity fixture');[IO.File]::WriteAllText($different,'public identity fixture')
[void](New-Item -ItemType HardLink -Path $alias -Target $physical)
$realContext=& $script:ActualIdentityContext -Packages @()
Check (& $script:ActualPathEquivalent $physical $alias $realContext) 'Real filesystem hardlink has the same physical executable identity'
Check (-not (& $script:ActualPathEquivalent $physical $different $realContext)) 'Same bytes and similar name do not imply the same executable identity'
Reset-Fixture;$script:Adapter='chromium';$script:HasEngine=$true;$script:SavedEnginePath=$alias;$script:AppTarget.Path=$physical;$reply=Choose 'Direct'
Check ($reply.OK -and $reply.Kind -eq 'ProgramAccessPlan' -and $script:Plans -eq 1 -and $script:ManagedWrites -eq 0 -and $script:EquivalenceReads -eq 1) 'Saved hardlink alias wins over stale observed Chromium row without creating a competing ingress'
Reset-Fixture;$script:Adapter='chromium';$script:HasEngine=$true;$script:SavedEnginePath=$alias;$script:AppTarget.Path=$different;$reply=Choose 'Direct'
Check ($reply.OK -and $reply.Kind -eq 'ManagedAppRoute' -and $script:Plans -eq 0 -and $script:ManagedWrites -eq 1 -and $script:EquivalenceReads -eq 1) 'An unrelated executable with the same bytes remains a separate supported managed program'
Write-Output ('PASS: '+$script:Checks+' program route dispatch assertions; actual UI request and worker AST, synthetic backend only, no real Windows or process mutations.')

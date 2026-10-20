$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-DailyProxy-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$script:realDailyEndpoint=${function:Get-DailyProxyEndpoint}
$script:realRuleFileWriter=${function:Set-RuleMaintenanceFile}
$script:checks=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Pattern){$errorText='';try{& $Action|Out-Null}catch{$errorText=$_.Exception.Message};Check ($errorText -match $Pattern) ('Expected '+$Pattern+', got '+$errorText)}
$script:Profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(
    [pscustomobject]@{Id='Clash';Name='Clash';Protocol='http';Host='127.0.0.1';Port=7897;CorePath='';AppPath=''},
    [pscustomobject]@{Id='AlternateProxy';Name='VPN';Protocol='http';Host='127.0.0.1';Port=57777;CorePath='';AppPath=''}
);Routing=[pscustomobject]@{Adapter='none';ProfileId='';UnifiedMode='system'}})
$script:sys=[pscustomobject]@{Flags=3;Server='127.0.0.1:7897';Bypass='<local>;company.local'}
$script:en=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:7897';HTTPS_PROXY='http://127.0.0.1:7897';ALL_PROXY=$null;NO_PROXY='company.local'}
$script:sel=$null;$script:writes=0;$script:backups=0;$script:probe=$true;$script:failSelection=$false;$script:failNative=$false;$script:guard=$false;$script:mutateProbe=$false
$script:rules=[pscustomobject]@{installed=$true;entries=@([pscustomobject]@{path='C:\Fixture\app.exe';route='Clash'});defaultRoute='Clash';programIngresses=@([pscustomobject]@{id='a';port=19080;route='AlternateProxy'});siteRules=@([pscustomobject]@{domain='example.org';route='Direct'});launchEntries=@([pscustomobject]@{path='C:\Fixture\other.exe';route='AlternateProxy'})}
$script:endpoints=@{Clash='Ready';AlternateProxy='Ready'};$script:ownerGeneration=1
$script:outsideSelectionAfterReceipt=$false
$script:viewsOverride=$null;$script:viewRaceOnNative=$false;$script:viewRaceOnSelection=$false
function Read-ProfileSettings {$script:Profiles}
function Get-SystemSnapshot {$script:sys}
function Get-UserProxyEnv {$script:en}
function Get-Selection {$script:sel}
function Get-RoutingSnapshot {$script:rules}
function New-FixtureWindowsViews {
    $enabled=[bool]($script:sys.Flags -band 2)
    [pscustomobject]@{Registry=[pscustomobject]@{Available=$true;Enabled=$enabled;Server=$script:sys.Server};WinHttpIE=[pscustomobject]@{Available=$true;Server=$(if($enabled){$script:sys.Server}else{''});AutoDetect=[bool]($script:sys.Flags -band 8);HasPac=[bool]($script:sys.Flags -band 4)}}
}
function Get-WindowsApplicationProxyViews {if($null -ne $script:viewsOverride){$script:viewsOverride}else{New-FixtureWindowsViews}}
function Get-ClientInterference {[pscustomobject]@{Running=$true;Tun=$false;Guard=$script:guard;SystemProxy=$true;Topology=[pscustomobject]@{State='NoEvidence';IPv4='NoEvidence';IPv6='NoEvidence';Available=$true;ObservedAt=[DateTime]::UtcNow.ToString('o')}}}
function Get-DailyProxyEndpoint([string]$Key){[pscustomobject]@{Key=$Key;State=$(if($Key -eq 'Direct'){'Ready'}else{$script:endpoints[$Key]});Identity=$(if($Key -eq 'Direct'){'Direct'}else{$Key+':'+$script:ownerGeneration})}}
function Set-SystemSnapshot($Snapshot){$script:writes++;if($script:failNative){$script:failNative=$false;throw 'native fixture failure'};$script:sys=$Snapshot;$script:viewsOverride=$null;if($script:viewRaceOnNative){$script:viewRaceOnNative=$false;$script:viewsOverride=New-FixtureWindowsViews;$script:viewsOverride.Registry.Server='127.0.0.1:19999'}}
function Set-UserProxyEnv($Values,$ExpectedBefore){Check (Test-SameEnv $ExpectedBefore $script:en) 'Environment CAS missing';$script:writes++;$script:en=$Values}
function Save-Selection($Selection){$script:writes++;if($script:failSelection){$script:failSelection=$false;throw 'selection fixture failure'};$script:sel=$Selection;if($script:viewRaceOnSelection){$script:viewRaceOnSelection=$false;$script:viewsOverride=New-FixtureWindowsViews;$script:viewsOverride.Registry.Server='127.0.0.1:19998'}}
function Save-Backup($Snapshot){$script:backups++;[void][IO.Directory]::CreateDirectory($qa);'fixture-backup'}
function Test-ProxyRoute([string]$Key,[switch]$Fast){Check $Fast 'Preflight must use bounded Fast';if($script:mutateProbe){$script:ownerGeneration++};[pscustomobject]@{Usable=$script:probe}}
function Get-Listener($Profile){[pscustomobject]@{PID=88;Name='fixture'}}
function Enable-IndependentGateway {throw 'FORBIDDEN engine startup'}
function Set-RoutingSnapshot {throw 'FORBIDDEN routing write'}
function Start-Process {throw 'FORBIDDEN program startup'}
function Get-OverrideWarnings {}
function Get-LiveConnections {@()}
function Get-LocalEndpointObservation {[pscustomobject]@{Ready=$true}}
function Set-RuleMaintenanceFile($Before,[byte[]]$Bytes,[bool]$Remove=$false){
    & $script:realRuleFileWriter $Before $Bytes $Remove
    if($script:outsideSelectionAfterReceipt){$script:outsideSelectionAfterReceipt=$false;$script:sel=[pscustomobject]@{Key='external-fixture'}}
}
try{
    $initialRules=Get-DailyProxyHash $script:rules;$before=Get-DailyProxyHash @($script:sys,$script:en,$script:sel)
    $plan=Get-DailyProxyPlan 'Clash';Check ($plan.CanApply -and $plan.NoChange) 'Missing ALL_PROXY must allow no-op'
    $count=$script:writes;$backupCount=$script:backups;$r=Set-UniversalProxy 'Clash'
    Check ($r.NoChange -and $script:writes -eq $count -and $script:backups -eq $backupCount) 'No-op must perform zero writes and zero backups'
    $state=Get-DailyProxyState ([pscustomobject]@{Key='Clash';EndpointReady=$true});Check ($state.Headline -eq '当前系统代理由 Clash 管理') 'Daily UI must use current key'
    $status=Get-ProxyStatus -TcpRows @();Check $status.Aligned 'Optional ALL_PROXY unset must not misalign'
    $script:endpoints.AlternateProxy='Stopped';$plan=Get-DailyProxyPlan 'AlternateProxy';Check (-not $plan.CanApply) 'Stopped target must refuse'
    Reject {Set-DailyProxy $plan -Confirmed} '未连接';Check ((Get-DailyProxyHash @($script:sys,$script:en,$script:sel)) -eq $before -and (Get-DailyProxyHash $script:rules) -eq $initialRules) 'Stopped target must preserve everything'
    $script:endpoints.AlternateProxy='Ready';$plan=Get-DailyProxyPlan 'AlternateProxy';Reject {Set-DailyProxy $plan} '明确确认'
    $plan.CreatedAt=[DateTimeOffset]::UtcNow.AddSeconds(-121).ToString('o');Reject {Set-DailyProxy $plan -Confirmed} '过期'
    $plan=Get-DailyProxyPlan 'AlternateProxy';$script:en.NO_PROXY='changed';Reject {Set-DailyProxy $plan -Confirmed} '已变化';$script:en.NO_PROXY='company.local'
    $plan=Get-DailyProxyPlan 'AlternateProxy';$script:rules.entries[0].route='AlternateProxy';Reject {Set-DailyProxy $plan -Confirmed} '已变化';$script:rules.entries[0].route='Clash'
    $plan=Get-DailyProxyPlan 'AlternateProxy';$script:viewsOverride=New-FixtureWindowsViews;$script:viewsOverride.Registry.Server='127.0.0.1:19999';$count=$script:writes;Reject {Set-DailyProxy $plan -Confirmed} '已变化';Check ($script:writes -eq $count) 'Three-view external edit must fail CAS before writes';$script:viewsOverride=$null
    $plan=Get-DailyProxyPlan 'AlternateProxy';$script:probe=$false;$count=$script:writes;Reject {Set-DailyProxy $plan -Confirmed} '检测未通过';Check ($count -eq $script:writes) 'Failed probe must not write';$script:probe=$true
    $plan=Get-DailyProxyPlan 'AlternateProxy';$script:mutateProbe=$true;Reject {Set-DailyProxy $plan -Confirmed} '已变化';$script:mutateProbe=$false
    $script:guard=$true;Check (-not (Get-DailyProxyPlan 'AlternateProxy').CanApply) 'Guard must block';$script:guard=$false
    Write-LocalJson (Get-IndependentSessionPath) ([pscustomobject]@{Started='old'});Check (-not (Get-DailyProxyPlan 'AlternateProxy').CanApply) 'Old independent session must block';[IO.File]::Delete((Get-IndependentSessionPath))
    $r=Set-UniversalProxy 'AlternateProxy';Check ($r.Key -eq 'AlternateProxy' -and (Get-SystemKey $script:sys) -eq 'AlternateProxy' -and $script:en.ALL_PROXY -eq 'http://127.0.0.1:57777') 'Alternate proxy switch must use external HTTP'
    Check ($script:en.NO_PROXY -eq 'company.local' -and $script:sys.Bypass -eq '<local>;company.local' -and (Get-DailyProxyHash $script:rules) -eq $initialRules) 'Switch must preserve bypass and all rules'
    $plan=Get-DailyProxyUndoPlan;Check $plan.CanApply 'Undo should be available';$script:en.NO_PROXY='external';Reject {Restore-DailyProxy $plan -Confirmed} '外部修改';$script:en.NO_PROXY='company.local'
    $plan=Get-DailyProxyUndoPlan;Restore-DailyProxy $plan -Confirmed|Out-Null
    Check ((Get-SystemKey $script:sys) -eq 'Clash' -and $null -eq $script:en.ALL_PROXY -and $null -eq $script:sel) 'Undo must restore original Windows, env and selection'
    Check (-not (Get-DailyProxyUndoPlan).CanApply) 'Undo must be single use'
    Set-UniversalProxy 'AlternateProxy'|Out-Null;Set-UniversalProxy 'Clash'|Out-Null;Check ((Get-SystemKey $script:sys) -eq 'Clash') 'Return to Clash'
    $prior=Get-DailyProxyHash @($script:sys,$script:en,$script:sel);$receipt=(Read-RuleMaintenanceFile (Get-DailyProxyReceiptPath)).Hash
    $script:failSelection=$true;Reject {Set-UniversalProxy 'AlternateProxy'} '已恢复'
    Check ((Get-DailyProxyHash @($script:sys,$script:en,$script:sel)) -eq $prior -and (Read-RuleMaintenanceFile (Get-DailyProxyReceiptPath)).Hash -eq $receipt) 'Failure must roll back native, env, selection and receipt'
    $script:failNative=$true;Reject {Set-UniversalProxy 'AlternateProxy'} '已恢复';Check ((Get-DailyProxyHash @($script:sys,$script:en,$script:sel)) -eq $prior) 'Native failure rollback'
    $oldSelection=$script:sel;$script:outsideSelectionAfterReceipt=$true;Reject {Set-UniversalProxy 'AlternateProxy'} '外部修改'
    Check ($script:sel.Key -eq 'external-fixture' -and (Get-SystemKey $script:sys) -eq 'Clash' -and (Read-RuleMaintenanceFile (Get-DailyProxyReceiptPath)).Hash -eq $receipt) 'Late external selection must survive rollback and receipt must be reverted'
    $script:sel=$oldSelection
    $script:endpoints.AlternateProxy='Stopped';Check (-not (Get-DailyProxyUndoPlan).CanApply) 'Stopped undo destination must refuse';$script:endpoints.AlternateProxy='Ready'
    $script:sys=[pscustomobject]@{Flags=15;Server=$script:sys.Server;Bypass=$script:sys.Bypass};Check (-not (Get-DailyProxyPlan 'AlternateProxy').CanApply) 'HTTP switch must not silently reset PAC'
    $count=$script:writes;Reject {Set-UniversalProxy 'Direct'} '自动代理';Check ($script:sys.Flags -eq 15 -and $script:writes -eq $count) 'Direct with automatic modes must reject without changing flags or variables'
    $script:sys=[pscustomobject]@{Flags=3;Server='127.0.0.1:7897';Bypass='<local>;company.local'}
    $script:viewsOverride=New-FixtureWindowsViews;$script:viewsOverride.Registry.Enabled=$false
    $plan=Get-DailyProxyPlan 'Clash';Check ($plan.CanApply -and -not $plan.NoChange -and $plan.Message -match '视图不一致') 'Same native target with different Windows view must offer explicit repair'
    $viewStatus=Get-ProxyStatus -TcpRows @();$viewState=Get-DailyProxyState $viewStatus;Check ($viewState.Headline -eq 'Windows 代理视图不一致' -and $viewState.NextStep -match '预览核对') 'UI must prioritize three-view disagreement over Direct or owner claims'
    Set-DailyProxy $plan -Confirmed|Out-Null;Check (-not (Get-DailyProxyContext).WindowsViews.Summary.Different) 'Explicit same-target repair must verify all three views'
    Check (-not (Get-DailyProxyUndoPlan).CanApply) 'Undo must not restore a divergent original Windows view'
    $script:sys=[pscustomobject]@{Flags=1;Server='127.0.0.1:7897';Bypass='<local>;company.local'}
    $script:viewsOverride=New-FixtureWindowsViews;$script:viewsOverride.Registry.Enabled=$true;$script:viewsOverride.Registry.Server='127.0.0.1:7897';$script:viewsOverride.WinHttpIE.Server='127.0.0.1:7897'
    $script:failSelection=$true
    Reject {Set-DailyProxy (Get-DailyProxyPlan 'Clash') -Confirmed} '原来的代理视图分歧无法安全还原'
    Check ((Get-SystemKey $script:sys) -eq 'Clash' -and -not (Get-DailyProxyContext).WindowsViews.Summary.Different) 'Failed receipt completion must retain verified repaired target instead of creating all-Direct rollback'
    $beforeRace=$script:sys;$oldSelection=$script:sel;$script:viewRaceOnNative=$true
    Reject {Set-UniversalProxy 'AlternateProxy'} '三个 Windows 代理视图'
    Check ($script:viewsOverride.Registry.Server -eq '127.0.0.1:19999' -and (Get-SystemKey $script:sys) -eq 'AlternateProxy') 'Failed post-write view verification must preserve external view edit without overwriting it in rollback'
    $script:viewsOverride=$null;$script:sys=$beforeRace;$script:sel=$oldSelection
    $script:viewRaceOnSelection=$true;Reject {Set-UniversalProxy 'AlternateProxy'} '完成前 Windows 代理视图'
    Check ($script:viewsOverride.Registry.Server -eq '127.0.0.1:19998' -and (Get-DailyProxyHash $script:sel) -eq (Get-DailyProxyHash $oldSelection)) 'Late view race must fail completion, preserve external view and roll back owned selection'
    $script:viewsOverride=$null;$script:sys=$beforeRace;$script:sel=$oldSelection
    Set-UniversalProxy 'Direct'|Out-Null;Check ($script:sys.Flags -eq 1 -and (Get-DailyProxyContext).WindowsViews.WinHttpIE.Key -eq 'Unset') 'Ordinary Direct must agree across three views'
    Check ((Get-DailyProxyHash $script:rules) -eq $initialRules) 'All paths must preserve program rules'
    # Exercise the real identity reader with an unreadable elevated service path.
    # Fixture file is an inert text file; it is never executed.
    $fixturePath=Join-Path $qa 'verge-mihomo.exe';[IO.File]::WriteAllText($fixturePath,'identity fixture')
    $script:Profiles.Profiles[0].CorePath=$fixturePath;$script:DataRoot=Join-Path $qa 'user-data'
    $script:pipeOwner=88;$script:cimCreated=[DateTime]::UtcNow
    function Get-GatewayControllerPID {$script:pipeOwner}
    function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$true;Rows=@([pscustomobject]@{State='Listen';LocalAddress='127.0.0.1';LocalPort=7897;OwningProcess=88})}}
    function Get-ProcessInventory($Id){[pscustomobject]@{Id=88;ProcessName='verge-mihomo';Path='';StartTime=[DateTime]::MinValue}}
    function Get-CimInstance($ClassName,$Filter,$Property,$ErrorAction){Check ($ClassName -eq 'Win32_Process' -and $Filter -eq 'ProcessId = 88' -and @($Property).Count -eq 2) 'Service fallback must query exact PID and limited properties';[pscustomobject]@{ProcessId=88;CreationDate=$script:cimCreated}}
    $identity=& $script:realDailyEndpoint 'Clash';Check ($identity.State -eq 'Ready') 'Elevated service identity must support exact pipe PID plus CIM creation time'
    $secondIdentity=& $script:realDailyEndpoint 'Clash';Check ($identity.Identity -ceq $secondIdentity.Identity) 'Identity must be stable across read-only observations'
    $script:cimCreated=$script:cimCreated.AddSeconds(1);$changedIdentity=& $script:realDailyEndpoint 'Clash';Check ($identity.Identity -cne $changedIdentity.Identity) 'PID reuse must change endpoint identity'
    $script:pipeOwner=99;Check ((& $script:realDailyEndpoint 'Clash').State -eq 'Unknown') 'Same process name with wrong OS pipe PID must refuse'
    $script:pipeOwner=0;$script:servicePID=77;$script:coreParent=77;$script:servicePath=Join-Path $qa 'clash-verge-service.exe';$script:serviceType='Own Process';$script:serviceAccount='LocalSystem'
    [IO.File]::WriteAllText($script:servicePath,'inert service identity fixture')
    function Get-CimInstance($ClassName,$Filter,$Property,$ErrorAction){
        if($ClassName -eq 'Win32_Service'){
            Check ($Filter -eq "Name = 'clash_verge_service'") 'SCM lookup must use the exact configured service name'
            return [pscustomobject]@{Name='clash_verge_service';State='Running';ProcessId=$script:servicePID;PathName=$script:servicePath;StartName=$script:serviceAccount;ServiceType=$script:serviceType}
        }
        if($Filter -eq 'ProcessId = 88'){return [pscustomobject]@{ProcessId=88;ParentProcessId=$script:coreParent;CreationDate=$script:cimCreated}}
        if($Filter -eq ('ProcessId = '+$script:servicePID)){return [pscustomobject]@{ProcessId=$script:servicePID;CreationDate=$script:cimCreated.AddMinutes(-1)}}
        throw 'unexpected process lookup'
    }
    $scmIdentity=& $script:realDailyEndpoint 'Clash';Check ($scmIdentity.State -eq 'Ready') 'SCM sibling image and exact parent identity must support elevated core'
    $script:servicePID=66;Check ((& $script:realDailyEndpoint 'Clash').State -eq 'Unknown') 'SCM changed service PID must refuse';$script:servicePID=77
    $script:coreParent=55;Check ((& $script:realDailyEndpoint 'Clash').State -eq 'Unknown') 'Changed core parent relationship must refuse';$script:coreParent=77
    $servicePathBefore=$script:servicePath;$script:servicePath=Join-Path $qa 'other-service.exe';Check ((& $script:realDailyEndpoint 'Clash').State -eq 'Unknown') 'Replaced SCM image path must refuse';$script:servicePath=$servicePathBefore
    [IO.File]::Move($script:servicePath,($script:servicePath+'.old'));[IO.File]::WriteAllText($script:servicePath,'replacement inert identity fixture')
    $changedScmIdentity=& $script:realDailyEndpoint 'Clash';Check ($changedScmIdentity.State -eq 'Ready' -and $scmIdentity.Identity -cne $changedScmIdentity.Identity) 'Replaced service file identity must invalidate existing plan'
    $script:servicePath=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'clash-verge-service\bin\clash-verge-service.exe'
    $protectedIdentity=& $script:realDailyEndpoint 'Clash';Check ($protectedIdentity.State -eq 'Ready') 'Exact protected official service layout must support OS service identity without file reads'
    $serviceIdentity=Get-GatewayServiceIdentity (Get-Profile 'Clash') (Get-ProcessInventory 88)
    Check ($serviceIdentity.Method -eq 'SCMProtected' -and $serviceIdentity.ConfiguredCoreFile -and -not $serviceIdentity.PSObject.Properties['CoreFile']) 'Protected SCM identity must distinguish configured core file from protected running image'
    $script:serviceAccount='fixture-user';Check ((& $script:realDailyEndpoint 'Clash').State -eq 'Unknown') 'Non-LocalSystem service must refuse';$script:serviceAccount='LocalSystem'
    $script:serviceType='Share Process';Check ((& $script:realDailyEndpoint 'Clash').State -eq 'Unknown') 'Shared service process must refuse';$script:serviceType='Own Process'
    $script:servicePath=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'unknown-service\bin\clash-verge-service.exe';Check ((& $script:realDailyEndpoint 'Clash').State -eq 'Unknown') 'Unknown ProgramData layout must refuse'
    $script:pipeOwner=88;$script:Profiles.Profiles[0].CorePath=(Join-Path $qa 'FlowSwitch.Core.exe');Check ((& $script:realDailyEndpoint 'Clash').State -eq 'Unsupported') 'Daily switching must never restore an old independent core'
    $script:DataRoot=$qa
    function Get-DailyProxyUndoPlan {throw 'FORBIDDEN UI ownership refresh'}
    function Get-ClientInterference {throw 'FORBIDDEN UI topology query'}
    function Get-TcpObservationSnapshot {throw 'FORBIDDEN UI TCP query'}
    $cheapState=Get-DailyProxyState ([pscustomobject]@{Key='Clash';EndpointReady=$true})
    Check ($cheapState.CanUndo -and $cheapState.UndoReason -match '点击后') 'UI state must only offer read-only undo preview without network queries'
    $stoppedState=Get-DailyProxyState ([pscustomobject]@{Key='Clash';EndpointReady=$false})
    Check ($stoppedState.NextStep -match '开始断网排查') 'stopped entry directs user to guided diagnosis'
    $offState=Get-DailyProxyState ([pscustomobject]@{Key='Direct';EnvConflict=$true})
    Check ($offState.Headline -match '程序仍有代理设置' -and $offState.NextStep -match '不要先清理') 'disabled system proxy does not hide inherited proxy settings'
    Write-Output ('PASS DailyProxy: '+$script:checks+' checks; Windows and process writes were stubbed; receipt files only in '+$qa)
}finally{
    # This unique fixture directory is the sole deletion target.
    if([IO.Path]::GetFullPath($qa).StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\FlowSwitch-DailyProxy-'),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $qa -Recurse -Force -ErrorAction SilentlyContinue}
}

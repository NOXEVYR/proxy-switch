$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-SelfDiagnosis-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$script:sharedApplicationRoutes=(Get-Item Function:Get-ApplicationRoutes).ScriptBlock
$script:sharedPathEquivalent=(Get-Item Function:Test-ProgramPathEquivalent).ScriptBlock
$script:checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++}
function New-SystemFixture {
    [pscustomobject]@{CheckedAt='fixture';SystemKey='current';CurrentEntry=[pscustomobject]@{Name='Current local entry';Key='current';Listening=$true;OwnerVerified=$true;ManualEnabled=$true};UserProxyEnvironment=[pscustomobject]@{State='Aligned';SetCount=3};HistoricalSelection=[pscustomobject]@{Available=$false;DifferentFromCurrent=$false};Issues=@();Targets=@([pscustomobject]@{Name='GitHub';Stage='https-response';HttpCode=200});ApplicationProxyViews=[pscustomobject]@{Different=$false;Registry='开启';WinHttpIE='开启';WinINET='开启'};ExternalMihomo=$null;RepairAction='';RepairText='';Message='Fixture detail'}
}
function Summarize($Fixture){Add-SystemNetworkDiagnosisSummary $Fixture -Probe;$Fixture}
$healthy=Summarize (New-SystemFixture)
Check ($healthy.Conclusion.State -eq 'ChecksPassed' -and -not $healthy.Conclusion.AuthenticationVerified) 'scoped HTTPS evidence is not represented as checks passed or overclaims authentication'
Check ($healthy.Checks.Count -eq 4 -and ($healthy.Checks|Where-Object Layer -eq 'Program').State -eq 'NotChecked') 'four-layer summary loses the unselected target-program boundary'
Check ($healthy.Summary -match '系统设置.*当前入口.*代理通路' -or ($healthy.Summary -match '系统设置' -and $healthy.Summary -match '当前入口' -and $healthy.Summary -match '代理通路')) 'readable summary lacks the diagnostic layers'
Check ($healthy.NextSteps.Count -gt 0 -and $healthy.Summary -match '下一步') 'healthy result has no real-request next step'
Check ($healthy.Summary.IndexOf('下一步') -lt $healthy.Summary.IndexOf('1. 系统设置') -and $healthy.Summary -match '检查对象：当前电脑') 'next actions are buried after layer evidence or scope is split across an unintended line'

$down=New-SystemFixture;$down.CurrentEntry.Listening=$false;$down.Targets=@();$down.Issues=@([pscustomobject]@{Code='system-entry-down';Message='当前系统入口未监听。'})
$down=Summarize $down
Check ($down.Conclusion.State -eq 'ProblemFound' -and $down.Findings[0].Code -eq 'system-entry-down') 'confirmed unlistening current endpoint does not lead the actionable findings'
Check (($down.Checks|Where-Object Layer -eq 'Entry').State -eq 'ProblemFound' -and $down.NextSteps[0].Text -match '启动已配置') 'dead entry has no precise service-start next step'

$unknown=New-SystemFixture;$unknown.CurrentEntry.OwnerVerified=$false;$unknown.Issues=@([pscustomobject]@{Code='system-entry-unknown';Message='监听或归属未知。'})
$unknown=Summarize $unknown
Check ($unknown.Conclusion.State -eq 'ChecksPassed' -and ($unknown.Findings|Where-Object Code -eq 'system-entry-unknown').Level -eq 'Info') 'unknown ownership with actual HTTPS response falsely reports route failure'
Check ($unknown.Summary -match '归属未知' -and ($unknown.Checks|Where-Object Layer -eq 'Entry').State -eq 'ChecksPassed') 'listening evidence and ownership boundaries are not separated'
Check (($unknown.Checks|Where-Object Layer -eq 'Entry').Evidence -notmatch '监听或归属未知' -and ($unknown.Checks|Where-Object Layer -eq 'Entry').Evidence -match '^TCP 快照确认监听') 'passed listening layer is led by an old combined unknown-listener/owner message'

$views=New-SystemFixture;$views.ApplicationProxyViews.Different=$true;$views.Issues=@([pscustomobject]@{Code='windows-proxy-view-mismatch';Message='三种代理视图不一致。'})
$views=Summarize $views
Check ($views.Conclusion.State -eq 'ProblemFound' -and $views.Findings[0].Code -eq 'windows-proxy-view-mismatch' -and ($views.Checks|Where-Object Layer -eq 'Settings').State -eq 'ProblemFound') 'confirmed proxy API view mismatch is buried instead of becoming the leading factual problem'
Check ($views.NextSteps[0].Text -match '原代理客户端' -and $views.NextSteps[0].Text -notmatch '补全局') 'proxy view mismatch recommends unrelated environment injection'

$unset=New-SystemFixture;$unset.UserProxyEnvironment.State='Unset';$unset.UserProxyEnvironment.SetCount=0;$unset.Issues=@([pscustomobject]@{Code='environment-mismatch';Message='用户变量未设置。'})
$unset=Summarize $unset
Check ($unset.Conclusion.State -eq 'ChecksPassed' -and ($unset.Findings|Where-Object Code -eq 'environment-mismatch').Level -eq 'Info') 'unset user environment is interpreted as a desktop network failure'
Check (-not ($unset.Findings|Where-Object Code -eq 'environment-mismatch').NextStep -and $unset.NextSteps.Code -notcontains 'environment-mismatch') 'unset user environment takes up actionable next steps despite requiring no change'

foreach($code in @(401,403,404,421,429,500)){
    $limited=New-SystemFixture;$limited.Targets=@([pscustomobject]@{Name='OpenAI API';Stage='https-response';HttpCode=$code});$limited=Summarize $limited
    Check ($limited.Conclusion.State -eq 'ChecksPassed' -and ($limited.Findings|Where-Object Code -eq 'target-response-OpenAI API').Level -eq 'Info' -and $limited.Findings.Code -contains 'https-OpenAI API') 'a fixed unauthenticated target response became a global proxy failure or lost HTTPS-layer evidence'
}
$tun=New-SystemFixture;$tun.Issues=@([pscustomobject]@{Code='external-proxy-control';Message='TUN exists'});$tun=Summarize $tun
Check ($tun.Conclusion.State -eq 'ChecksPassed' -and ($tun.Findings|Where-Object Code -eq 'external-proxy-control').Level -eq 'Info') 'TUN existence falsely means global network failure'
$history=New-SystemFixture;$history.HistoricalSelection=[pscustomobject]@{Available=$true;Key='old';DifferentFromCurrent=$true;IsHistorical=$true};$history=Summarize $history
Check ($history.Conclusion.State -eq 'ChecksPassed' -and $history.Findings.Code -contains 'historical-selection' -and $history.Summary -match '历史意图') 'historical choice replaces current entry evidence'
$noProbe=New-SystemFixture;$noProbe.Targets=@();Add-SystemNetworkDiagnosisSummary $noProbe
Check (($noProbe.Checks|Where-Object Layer -eq 'Route').State -eq 'NotChecked') 'passive result claims active probe coverage'

$stalled=New-SystemFixture
$stalled.Targets=@([pscustomobject]@{Name='GitHub';Stage='probe-timeout';ConnectCode=0;CurlExitCode=28},[pscustomobject]@{Name='OpenAI API';Stage='probe-timeout';ConnectCode=200;CurlExitCode=28})
$stalled=Summarize $stalled
Check ($stalled.ForwardingState -eq 'AllTimeout' -and $stalled.CurrentEntry.Listening -and $stalled.Conclusion.State -eq 'NeedsRetest' -and $stalled.Findings.Code -contains 'system-forwarding-timeout') 'Listening and forwarding timeout must remain separate and limited to this round'
Check ($stalled.Summary -match 'CONNECT=0' -and $stalled.Summary -match 'CONNECT 200' -and $stalled.NextSteps[0].Text -match '原代理/VPN') 'CONNECT-before and after timeouts require distinct evidence and upstream guidance'
$stalled.Targets[0]=[pscustomobject]@{Name='GitHub';Stage='https-response';ConnectCode=200;HttpCode=204}
$stalled=Summarize $stalled
Check ($stalled.ForwardingState -eq 'PartialResponse' -and $stalled.Findings.Code -notcontains 'system-forwarding-timeout' -and $stalled.Targets.Count -eq 2 -and $stalled.Conclusion.State -eq 'NeedsRetest') 'One response must not mask another timeout or become all-target failure'

# Program API uses fresh shared observers; transport and OS mutations are forbidden.
$script:systemCalls=0;$script:appCalls=0;$script:tcpCalls=0;$script:lastProbe=$false
function Get-NetworkDiagnosis {param([switch]$Probe);$script:systemCalls++;$script:lastProbe=[bool]$Probe;Summarize (New-SystemFixture)}
function Get-TcpObservationSnapshot {$script:tcpCalls++;[pscustomobject]@{Available=$true;Rows=@()}}
$script:appRows=@();$script:appsAvailable=$true
function Get-ApplicationRoutes {param($TcpRows,[bool]$TcpAvailable);$script:appCalls++;[pscustomobject]@{Rows=$script:appRows;ProcessesAvailable=$false;TcpAvailable=$script:appsAvailable;RulesAvailable=$true;ConnectionsAvailable=$true}}
function Set-SystemSnapshot {throw 'No Windows writes permitted'}
function Set-UserProxyEnv {throw 'No user environment writes permitted'}
function Test-ProgramPathEquivalent($Left,$Right){$Left -ieq $Right}
function Start-ManagedProgram {throw 'No application launch permitted'}
function Wait-ManagedProgramIngressReady {throw 'No launch readiness or service startup permitted'}
function Get-ManagedProgramIngress($Path){[pscustomobject]@{id='fixture';path=$Path;port=22111;route='Follow'}}
function Get-RoutingSnapshot {[pscustomobject]@{programIngresses=@((Get-ManagedProgramIngress 'C:\Fixture\Editor.exe'))}}
function Invoke-AppRouter {[pscustomobject]@{available=$true;rulesAvailable=$true;programIngresses=@([pscustomobject]@{id='fixture';path='C:\Fixture\Editor.exe';port=22111;route='Follow';loaded=$true;ready=$true;effectiveRoute='Direct'})}}
function Test-NetworkTargets($Profile){@([pscustomobject]@{Name='Fixture';Stage='https-response';HttpCode=204})}
function New-ProgramFixture([string]$State='Idle'){
    [pscustomobject]@{Path='C:\Fixture\Editor.exe';SavedPath='C:\Fixture\Editor.exe';PIDs='100,101';ObservationState=$State;Policy='Follow';Actual='运行中 · 未观察到 TCP';Coverage='verified family TCP snapshot';Mode='observe';HasSavedRule=$false;RuleLoaded=$false;Loaded=$false;RequiresRepair=$false;NeedsEntryConnection=$false;ProgramEntryState='Unknown';Pending=0;ConnectionDetails=@();ObservedAt='fresh-fixture'}
}
$row=New-ProgramFixture 'NotRunning';$row.PIDs='';$script:appRows=@($row)
$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Program.Running -eq $false -and $result.Conclusion.State -eq 'NeedsRetest' -and $result.Findings.Code -contains 'program-not-running') 'non-running program does not produce an actionable result'
Check ($script:lastProbe -and $script:appCalls -eq 1 -and $script:tcpCalls -eq 1 -and $result.Message -match '流向请求') 'program check uses stale display data or attributes manager probes to the target application'

$script:appRows=@(New-ProgramFixture)
$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Program.Running -and $result.Findings.Code -contains 'program-no-external-connections' -and $result.NextSteps[0].Text -match '发起一次失败请求') 'idle program is described as broken instead of asking for a new request'

$row=New-ProgramFixture 'Observed';$row.Mode='engine';$row.HasSavedRule=$true;$row.RuleLoaded=$true;$row.ProgramEntryState='NeedsEntry';$row.NeedsEntryConnection=$true;$script:appRows=@($row)
$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Conclusion.State -ne 'ProblemFound' -and ($result.Findings|Where-Object Code -eq 'program-entry-bypassed').Level -eq 'Info') 'saved or loaded engine rule is treated as active despite bypassed ingress'
$row.NeedsEntryConnection=$false;$row.ProgramEntryState='Unknown';$row.ConnectionDetails=@([pscustomobject]@{State='Established';IngressKind='Proxy';EvidenceSource='RegisteredEndpoint';ActualRoute='other-proxy'})
$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Conclusion.State -ne 'ProblemFound' -and ($result.Findings|Where-Object Code -eq 'program-other-proxy-entry').Level -eq 'Info' -and $result.Evidence.ControllerVerifiedCount -eq 0) 'registered endpoint TCP is falsely considered adherence to saved engine routing'

$row=New-ProgramFixture 'Observed';$row.Mode='managed';$row.HasSavedRule=$true;$row.RuleLoaded=$true;$row.Loaded=$true;$row.ProgramEntryState='Observed';$row.ConnectionDetails=@([pscustomobject]@{State='Established';IngressKind='Managed';EvidenceSource='Controller';ActualRoute='upstream'})
$script:appRows=@($row);$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Conclusion.State -eq 'ChecksPassed' -and $result.Evidence.ControllerVerifiedCount -eq 1 -and -not $result.Evidence.AuthenticationVerified) 'precise current program controller evidence loses scoped success or overclaims login'
Check ($result.Checks.Count -eq 4 -and ($result.Checks|Where-Object Layer -eq 'Program').State -eq 'ChecksPassed' -and -not $result.RepairAction) 'program-scoped result accidentally authorizes a repair or lacks four-layer checks'
Check ($result.Summary.Contains($result.Program.Actual) -and $result.Summary.Contains($result.Program.Coverage) -and $result.Summary -match '系统.*独立系统详情' -and $result.SystemDiagnosis.CurrentEntry.Name -eq 'Current local entry') 'program summary loses its evidence or mixes independent system details into the target conclusion'
$row.PIDs=@('100, 101',' 102 ');$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Program.ProcessCount -eq 3) 'comma spaces or array PID representation loses verified process counts'
$row.Loaded=$false;$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Conclusion.State -eq 'NeedsRetest' -and $result.Findings.Code -contains 'program-policy-unconfirmed') 'controller connection existence falsely certifies all saved policy when the shared observer disagrees'
$row.Loaded=$true;$row|Add-Member NoteProperty FamilyUnknownIds @(999) -Force;$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Conclusion.State -eq 'NeedsRetest' -and $result.Findings.Code -contains 'program-family-coverage-unknown' -and $result.Program.ProcessCount -eq 3) 'unknown family member is claimed or scoped connections certify the entire family'
$row.FamilyUnknownIds=@()
function Get-NetworkDiagnosis {
    param([switch]$Probe)
    $fixture=New-SystemFixture;$fixture.Targets=@([pscustomobject]@{Name='OpenAI API';Stage='https-response';HttpCode=401},[pscustomobject]@{Name='OpenAI API root';Stage='https-response';HttpCode=421})
    $fixture.ExternalMihomo=[pscustomobject]@{State='observed';Rows=@([pscustomobject]@{Host='chatgpt.com';Type='HTTP';Chains=@('选择节点','Node A');Source='ChatGPT（本机 TCP 对应）';Count=2},[pscustomobject]@{Host='ws.chatgpt.com';Type='Tun';Chains=@('Private unverified node');Source='来源未知';Count=1})}
    Summarize $fixture
}
$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Conclusion.State -eq 'ChecksPassed' -and @($result.Findings|Where-Object {$_.Code -like 'target-response-*' -and $_.Level -ne 'Info'}).Count -eq 0) 'healthy ordinary app is misdiagnosed because unrelated fixed API probes returned 401 or 421'
Check ($result.Summary -notmatch 'ChatGPT 连接旁证|Node A|Private unverified node' -and $result.SystemDiagnosis.Summary -match 'ChatGPT 连接旁证.*独立范围' -and $result.SystemDiagnosis.Summary -match '选择节点 → Node A' -and $result.SystemDiagnosis.Summary -notmatch 'Private unverified node') 'ordinary program summary includes unrelated ChatGPT node or system summary loses verified-only supplementary scope'
Check ($result.NextSteps[0].Code -eq 'program-controller-connections') 'unrelated fixed target or unset environment guidance outranks target-program evidence'
$row|Add-Member NoteProperty PolicyName 'Readable B' -Force;$row.RequiresRepair=$true;$row|Add-Member NoteProperty IdentityReason 'SameFile' -Force;$row|Add-Member NoteProperty CanRepair $true -Force
$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Conclusion.Title -match '保存的程序记录' -and $result.Program.RecordRequiresReview -and $result.Program.RecordIdentityReason -eq 'SameFile' -and $result.Program.Policy -eq 'Readable B' -and $result.Evidence.ControllerVerifiedCount -eq 1 -and $result.Findings.Code -contains 'program-controller-connections') 'saved identity record issue is misrepresented as proven software network failure or suppresses independent live evidence'
$row.RequiresRepair=$false
$row.ConnectionDetails+=@([pscustomobject]@{State='Established';IngressKind='Outside';EvidenceSource='TcpOnly';ActualRoute='Unknown'})
$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Conclusion.State -eq 'NeedsRetest' -and $result.Findings.Code -contains 'program-partial-coverage' -and $result.Evidence.EstablishedCount -eq 2) 'one confirmed connection falsely covers all unknown connections'

$row=New-ProgramFixture 'Idle';$row.Pending=2;$script:appRows=@($row);$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Findings.Code -contains 'program-pending' -and @($result.Findings|Where-Object Level -eq 'Problem').Count -eq 0) 'pending TCP snapshot is described as permanent failure'
$row=New-ProgramFixture 'Unknown';$row.PIDs='';$script:appRows=@($row);$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($null -eq $result.Program.Running -and $result.Conclusion.State -eq 'NeedsRetest') 'unknown process state is described as definitely not running'
$script:appRows=@((New-ProgramFixture),(New-ProgramFixture))
$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Editor.exe'
Check ($result.Findings.Code -contains 'program-observation-unknown' -and $result.Evidence.ControllerVerifiedCount -eq 0) 'ambiguous catalog rows are silently assigned to one target'
$script:appRows=@();$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Unlisted.exe'
Check ($result.Conclusion.State -eq 'NeedsRetest' -and $result.Findings.Code -contains 'program-observation-unknown') 'unavailable catalog identity throws instead of producing a result'
$result=Get-ProgramNetworkDiagnosis ''
Check ($result.Conclusion.State -eq 'NeedsRetest') 'missing object selection crashes program diagnosis'
function Get-NetworkDiagnosis {param([switch]$Probe);throw 'fixture configuration drift'}
$result=Get-ProgramNetworkDiagnosis 'C:\Fixture\Unlisted.exe'
Check ($result.Conclusion.State -eq 'NeedsRetest' -and $result.Findings.Code -contains 'system-diagnosis-unknown') 'system drift throws through the program result UI'
Check (($result|ConvertTo-Json -Depth 10) -notmatch 'fixture configuration drift') 'raw exception content leaks through diagnostic details'

# Exercise the real application/family/connection observers with isolated file
# identities and synthetic TCP/controller rows, including an uncatalogued CLI.
Set-Item Function:Get-ApplicationRoutes $script:sharedApplicationRoutes
Set-Item Function:Test-ProgramPathEquivalent $script:sharedPathEquivalent
. (Join-Path $PSScriptRoot 'ProgramFamilyTracking.ps1')
function Get-NetworkDiagnosis {param([switch]$Probe);Summarize (New-SystemFixture)}
function Get-RegisteredProgramPackages {return @()}
function Get-SystemSnapshot {[pscustomobject]@{Flags=3;Server='127.0.0.1:18790'}}
function Test-ManagedProgramSession {return $true}
$appDir=Join-Path $qa 'app';$helperDir=Join-Path $qa 'runtime'
foreach($dir in @($appDir,$helperDir)){[void][IO.Directory]::CreateDirectory($dir)}
$editor=Join-Path $appDir 'Editor.exe';$helper=Join-Path $helperDir 'Helper.exe'
foreach($file in @($editor,$helper)){[IO.File]::WriteAllText($file,'identity fixture only; never executed')}
$birth=[DateTime]::UtcNow.AddMinutes(-1)
function ProcessFixture([int]$Id,[int]$Parent,[string]$Path,[bool]$Window=$false){[pscustomobject]@{Id=$Id;ParentId=$Parent;Path=$Path;PathStatus='Available';StartTime=$birth.AddSeconds($Id);ProcessName=[IO.Path]::GetFileNameWithoutExtension($Path);MainWindowHandle=$(if($Window){[IntPtr]1}else{[IntPtr]::Zero})}}
function TcpFixture([int]$Owner,[int]$Source,[int]$Port,[string]$Address='127.0.0.1'){[pscustomobject]@{OwningProcess=$Owner;State='Established';LocalAddress='127.0.0.1';LocalPort=$Source;RemoteAddress=$Address;RemotePort=$Port}}
function ControllerFixture([string]$Path,[int]$Source){[pscustomobject]@{path=$Path;sourceAddress='127.0.0.1';sourcePort=$Source;network='tcp';inbound='HTTP';ingressId='diagnostic-fixture';inboundName='FS-Program-diagnostic-fixture';route='b';expectedRoute='b';policyMatches=$true}}
$script:Profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(
    @{Id='gateway';Name='Gateway';Protocol='http';Host='127.0.0.1';Port=18790;CorePath='C:\Fixture\core.exe'},
    @{Id='b';Name='B';Protocol='http';Host='127.0.0.1';Port=21002}
);Routing=@{Adapter='standalone';ProfileId='gateway';UnifiedMode='gateway'}})
$script:liveIngress=@([pscustomobject]@{id='diagnostic-fixture';path=$editor;port=22111;route='b';managed=$true;loaded=$true;ready=$true;effectiveRoute='b'})
$script:liveProcesses=@((ProcessFixture 10 1 $editor $true),(ProcessFixture 11 10 $helper),(ProcessFixture 20 1 $helper))
$script:liveTcp=@((TcpFixture 10 50010 22111),(TcpFixture 11 50011 22111),(TcpFixture 20 50020 443 '192.0.2.1'))
$script:liveConnections=@((ControllerFixture $editor 50010),(ControllerFixture $helper 50011))
function Get-ProcessInventory {return @($script:liveProcesses)}
function Get-RoutingSnapshot {[pscustomobject]@{entries=@();programIngresses=@($script:liveIngress);launchEntries=@();defaultRoute='b'}}
function Get-ManagedProgramIngress($Path){$script:liveIngress|Where-Object path -IEQ $Path|Select-Object -First 1}
function Invoke-AppRouter {[pscustomobject]@{available=$true;rulesAvailable=$true;connectionsAvailable=$true;proxiesAvailable=$true;programIngresses=@($script:liveIngress);entries=@();connections=@($script:liveConnections);defaultRoute='b';defaultLoaded=$true}}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$true;Rows=@($script:liveTcp)}}
$before=Get-RoutingSnapshot|ConvertTo-Json -Depth 8 -Compress
$result=Get-ProgramNetworkDiagnosis $editor
Check ($result.Program.Running -and $result.Program.ProcessCount -eq 2 -and $result.Evidence.ControllerVerifiedCount -eq 2 -and $result.Conclusion.State -eq 'ChecksPassed') 'real shared observers lose precise verified cross-directory family/controller evidence or claim an unrelated helper instance'
Check ($result.Program.Actual -match 'B' -and $result.Summary.Contains($result.Program.Coverage)) 'real observation route and family scope are hidden from the readable program result'
$script:liveIngress=@();$script:liveConnections=@();$script:liveProcesses=@((ProcessFixture 20 1 $helper));$script:liveTcp=@((TcpFixture 20 50020 443 '192.0.2.1'))
$result=Get-ProgramNetworkDiagnosis $helper
Check ($result.Program.Running -and $result.Program.ProcessCount -eq 1 -and $result.Findings.Code -contains 'program-tcp-only' -and $result.Evidence.ControllerVerifiedCount -eq 0) 'uncatalogued non-windowed program fallback loses its verified process or invents controller evidence'
$script:liveIngress=@([pscustomobject]@{id='diagnostic-fixture';path=$editor;port=22111;route='b';managed=$true;loaded=$true;ready=$true;effectiveRoute='b'})
Check ((Get-RoutingSnapshot|ConvertTo-Json -Depth 8 -Compress) -ceq $before) 'program diagnosis modifies shared routing records'
Write-Output ('PASS: '+$script:checks+' self-service diagnostic conclusions and program-path checks; isolated observations only, no real network or application changes.')

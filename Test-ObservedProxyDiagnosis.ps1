param([string]$FixturePath='')
$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-ObservedProxy-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$script:checks=0
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Set-SystemSnapshot {throw 'No Windows settings writes'}
function Set-UserProxyEnv {throw 'No environment writes'}
function Start-ManagedProgram {throw 'No application launch'}
function Ensure-ManagedGateway {throw 'No service launch'}
function Wait-ManagedProgramIngressReady {throw 'No launch readiness'}
[void][IO.Directory]::CreateDirectory($qa)
$appDir=Join-Path $qa 'app';$otherDir=Join-Path $qa 'other'
foreach($directory in @($appDir,$otherDir)){[void][IO.Directory]::CreateDirectory($directory)}
$app=Join-Path $appDir 'Editor.exe';$owner=Join-Path $qa 'Proxy.exe';$other=Join-Path $otherDir 'Editor.exe'
foreach($file in @($app,$owner,$other)){[IO.File]::WriteAllText($file,'identity-only fixture; never executed')}
$script:birth=[DateTime]::UtcNow.AddMinutes(-1)
$script:row=[pscustomobject]@{Path=$app;SavedPath=$app;PIDs='100';ObservationState='Observed';Mode='managed';HasSavedRule=$true;RuleLoaded=$true;Loaded=$true;RequiresRepair=$false;Policy='a';ProgramEntryState='NeedsEntry';NeedsEntryConnection=$true;Pending=0;Actual='external B';Coverage='exact TCP';ConnectionDetails=@()}
$script:detail=[pscustomobject]@{PID=100;Path=$app;State='Established';LocalAddress='127.0.0.1';LocalPort=50100;RemoteAddress='127.0.0.1';RemotePort=22002;IngressKind='Proxy';IngressId='b';EvidenceSource='RegisteredEndpoint';ActualRoute='b'}
$script:row.ConnectionDetails=@($script:detail)
$script:settings=[pscustomobject]@{Profiles=@([pscustomobject]@{Id='a';Name='A';Protocol='http';Host='127.0.0.1';Port=22001},[pscustomobject]@{Id='b';Name='B';Protocol='http';Host='127.0.0.1';Port=22002;CorePath=$owner});Routing=[pscustomobject]@{Adapter='standalone';ProfileId='a'}}
$script:Profiles=$script:settings
$script:ingress=[pscustomobject]@{id='managed-a';path=$app;port=22003;route='a';loaded=$true;ready=$true;effectiveRoute='a'}
$script:processes=@([pscustomobject]@{Id=100;Path=$app;PathStatus='Available';StartTime=$script:birth},[pscustomobject]@{Id=200;Path=$owner;PathStatus='Available';StartTime=$script:birth})
$script:tcp=@([pscustomobject]@{OwningProcess=100;State='Established';LocalAddress='127.0.0.1';LocalPort=50100;RemoteAddress='127.0.0.1';RemotePort=22002},[pscustomobject]@{OwningProcess=200;State='Listen';LocalAddress='127.0.0.1';LocalPort=22002;RemoteAddress='0.0.0.0';RemotePort=0},[pscustomobject]@{OwningProcess=200;State='Listen';LocalAddress='127.0.0.1';LocalPort=22003;RemoteAddress='0.0.0.0';RemotePort=0})
$script:tcpAvailable=$true;$script:probePorts=@();$script:drift='';$script:systemProbes=0
function Read-ProfileSettings {$script:settings}
function Get-RegisteredProgramPackages {return @()}
function Get-ProcessInventory([int]$Id=0){if($Id){@($script:processes|Where-Object {$_.Id -eq $Id})}else{@($script:processes)}}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$script:tcpAvailable;Rows=@($script:tcp)}}
function Get-ApplicationRoutes {param($TcpRows,$TcpAvailable);[pscustomobject]@{Rows=@($script:row);TcpAvailable=$script:tcpAvailable;ProcessesAvailable=$true}}
function Get-RoutingSnapshot {[pscustomobject]@{programIngresses=@($script:ingress);entries=@();defaultRoute='a'}}
function Get-ManagedProgramIngress($Path){$script:ingress}
function Invoke-AppRouter {param($Request,$TimeoutMilliseconds);Check ($Request.action -eq 'status') 'Only status is authorized';[pscustomobject]@{available=$true;rulesAvailable=$true;programIngresses=@($script:ingress)}}
function Get-NetworkDiagnosis {
    param([switch]$Probe)
    if($Probe){$script:systemProbes++}
    $f=[pscustomobject]@{CurrentEntry=[pscustomobject]@{Name='A system';Listening=$true;OwnerVerified=$true};HistoricalSelection=[pscustomobject]@{DifferentFromCurrent=$false};Issues=@();Targets=@([pscustomobject]@{Name='A';Stage='https-response';HttpCode=204});UserProxyEnvironment=[pscustomobject]@{State='Unset'};RepairAction='';ApplicationProxyViews=$null;ExternalMihomo=$null;Message=''}
    Add-SystemNetworkDiagnosisSummary $f -Probe:$Probe;$f
}
$script:realTargets=${function:Test-NetworkTargets}
function Targets([string]$Stage='probe-timeout',[int]$Connect=0,[int]$Code=0){@('GitHub','OpenAI API')|ForEach-Object {[pscustomobject]@{Name=$_;Stage=$Stage;ConnectCode=$Connect;HttpCode=$Code;CurlExitCode=$(if($Stage -eq 'probe-timeout'){28}else{0});Seconds=1;AuthenticationVerified=$false}}}
$script:bTargets=@(Targets)
function Test-NetworkTargets($Profile){
    $script:probePorts+=@($Profile.Port)
    if($Profile.Port -ne $script:settings.Profiles[1].Port){return @(Targets 'https-response' 200 204)}
    switch($script:drift){
        'process'{$script:processes[0].StartTime=$script:birth.AddSeconds(10)}
        'owner'{$script:processes[1].StartTime=$script:birth.AddSeconds(10)}
        'config'{$script:settings.Profiles[1].Name='changed'}
        'port'{$script:tcp[1].OwningProcess=201}
        'exit'{$script:processes=@($script:processes|Where-Object {$_.Id -ne 100})}
        'closed'{$script:tcp=@($script:tcp|Where-Object {$_.State -ne 'Established'})}
        'switched'{$script:tcp[0].RemotePort=22004}
        'helper'{$script:processes+=@([pscustomobject]@{Id=150;ParentId=100;Path=$script:row.Path;PathStatus='Available';StartTime=$script:birth.AddSeconds(5)})}
        'truncated'{foreach($id in 500..630){$script:processes+=@([pscustomobject]@{Id=$id;ParentId=100;Path=$other;PathStatus='Available';StartTime=$script:birth.AddSeconds(5)})}}
        'child-switch'{
            $script:processes+=@([pscustomobject]@{Id=150;ParentId=100;Path=$script:row.Path;PathStatus='Available';StartTime=$script:birth.AddSeconds(5)})
            $script:tcp=@($script:tcp|Where-Object {$_.State -ne 'Established'})
            $script:tcp+=@([pscustomobject]@{OwningProcess=150;State='Established';LocalAddress='127.0.0.1';LocalPort=50102;RemoteAddress='127.0.0.1';RemotePort=22004})
        }
    }
    @($script:bTargets)
}
$r=Get-ProgramNetworkDiagnosis $app
Check ($r.ProbeScope.State -eq 'Ready' -and $r.ProbeScope.ForwardingState -eq 'HttpsResponse' -and $r.SystemDiagnosis.ForwardingState -eq 'HttpsResponse') 'A fixed and system scopes remain healthy and independent'
Check ($r.ObservedProxyScope.State -eq 'Ready' -and $r.ObservedProxyScope.Port -eq 22002 -and $r.ObservedProxyScope.Listening -eq $true -and $r.ObservedProxyScope.ForwardingState -eq 'AllTimeout') 'B actual entry stall must not borrow healthy A'
Check ($r.Findings.Code -contains 'observed-proxy-forwarding-timeout' -and $r.Summary -match 'HTTPS代测均超时' -and $r.NextSteps[0].Text -match '原代理/VPN') 'Listening stall needs scoped upstream guidance'
Check (($r.Findings|Where-Object Code -eq 'program-other-proxy-entry').Level -eq 'Info' -and ($r.Findings|Where-Object Code -eq 'program-entry-bypassed').Level -eq 'Info' -and $r.Conclusion.State -ne 'ProblemFound' -and $script:systemProbes -eq 0) 'Control coverage difference cannot become disconnection or force system fallback'
$script:bTargets=@(Targets 'https-response' 200 401);$r=Get-ProgramNetworkDiagnosis $app
Check ($r.ObservedProxyScope.ForwardingState -eq 'HttpsResponse' -and -not $r.ObservedProxyScope.AuthenticationVerified -and $r.Conclusion.State -ne 'ProblemFound') '401 proves HTTPS only, and healthy bypass does not become a network Problem'
$script:bTargets=@((Targets 'https-response' 200 204)[0],(Targets)[1]);$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.ForwardingState -eq 'PartialResponse' -and $s.Targets.Count -eq 2 -and $s.Targets[1].Stage -eq 'probe-timeout') 'Partial success must preserve both target outcomes'
$script:baseline=[pscustomobject]@{Settings=$script:settings;Row=$script:row;Processes=$script:processes;Tcp=$script:tcp}|ConvertTo-Json -Depth 15
function Reset-Fixture {
    $x=$script:baseline|ConvertFrom-Json;$script:settings=$x.Settings;$script:Profiles=$script:settings;$script:row=$x.Row;$script:processes=@($x.Processes);foreach($process in $script:processes){$process.StartTime=[DateTime]$process.StartTime};$script:tcp=@($x.Tcp);$script:tcpAvailable=$true;$script:drift='';$script:bTargets=@(Targets)
}
Reset-Fixture
$helperDir=Join-Path $qa 'runtime';[void][IO.Directory]::CreateDirectory($helperDir)
$helper=Join-Path $helperDir 'Helper.exe';[IO.File]::WriteAllText($helper,'cross-directory identity fixture; never executed')
$script:processes+=@([pscustomobject]@{Id=101;ParentId=100;Path=$app;PathStatus='Available';StartTime=$script:birth.AddSeconds(1)},[pscustomobject]@{Id=102;ParentId=101;Path=$helper;PathStatus='Available';StartTime=$script:birth.AddSeconds(2)})
$script:row.PIDs='100,101,102'
$script:row.ConnectionDetails[0].PID=101;$script:tcp[0].OwningProcess=101
$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'Ready') 'Root with no socket: same-image verified child may provide the actual external entry'
$script:row.ConnectionDetails[0].PID=102;$script:row.ConnectionDetails[0].Path=$helper;$script:tcp[0].OwningProcess=102
$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'Ready') 'Root with no socket: cross-directory backend requires the complete fresh verified parent chain'
$script:processes[3].ParentId=999;$before=$script:probePorts.Count;$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -ne 'Ready' -and $script:probePorts.Count -eq $before) 'Shared runtime path without its verified family chain must not be claimed'
Reset-Fixture
foreach($case in @('unknown','same-name','duplicate','duplicate-id','multiple','port-replaced','wrong-socket','wrong-pid','remote','managed-port','missing-file','ambiguous-row','unknown-member','config-before')){
    Reset-Fixture
    switch($case){
        'unknown'{$script:tcpAvailable=$false}
        'same-name'{$script:processes[0].Path=$other}
        'duplicate'{$script:settings.Profiles+=@($script:settings.Profiles[1])}
        'duplicate-id'{$script:settings.Profiles+=@([pscustomobject]@{Id='b';Protocol='http';Host='127.0.0.1';Port=22004})}
        'multiple'{$script:settings.Profiles+=@([pscustomobject]@{Id='c';Protocol='http';Host='127.0.0.1';Port=22004});$script:tcp+=@([pscustomobject]@{OwningProcess=100;State='Established';LocalAddress='127.0.0.1';LocalPort=50101;RemoteAddress='127.0.0.1';RemotePort=22004})}
        'port-replaced'{$script:tcp[1].OwningProcess=999}
        'wrong-socket'{$script:tcp[0].LocalPort=50101}
        'wrong-pid'{$script:row.ConnectionDetails[0].PID=999}
        'remote'{$script:row.ConnectionDetails[0].RemoteAddress='192.0.2.1'}
        'managed-port'{$script:ingress.port=22002}
        'missing-file'{$script:row.Path=Join-Path $qa 'missing.exe'}
        'unknown-member'{$script:row|Add-Member NoteProperty FamilyUnknownIds @(100)}
        'config-before'{$script:Profiles=$script:settings|ConvertTo-Json -Depth 12|ConvertFrom-Json;$script:settings.Profiles[1].Name='changed before check'}
    }
    $before=$script:probePorts.Count;$s=Get-ObservedProxyDiagnosticScope $script:row ($case -eq 'ambiguous-row')
    Check ($s.State -ne 'Ready' -and $s.ForwardingState -eq 'NotChecked' -and $before -eq $script:probePorts.Count) ($case+': unknown or ambiguous evidence must not probe')
    $script:ingress.port=22003
}
foreach($case in @('process','owner','config','port','exit')){
    Reset-Fixture;$script:drift=$case;$s=Get-ObservedProxyDiagnosticScope $script:row $false
    Check ($s.State -eq 'Changed' -and $s.ForwardingState -eq 'Unknown' -and -not $s.OwnerVerified -and $s.Targets.Count -eq 2) ($case+': changed binding cannot certify a path; individual diagnostic results remain available')
}
Reset-Fixture;$script:drift='closed';$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'Ready' -and $s.CurrentConnectionObserved -eq $false -and $s.ForwardingState -eq 'AllTimeout') 'A naturally closed original TCP must preserve the diagnostic result for the entry seen at start'
Reset-Fixture;$script:drift='helper';$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'Ready' -and $s.CurrentConnectionObserved -eq $true) 'An unrelated verified helper must not change the participating identity binding'
Reset-Fixture;$script:settings.Profiles+=@([pscustomobject]@{Id='c';Protocol='http';Host='127.0.0.1';Port=22004});$script:drift='switched';$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'Changed' -and $s.ForwardingState -eq 'Unknown') 'Switching from the original socket to another registered proxy invalidates certification'
Reset-Fixture;$script:settings.Profiles+=@([pscustomobject]@{Id='c';Protocol='http';Host='127.0.0.1';Port=22004});$script:drift='child-switch';$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'Changed' -and $s.ForwardingState -eq 'Unknown') 'A new verified child using another registered proxy invalidates the original entry after its TCP closes'
Reset-Fixture;$script:row|Add-Member NoteProperty FamilyObservationTruncated $true;$r=Get-ProgramNetworkDiagnosis $app
Check ($r.ObservedProxyScope.State -eq 'Ready' -and $r.ObservedProxyScope.CoverageLimited -and $r.Summary -match '仅检查已核验成员所见入口') 'A bounded display family must permit independently verified entry probes with explicit limited coverage'
Check ($r.Findings.Code -contains 'observed-proxy-limited-coverage' -and ($r.Findings|Where-Object Code -eq 'observed-proxy-forwarding-timeout').Evidence -match '家族观察不完整') 'Limited coverage stays visible in findings and all-timeout guidance'
Reset-Fixture;$script:drift='truncated';$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'Ready' -and $s.CoverageLimited -and $s.ForwardingState -eq 'AllTimeout') 'Fresh post-probe family truncation does not erase an unchanged known entry and cannot certify all members'
Reset-Fixture
foreach($id in 500..630){$script:processes+=@([pscustomobject]@{Id=$id;ParentId=100;Path=$other;PathStatus='Available';StartTime=$script:birth.AddSeconds(5)})}
$script:bTargets=@((Targets 'https-response' 200 204)[0],(Targets)[1]);$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'Ready' -and $s.CoverageLimited -and $s.ForwardingState -eq 'PartialResponse') 'Fresh initial truncation preserves partial HTTPS success only for the verified entry'
Reset-Fixture;$script:settings.Profiles+=@([pscustomobject]@{Id='c';Protocol='http';Host='127.0.0.1';Port=22004});$script:row.PIDs='100,999';$script:row|Add-Member NoteProperty FamilyUnknownIds @(999)
$script:processes+=@([pscustomobject]@{Id=999;ParentId=100;Path=$other;PathStatus='Unavailable';StartTime=$script:birth.AddSeconds(5)})
$script:tcp+=@([pscustomobject]@{OwningProcess=999;State='Established';LocalAddress='127.0.0.1';LocalPort=50103;RemoteAddress='127.0.0.1';RemotePort=22004})
$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'Ready' -and $s.CoverageLimited) 'An unverified sibling must stay unknown rather than be claimed as a second application entry'
Reset-Fixture;$ended=$script:row.ConnectionDetails[0]|Select-Object *;$ended.LocalPort=50109;$script:row.ConnectionDetails+=@($ended)
$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'Ready' -and $s.ClosedBeforeCheckCount -eq 1 -and $s.ObservedConnectionCount -eq 1 -and $s.ForwardingState -eq 'AllTimeout') 'One naturally ended display socket does not discard another fresh verified socket or change its post-probe binding'
$script:drift='closed';$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'Ready' -and $s.CurrentConnectionObserved -eq $false -and $s.ClosedBeforeCheckCount -eq 1) 'A selected fresh socket may end during probing even when old closed display sockets were excluded'
Reset-Fixture;$script:tcp=@($script:tcp|Where-Object State -ne 'Established');$before=$script:probePorts.Count;$s=Get-ObservedProxyDiagnosticScope $script:row $false
Check ($s.State -eq 'NotObserved' -and $s.ObservedConnectionCount -eq 0 -and $script:probePorts.Count -eq $before) 'All display sockets already ended: no entry is probed without a fresh connection'
Reset-Fixture
$script:row.Mode='managed';$script:ingress.ready=$null;$before=$script:systemProbes;$r=Get-ProgramNetworkDiagnosis $app
Check ($r.ProbeScope.State -eq 'Unknown' -and $script:systemProbes -eq $before -and $r.ObservedProxyScope.State -eq 'Ready') 'Unknown managed scope cannot borrow system or external scope, which remains independent'
$script:ingress.ready=$true
foreach($connect in @(0,200)){
    $probe=[pscustomobject]@{Output=[pscustomobject]@{Result=('000 6.0 '+$connect)};Process=[pscustomobject]@{ExitCode=28}}
    $t=Read-NetworkTargetProbe ([pscustomobject]@{Protocol='http'}) 'fixture' $probe
    Check ($t.Stage -eq 'probe-timeout' -and $t.ConnectCode -eq $connect -and $t.TimeoutPhase -eq $(if($connect){'AfterConnect'}else{'BeforeConnect'}) -and (Get-NetworkTargetStageText $t.Stage $t) -match $(if($connect){'CONNECT 200'}else{'CONNECT=0'})) 'CONNECT timeout phases retain machine and human evidence'
}
if($FixturePath){
    Set-Item Function:Test-NetworkTargets $script:realTargets
    $fixture=Get-Content -LiteralPath $FixturePath -Raw|ConvertFrom-Json
    $ca=Join-Path $PSScriptRoot 'test-fixtures/web-transport/localhost-cert.pem'
    $script:fixtureStart=[scriptblock]::Create((${function:Start-HttpEndpointProbe}.ToString().Replace('--disable --silent',('--disable --cacert "'+$ca+'" --silent'))))
    function Start-HttpEndpointProbe($Profile,[string]$Url,[bool]$Fast=$false){
        $route='/204'
        if($script:fixtureCase.Name -eq 'stallTotal' -or ($script:fixtureMode -eq 'partial' -and $Url -like '*openai*')){$route='/stall'}
        elseif($script:fixtureMode -eq 'responses' -and $Url -like '*openai*'){$route='/401'}
        & $script:fixtureStart $Profile ('https://localhost:'+$fixture.OriginPort+$route) $Fast
    }
    foreach($script:fixtureMode in @('stallConnect','stallTotal','partial','responses')){
        Reset-Fixture
        $caseName=if($script:fixtureMode -in @('stallConnect','stallTotal')){$script:fixtureMode}else{'early'}
        $script:fixtureCase=$fixture.Cases|Where-Object Name -eq $caseName|Select-Object -First 1
        Check ([bool]$script:fixtureCase) 'Required loopback case is present'
        $port=[int]$script:fixtureCase.Port;$script:settings.Profiles[1].Port=$port;$script:row.ConnectionDetails[0].RemotePort=$port;$script:tcp[0].RemotePort=$port;$script:tcp[1].LocalPort=$port
        if($script:fixtureMode -eq 'partial'){$script:row|Add-Member NoteProperty FamilyObservationTruncated $true}
        $clock=[Diagnostics.Stopwatch]::StartNew();$s=Get-ObservedProxyDiagnosticScope $script:row $false
        Check ($s.State -eq 'Ready' -and $s.Listening -and $s.Targets.Count -eq 2 -and $clock.Elapsed.TotalSeconds -lt 13) 'Real curl observed-entry test stays bounded, attributed and isolated'
        if($script:fixtureMode -like 'stall*'){
            $expected=if($script:fixtureMode -eq 'stallConnect'){0}else{200}
            Check ($s.ForwardingState -eq 'AllTimeout' -and @($s.Targets|Where-Object {$_.ConnectCode -eq $expected -and $_.CurlExitCode -eq 28}).Count -eq 2) 'Real CONNECT-before/after stalls retain exact phases'
        }elseif($script:fixtureMode -eq 'partial'){Check ($s.ForwardingState -eq 'PartialResponse' -and $s.CoverageLimited) 'Real mixed HTTPS/timeout outcomes remain separate under limited family coverage'}
        else{Check ($s.ForwardingState -eq 'HttpsResponse' -and @($s.Targets|Where-Object HttpCode -eq 401).Count -eq 1 -and -not $s.AuthenticationVerified) 'Real HTTP 401 is only HTTPS reachability'}
        Write-Output ('PASS: observed external loopback '+$script:fixtureMode+' '+[Math]::Round($clock.Elapsed.TotalSeconds,2)+'s')
    }
}
Write-Output ('PASS: '+$script:checks+' observed external proxy assertions; only isolated identities/loopback transport, no settings or application changes.')

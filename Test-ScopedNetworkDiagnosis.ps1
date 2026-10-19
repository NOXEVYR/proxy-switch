param([string]$FixturePath='')
$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-ScopedDiagnosis-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$script:Checks=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
function Set-SystemSnapshot {throw 'Network diagnosis cannot write Windows settings'}
function Set-UserProxyEnv {throw 'Network diagnosis cannot write user environment'}
function Wait-ManagedProgramIngressReady {throw 'Read-only diagnosis cannot invoke launch readiness'}
function Ensure-ManagedGateway {throw 'Read-only diagnosis cannot start a service'}
function Start-ManagedProgram {throw 'Read-only diagnosis cannot launch an application'}
function Test-ProgramPathEquivalent($Left,$Right){$Left -ieq $Right}
$script:Profiles=[pscustomobject]@{Profiles=@([pscustomobject]@{Id='good';Name='Good';Protocol='http';Host='127.0.0.1';Port=21002})}
$script:row=[pscustomobject]@{Path='C:\Fixture\Editor.exe';SavedPath='C:\Fixture\Editor.exe';PIDs='100';ObservationState='Observed';Policy='good';Actual='verified managed connection';Coverage='verified family TCP';Mode='managed';HasSavedRule=$true;RuleLoaded=$true;Loaded=$true;RequiresRepair=$false;NeedsEntryConnection=$false;ProgramEntryState='Observed';Pending=0;ObservedAt='fixture';CanLaunch=$true;NeedsRelaunch=$false;ConnectionDetails=@([pscustomobject]@{State='Established';IngressKind='Managed';EvidenceSource='Controller';ActualRoute='good'})}
$script:ingress=[pscustomobject]@{id='dedicated';path=$script:row.Path;port=22111;route='good'}
$script:live=[pscustomobject]@{id='dedicated';path=$script:row.Path;port=22111;route='good';loaded=$true;ready=$true;effectiveRoute='good'}
$script:targets=@([pscustomobject]@{Name='Fixture';Stage='https-response';HttpCode=204;ConnectCode=200;CurlExitCode=0;Seconds=0.2})
$script:probePorts=@();$script:systemProbeCalls=0;$script:systemBroken=$true;$script:statusCalls=0;$script:drift=$false
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$true;Rows=@()}}
function Get-ApplicationRoutes {param($TcpRows,[bool]$TcpAvailable);[pscustomobject]@{Rows=@($script:row);ProcessesAvailable=$true;TcpAvailable=$true}}
function Get-ManagedProgramIngress($Path){$script:ingress}
function Get-RoutingSnapshot {[pscustomobject]@{programIngresses=@($script:ingress)}}
function Invoke-AppRouter {
    param($Request,$TimeoutMilliseconds)
    Check ($Request.action -eq 'status') 'Only read-only status may be queried'
    $script:statusCalls++
    if($script:drift -and $script:statusCalls -gt 1){$script:live.effectiveRoute='Direct'}
    [pscustomobject]@{available=$true;rulesAvailable=$true;programIngresses=@($script:live)}
}
function Get-NetworkDiagnosis {
    param([switch]$Probe)
    if($Probe){$script:systemProbeCalls++}
    $f=[pscustomobject]@{CurrentEntry=[pscustomobject]@{Name='Unrelated system entry';Key='other';Listening=(-not $script:systemBroken);OwnerVerified=$true};UserProxyEnvironment=[pscustomobject]@{State='Unset';SetCount=0};HistoricalSelection=[pscustomobject]@{DifferentFromCurrent=$false};Issues=@();Targets=@();ExternalMihomo=$null;ApplicationProxyViews=$null;RepairAction='';Message='system detail';TopologySummary=(ConvertTo-NetworkTopologySummary ([pscustomobject]@{State='Evidence';IPv4='Evidence';IPv6='Unknown';Available=$true;ObservedAt='2026-10-17T00:00:00Z'}))}
    if($script:systemBroken){$f.Issues=@([pscustomobject]@{Code='system-entry-down';Message='System entry is down'})}
    elseif($Probe){$f.Targets=@([pscustomobject]@{Name='System fixture';Stage='https-response';HttpCode=204})}
    Add-SystemNetworkDiagnosisSummary $f -Probe:$Probe
    $f
}
$script:realTargets=${function:Test-NetworkTargets}
function Test-NetworkTargets($Profile){$script:probePorts+=@($Profile.Port);$script:targets}
$r=Get-ProgramNetworkDiagnosis $script:row.Path
Check ($r.Conclusion.State -eq 'ChecksPassed' -and $r.SystemDiagnosis.Conclusion.State -eq 'ProblemFound') 'Healthy dedicated program must survive an unrelated broken system endpoint'
Check ($r.ProbeScope.Kind -eq 'Managed' -and $r.ProbeScope.State -eq 'Ready' -and $script:systemProbeCalls -eq 0 -and $script:probePorts.Count -eq 1 -and $script:probePorts[0] -eq 22111) 'Dedicated request must use its exact fixed ingress, never the default endpoint'
Check ($r.Findings.Code -notcontains 'system-entry-down' -and $r.Summary -notmatch 'Unrelated system entry|System entry is down') 'Independent system failures must stay out of the program conclusion and primary summary'
Check ($r.Program.Mode -eq 'managed' -and $r.Program.SavedPath -eq $script:row.Path -and $r.Program.ObservedPath -eq $script:row.Path -and $r.Program.HasSavedRule -and $r.Program.CanLaunch -eq $true -and $r.Program.NeedsRelaunch -eq $false) 'Program action descriptors must preserve reliable observer fields'
Check ($r.TopologySummary.IPv4 -eq 'Evidence' -and $r.TopologySummary.IPv6 -eq 'Unknown') 'Program report must include the independent safe topology summary'
Check ($r.Summary -match '127.0.0.1:22111' -and $r.Summary -match 'IPv4 已见隧道路由证据' -and $r.ProbeScope.EntrySource -match '本轮控制器核验') 'Verified ingress and topology must be visible in the human summary'
$script:systemBroken=$false;$script:targets=@([pscustomobject]@{Name='Fixture';Stage='proxy-rejected';HttpCode=0;ConnectCode=407;CurlExitCode=56;Seconds=0.1})
$r=Get-ProgramNetworkDiagnosis $script:row.Path
Check ($r.Conclusion.State -eq 'NeedsRetest' -and $r.Findings.Code -contains 'program-probe-Fixture' -and $r.Targets[0].ConnectCode -eq 407) 'A healthy default cannot hide a refused dedicated CONNECT request'
$script:targets=@([pscustomobject]@{Name='Fixture';Stage='https-response';HttpCode=204})
foreach($change in @('loaded','ready','route','path','port','id')){
    $previous=$script:live|ConvertTo-Json -Compress
    switch($change){'loaded'{$script:live.loaded=$null};'ready'{$script:live.ready=$false};'route'{$script:live.effectiveRoute='Unknown'};'path'{$script:live.path='C:\Other\Editor.exe'};'port'{$script:live.port=22112};'id'{$script:live.id='other'}}
    $count=$script:probePorts.Count;$r=Get-ProgramNetworkDiagnosis $script:row.Path
    Check ($r.Conclusion.State -eq 'NeedsRetest' -and $r.Findings.Code -contains 'program-ingress-unknown' -and $script:probePorts.Count -eq $count -and $script:systemProbeCalls -eq 0) ($change+': unverified ingress must never trigger an active/default probe')
    Check ($r.ProbeScope.EntrySource -notmatch '本轮控制器核验') 'Unknown or unavailable ingress must not claim verified ownership in its scope label'
    $script:live=$previous|ConvertFrom-Json
}
$script:drift=$true;$script:statusCalls=0;$r=Get-ProgramNetworkDiagnosis $script:row.Path
Check ($r.ProbeScope.State -eq 'Changed' -and $r.Conclusion.State -eq 'NeedsRetest') 'A changed selector after the probe cannot certify the original route'
$script:drift=$false;$script:live.effectiveRoute='good'
$script:row.Mode='engine';$count=$script:probePorts.Count;$r=Get-ProgramNetworkDiagnosis $script:row.Path
Check ($r.ProbeScope.Kind -eq 'Unknown' -and $r.Conclusion.State -eq 'NeedsRetest' -and $script:probePorts.Count -eq $count -and $script:systemProbeCalls -eq 0) 'Engine-specific saved rules cannot be diagnosed through the system default'
$script:row.Mode='observe';$script:row.HasSavedRule=$false;$script:row.Policy='Follow'
$script:row.ConnectionDetails=@([pscustomobject]@{State='Established';IngressKind='Proxy';EvidenceSource='RegisteredEndpoint';ActualRoute='other-proxy'})
$r=Get-ProgramNetworkDiagnosis $script:row.Path
Check ($r.ProbeScope.Kind -eq 'SystemComparison' -and $script:systemProbeCalls -eq 1 -and $r.Conclusion.State -eq 'NeedsRetest' -and $r.Findings.Code -contains 'program-tcp-only') 'A system comparison success must not certify software observed using another proxy'
$script:row.PSObject.Properties.Remove('CanLaunch');$script:row.PSObject.Properties.Remove('NeedsRelaunch');$r=Get-ProgramNetworkDiagnosis $script:row.Path
Check ($null -eq $r.Program.CanLaunch -and $null -eq $r.Program.NeedsRelaunch) 'Absent launch/relaunch evidence must remain unknown'
foreach($state in @('Evidence','NoEvidence','Unknown')){
    $t=ConvertTo-NetworkTopologySummary ([pscustomobject]@{State=$state;IPv4=$state;IPv6='Unknown';Available=($state -ne 'Unknown');ObservedAt='2026-10-17T00:00:00Z';Coverage='PRIVATE-ADDRESS';InterfaceIndices=@(12);Address='PRIVATE-ADDRESS'})
    Check ($t.State -eq $state -and $t.IPv4 -eq $state -and $t.IPv6 -eq 'Unknown') ($state+': topology must preserve three-valued observation')
    Check (($t.PSObject.Properties.Name -join ',') -eq 'State,IPv4,IPv6,Available,Coverage,ObservedAt' -and ($t|ConvertTo-Json) -notmatch 'PRIVATE-ADDRESS|InterfaceIndices') 'Topology summary must expose only safe fields and fixed coverage text'
}
$t=ConvertTo-NetworkTopologySummary $null
Check ($t.State -eq 'Unknown' -and $t.IPv4 -eq 'Unknown' -and -not $t.Available) 'Missing topology is unknown, never no-evidence'
if($FixturePath){
    Set-Item Function:Test-NetworkTargets $script:realTargets
    $fixture=Get-Content -LiteralPath $FixturePath -Raw|ConvertFrom-Json
    $testCa=Join-Path $PSScriptRoot 'test-fixtures/web-transport/localhost-cert.pem'
    $script:realStart=[scriptblock]::Create((${function:Start-HttpEndpointProbe}.ToString().Replace('--disable --silent',('--disable --cacert "'+$testCa+'" --silent'))))
    function Start-HttpEndpointProbe($Profile,[string]$Url,[bool]$Fast=$false){
        $route=if($script:case.Name -eq 'late'){'/late'}elseif($script:case.Name -eq 'stallTotal'){'/stall'}else{'/204'}
        & $script:realStart $Profile ('https://localhost:'+$fixture.OriginPort+$route) $Fast
    }
    foreach($script:case in @($fixture.Cases|Where-Object {$_.Name -in @('late','proxyAuth','tlsFailure','stallConnect','stallTotal')})){
        $profile=[pscustomobject]@{Protocol='http';Host='127.0.0.1';Port=$script:case.Port}
        $clock=[Diagnostics.Stopwatch]::StartNew();$targets=@(Test-NetworkTargets $profile);$elapsed=$clock.Elapsed.TotalSeconds
        Check ($targets.Count -eq 2 -and $elapsed -lt 13) ($script:case.Name+': parallel diagnostic targets must share one twelve-second deadline')
        switch($script:case.Name){
            'late'{Check ($elapsed -ge 8.5 -and @($targets|Where-Object {$_.Stage -eq 'https-response' -and $_.ConnectCode -eq 200 -and $_.CurlExitCode -eq 0 -and $_.Seconds -ge 8.5}).Count -eq 2) 'Nine-second HTTPS replies must survive the old eight-second cutoff with curl evidence preserved'}
            'proxyAuth'{Check (@($targets|Where-Object {$_.Stage -eq 'proxy-rejected' -and $_.ConnectCode -eq 407 -and $_.CurlExitCode -ne 0}).Count -eq 2) 'CONNECT 407 must retain refusal status and curl failure, never unknown or target TLS failure'}
            'tlsFailure'{Check (@($targets|Where-Object {$_.Stage -eq 'target-tls-failed' -and $_.ConnectCode -eq 200 -and $_.CurlExitCode -ne 0}).Count -eq 2) 'Failed TLS after CONNECT must retain tunnel and TLS evidence separately'}
            'stallConnect'{Check ($elapsed -ge 5 -and @($targets|Where-Object {$_.Stage -eq 'probe-timeout' -and $_.ConnectCode -eq 0 -and $_.CurlExitCode -eq 28 -and $_.TimeoutPhase -eq 'BeforeConnect'}).Count -eq 2) 'CONNECT timeouts must remain bounded and distinct from proxy rejection'}
            'stallTotal'{Check ($elapsed -ge 9 -and @($targets|Where-Object {$_.Stage -eq 'probe-timeout' -and $_.ConnectCode -eq 200 -and $_.CurlExitCode -eq 28 -and $_.TimeoutPhase -eq 'AfterConnect'}).Count -eq 2) 'Origin timeouts must preserve CONNECT success and share the total budget'}
        }
        Write-Output ('PASS: diagnostic targets '+$script:case.Name+' '+[Math]::Round($elapsed,2)+'s')
    }
}
Write-Output ('PASS: '+$script:Checks+' scoped program diagnosis and topology assertions; settings and application launch are forbidden.')

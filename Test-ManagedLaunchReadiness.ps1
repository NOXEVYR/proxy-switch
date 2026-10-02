[CmdletBinding()]
param([string]$LegacyLaunchFile='',[string]$LegacyManagedRoutingFile='')
$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-launch-readiness-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory (Join-Path $qa 'data')
if($LegacyLaunchFile){. $LegacyLaunchFile}
if($LegacyManagedRoutingFile){. $LegacyManagedRoutingFile}
$script:Checks=0;$script:Reads=0;$script:Probes=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:Checks++}
function Use-ChangeLock([scriptblock]$Action){& $Action}
function Set-SystemSnapshot {throw 'Real Windows writes forbidden'}
function Set-UserProxyEnv {throw 'Real environment writes forbidden'}
function Get-ProcessInventory {@()}
function Get-ManagedProgramIngress($Executable){[pscustomobject]@{id=('a'*32);path=$Executable;port=19998;route=$script:Selected}}
function Ensure-ManagedGateway([switch]$PreserveWindowsSettings){Check $PreserveWindowsSettings 'Every supported fixed-entry launch requests program-only coexistence';Get-FixtureLive}
function Get-FixtureLive {
    $script:Reads++;$route=$script:Effective
    if($script:Scenario -eq 'fallback' -and $script:Reads -ge 3){$route='b'}
    $time=[DateTime]::UtcNow;if($script:Scenario -eq 'stale'){$time=$time.AddMinutes(-3)}elseif($script:Scenario -eq 'future'){$time=$time.AddMinutes(3)}
    [pscustomobject]@{available=$script:Available;rulesAvailable=$true;defaultLoaded=$true;effectiveDefaultRoute='Blocked';
      programIngresses=@([pscustomobject]@{id=('a'*32);loaded=$script:Ready;ready=$script:Ready;effectiveRoute=$route});
      failover=[pscustomobject]@{updated=$time.ToString('o');health=[pscustomobject]@{a=$script:HealthA;b=$script:HealthB}};
      siteRulesLoaded=$script:SitesLoaded;siteRules=@($script:Sites)}
}
function Invoke-AppRouter($Request,[int]$TimeoutMilliseconds){Get-FixtureLive}
function Invoke-ManagedIngressTransportProbe($Ingress,$Urls,$Deadline,$Cancellation){
    $script:Probes++;Check ($Ingress.port -eq 19998 -and $Ingress.id -ceq ('a'*32)) 'Probe targets the program entrance rather than the dead default entrance'
    if($script:Scenario -eq 'cancel-probe'){$Cancellation.Cancel()}
    if($script:Scenario -eq 'unknown-after'){$script:Available=$false}
    if($script:Scenario -eq 'health-failed-after'){$script:HealthB=$false}
    if($script:Scenario -eq 'entrance-changed'){$script:Selected='a'}
    return $script:ProbePass
}
$realWait=${function:Wait-ManagedProgramIngressReady}
function Wait-ManagedProgramIngressReady($Ingress,$Cancellation){& $realWait $Ingress -TimeoutMilliseconds 230 -Cancellation $Cancellation}
$script:Profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(
 @{Id='a';Name='A';Protocol='http';Host='127.0.0.1';Port=19996},@{Id='b';Name='B';Protocol='http';Host='127.0.0.1';Port=19997}
);Routing=@{Adapter='none';ProfileId=''}})
[void][IO.Directory]::CreateDirectory((Join-Path $qa 'template'))
$template=Join-Path $qa 'template\client.exe'
Add-Type -TypeDefinition @'
using System;using System.IO;
public static class ReadyClient {public static void Main(){File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"started"),"own fixture");}}
'@ -OutputAssembly $template -OutputType WindowsApplication
function Site($Scope,$Type,$Domain,$Route){[pscustomobject]@{scope=$Scope;type=$Type;domain=$Domain;route=$Route;loaded=$true}}
$programScope='a'*32
$cases=@(
 @{Name='shadowed-program-suffix';Route='Blocked';Sites=@((Site 'global' 'suffix' 'example.com' 'Direct'),(Site $programScope 'suffix' 'example.com' 'a'));Allow=$false},
 @{Name='shadowed-program-ancestor';Route='Blocked';Sites=@((Site 'global' 'suffix' 'example.com' 'Direct'),(Site $programScope 'suffix' 'com' 'a'));Allow=$false},
 @{Name='shadowed-global-exact';Route='Blocked';Sites=@((Site 'global' 'domain' 'example.com' 'Direct'),(Site $programScope 'suffix' 'com' 'a'));Allow=$false},
 @{Name='limited-exact-only-shadow';Route='Blocked';Sites=@((Site 'global' 'suffix' 'example.com' 'Direct'),(Site $programScope 'domain' 'example.com' 'a'));Allow=$true},
 @{Name='limited-child-only-shadow';Route='Blocked';Sites=@((Site 'global' 'suffix' 'example.com' 'Direct'),(Site $programScope 'suffix' 'child.example.com' 'a'));Allow=$true},
 @{Name='limited-program-direct';Route='Blocked';Sites=@((Site 'global' 'suffix' 'example.com' 'a'),(Site $programScope 'suffix' 'example.com' 'Direct'));Allow=$true},
 @{Name='limited-more-specific-direct';Route='Blocked';Sites=@((Site $programScope 'suffix' 'com' 'a'),(Site $programScope 'domain' 'example.com' 'Direct'));Allow=$true},
 @{Name='limited-other-program-shadow';Route='Blocked';Sites=@((Site 'global' 'suffix' 'example.com' 'Direct'),(Site ('b'*32) 'suffix' 'com' 'a'));Allow=$true},
 @{Name='shadowed-exact-by-program';Route='Blocked';Sites=@((Site 'global' 'domain' 'example.com' 'Direct'),(Site $programScope 'domain' 'example.com' 'a'));Allow=$false},
 @{Name='limited-exact-beats-suffix';Route='Blocked';Sites=@((Site $programScope 'suffix' 'example.com' 'a'),(Site $programScope 'domain' 'example.com' 'Direct'));Allow=$true},
 @{Name='dead';Route='a';HealthA=$false;Allow=$false},
 @{Name='live';Route='a';HealthA=$true;Allow=$true},
 @{Name='fallback';Route='a';HealthA=$false;HealthB=$true;Allow=$true},
 @{Name='dedicated-b';Route='b';HealthB=$true;Allow=$true},
 @{Name='direct';Route='Direct';Allow=$true},
 @{Name='stale';Route='a';HealthA=$true;Allow=$false},
 @{Name='future';Route='a';HealthA=$true;Allow=$false},
 @{Name='unknown-health';Route='a';Allow=$false},
 @{Name='unknown-route';Route='Unknown';Allow=$false},
 @{Name='unknown-after';Route='b';HealthB=$true;Allow=$false},
 @{Name='health-failed-after';Route='b';HealthB=$true;Allow=$false},
 @{Name='entrance-changed';Route='b';HealthB=$true;Allow=$false;Changed=$true},
 @{Name='transport-failed';Route='b';HealthB=$true;Probe=$false;Allow=$false},
 @{Name='not-ready';Route='Direct';Ready=$false;Allow=$false},
 @{Name='cancel-before';Route='a';HealthA=$true;Allow=$false},
 @{Name='cancel-probe';Route='b';HealthB=$true;Allow=$false},
 @{Name='limited-program';Route='Blocked';Scope=('a'*32);Allow=$true},
 @{Name='limited-global';Route='Blocked';Scope='global';Allow=$true},
 @{Name='other-program';Route='Blocked';Scope=('b'*32);Allow=$false},
 @{Name='unloaded-sites';Route='Blocked';Scope='global';SitesLoaded=$false;Allow=$false},
 @{Name='limited-foreign-unreachable';Route='Blocked';Scope='global';Probe=$false;Allow=$true}
)
foreach($case in $cases){
    $dir=Join-Path $qa $case.Name;[void][IO.Directory]::CreateDirectory($dir);$exe=Join-Path $dir 'client.exe';Copy-Item -LiteralPath $template -Destination $exe
    foreach($name in @('resources.pak','chrome_100_percent.pak')){[IO.File]::WriteAllText((Join-Path $dir $name),'inert adapter fixture')}
    $script:Scenario=$case.Name;$script:Effective=$case.Route;$script:Selected=$(if($case.Route -in @('Unknown','Blocked')){'a'}else{$case.Route})
    $script:Reads=0;$script:Probes=0;$script:HealthA=$case.HealthA;$script:HealthB=$case.HealthB;$script:Available=$true
    $script:Ready=-not ($case.ContainsKey('Ready') -and -not $case.Ready);$script:ProbePass=-not ($case.ContainsKey('Probe') -and -not $case.Probe)
    $script:SitesLoaded=-not ($case.ContainsKey('SitesLoaded') -and -not $case.SitesLoaded);$script:Sites=@()
    if($case.Scope){$script:Sites=@(Site $case.Scope 'suffix' 'example.com' 'Direct')}
    if($case.Sites){$script:Sites=@($case.Sites)}
    $before=Get-ManagedProgramIngress $exe|ConvertTo-Json -Compress;$cancel=New-Object Threading.CancellationTokenSource
    if($case.Name -eq 'cancel-before'){$cancel.Cancel()}
    $result=$null;$failure='';$watch=[Diagnostics.Stopwatch]::StartNew()
    try{$result=Start-ManagedProgram $exe -Cancellation $cancel}catch{$failure=$_.Exception.Message}finally{$cancel.Dispose()}
    $watch.Stop();$started=Test-Path -LiteralPath (Join-Path $dir 'started')
    if($case.Allow){
        if($result.PID){$p=$null;try{$p=[Diagnostics.Process]::GetProcessById($result.PID);[void]$p.WaitForExit(3000)}catch [ArgumentException]{}finally{if($p){$p.Dispose()}}}
        $started=Test-Path -LiteralPath (Join-Path $dir 'started')
        Check ($result.PID -gt 0 -and $started -and -not $failure) ($case.Name+' launches exactly the owned target after fresh verified transport')
        if($case.Route -in @('Direct','Blocked')){Check ($script:Probes -eq 0) ($case.Name+' explicit Direct policy does not require a foreign website')}
        else{Check ($script:Probes -ge 1) ($case.Name+' cannot authorize launch from selector state alone')}
        if($case.Name -match '^limited'){Check ($result.LimitedDirect -and $result.Message -match '仅匹配直连网站例外') 'Limited Direct launch does not advertise ordinary proxy availability'}
    }else{
        Check (-not $result -and -not $started -and $failure -match '未启动') ($case.Name+' must refuse before Process.Start')
        Check ($watch.Elapsed.TotalSeconds -lt 3) ($case.Name+' remains bounded rather than waiting indefinitely')
    }
    if($case.Changed){Check ((Get-ManagedProgramIngress $exe).route -eq 'a') 'Launch refuses a changed route without overwriting the concurrent edit'}
    else{Check ((Get-ManagedProgramIngress $exe|ConvertTo-Json -Compress) -ceq $before) ($case.Name+' preserves saved route and fixed entrance')}
}
# Check the mirrored policy against the existing pure RoutePolicy resolver over
# every pair drawn from all scopes/types/routes and nested-domain boundaries.
$options=@();foreach($scope in @('global',$programScope,('b'*32))){foreach($type in @('domain','suffix')){foreach($domain in @('com','example.com','child.example.com')){foreach($route in @('a','Direct')){$options+=@(Site $scope $type $domain $route)}}}}
$matrix=@();foreach($first in $options){foreach($second in $options){$matrix+=@([pscustomobject]@{siteRules=@($first,$second)})}}
$oracleScript=Join-Path $qa 'site-policy-oracle.cjs';$oracleInput=Join-Path $qa 'site-policy-cases.json';$oracleOutput=Join-Path $qa 'site-policy-results.json'
Write-LocalJson $oracleInput $matrix
[IO.File]::WriteAllText($oracleScript,@'
const fs=require('fs'),path=require('path'),policy=require(path.join(process.argv[2],'RoutePolicy.cjs'));
const cases=JSON.parse(fs.readFileSync(process.argv[3],'utf8').replace(/^\uFEFF/,'')),id='a'.repeat(32);
const hosts=['com','0.com','example.com','0.example.com','child.example.com','0.child.example.com'];
const results=cases.map(c=>hosts.some(host=>policy.connectionPolicy({siteRules:c.siteRules,programIngresses:[{id,route:'a'}]},{host,inboundName:policy.ingressName(id)})==='Direct'));
fs.writeFileSync(process.argv[4],JSON.stringify(results));
'@)
& (Get-NodeRuntimePath) $oracleScript $PSScriptRoot $oracleInput $oracleOutput
if($LASTEXITCODE -ne 0){throw 'Pure RoutePolicy oracle failed'}
$expected=[IO.File]::ReadAllText($oracleOutput)|ConvertFrom-Json
for($i=0;$i -lt $matrix.Count;$i++){
    $live=[pscustomobject]@{siteRulesLoaded=$true;siteRules=$matrix[$i].siteRules}
    Check ((Test-ManagedDirectWebsiteSpace $live $programScope) -eq $expected[$i]) ('Direct-space policy agrees with RoutePolicy pair '+$i)
}
$longBase=('a'*63)+'.'+('b'*63)+'.'+('c'*63)+'.'+('d'*59)
$alphabet='0123456789abcdefghijklmnopqrstuvwxyz'
$nearLimit=@((Site 'global' 'suffix' $longBase 'Direct'),(Site $programScope 'domain' $longBase 'a'))
foreach($letter in $alphabet.ToCharArray()){$nearLimit+=@(Site $programScope 'domain' ($letter+'.'+$longBase) 'a')}
Check (-not (Test-ManagedDirectWebsiteSpace ([pscustomobject]@{siteRulesLoaded=$true;siteRules=$nearLimit}) $programScope)) 'At 251 characters every valid one-character child can be covered, leaving no Direct space'
Check (Test-ManagedDirectWebsiteSpace ([pscustomobject]@{siteRulesLoaded=$true;siteRules=@($nearLimit|Select-Object -SkipLast 1)}) $programScope) 'At 251 characters one uncovered valid child still permits limited Direct'
$longBase=('a'*63)+'.'+('b'*63)+'.'+('c'*63)+'.'+('d'*61)
$nearLimit=@((Site 'global' 'suffix' $longBase 'Direct'),(Site $programScope 'domain' $longBase 'a'))
Check (-not (Test-ManagedDirectWebsiteSpace ([pscustomobject]@{siteRulesLoaded=$true;siteRules=$nearLimit}) $programScope)) 'A 253-character suffix with its main domain covered cannot invent an overlong child'
# Exercise the actual probe orchestration with inert process handles: every started
# probe is closed on success, cancellation, expiration, or partial start failure.
. (Join-Path $PSScriptRoot 'ManagedRouting.ps1')
$script:StartedProbes=0;$script:ClosedProbes=0;$script:FailProbeStart=$false;$script:ProbeExited=$true
function Start-HttpEndpointProbe($Profile,$Url,$Fast){
    $script:StartedProbes++
    if($script:FailProbeStart -and $script:StartedProbes -eq 2){throw 'inert start failure'}
    [pscustomobject]@{Url=$Url;Process=[pscustomobject]@{HasExited=$script:ProbeExited}}
}
function Read-HttpEndpointProbe($Probe){[pscustomobject]@{Accepted=$true}}
function Close-HttpEndpointProbe($Probe){$script:ClosedProbes++}
$ingress=[pscustomobject]@{port=19998};$urls=@('https://example.com/1','https://example.com/2','https://example.com/3')
$passed=Invoke-ManagedIngressTransportProbe $ingress $urls ([DateTime]::UtcNow.AddSeconds(1))
Check ($passed -and $script:StartedProbes -eq 3 -and $script:ClosedProbes -eq 3) 'Successful first answer disposes all owned probes including unfinished siblings'
$script:StartedProbes=0;$script:ClosedProbes=0;$script:FailProbeStart=$true;$failed=$false
try{Invoke-ManagedIngressTransportProbe $ingress $urls ([DateTime]::UtcNow.AddSeconds(1))|Out-Null}catch{$failed=$true}
Check ($failed -and $script:ClosedProbes -eq 1) 'Partial start failure disposes the earlier successfully started probe'
$script:StartedProbes=0;$script:ClosedProbes=0;$script:FailProbeStart=$false;$script:ProbeExited=$false
$passed=Invoke-ManagedIngressTransportProbe $ingress $urls ([DateTime]::UtcNow.AddMilliseconds(70))
Check (-not $passed -and $script:ClosedProbes -eq 3) 'Expired probe deadline disposes every owned probe and returns unavailable'
$cancel=New-Object Threading.CancellationTokenSource;$cancel.Cancel();$script:StartedProbes=0
try{$passed=Invoke-ManagedIngressTransportProbe $ingress $urls ([DateTime]::UtcNow.AddSeconds(1)) $cancel;Check (-not $passed -and $script:StartedProbes -eq 0) 'Already cancelled transport starts no new helper process'}finally{$cancel.Dispose()}
Write-Output ('PASS: '+$script:Checks+' managed launch readiness checks; isolated real target starts, bounded health/transport/controller/cancellation simulations, no Windows writes.')

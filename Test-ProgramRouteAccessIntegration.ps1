[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RuntimeDirectory)
$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-program-route-access-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qa)
$fixture=$null;$checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++;Write-Output ('PASS: '+$Message)}
try{
    $node=Join-Path $RuntimeDirectory 'node.exe';$sourceCore=Join-Path $RuntimeDirectory 'FlowSwitch.Core.exe'
    $testCore=Join-Path $qa 'FlowSwitch-TestEngine.exe';Copy-Item -LiteralPath $sourceCore -Destination $testCore
    $fixtureScript=Join-Path $qa 'servers.cjs';$portsFile=Join-Path $qa 'ports.json';$controlFile=Join-Path $qa 'server-control.json'
    [IO.File]::WriteAllText($fixtureScript,@'
const http=require('http'),fs=require('fs');const servers=[],addresses=[];let revision='';
Promise.all(['A','B','D'].map(marker=>new Promise(resolve=>{
const s=http.createServer((q,r)=>{r.writeHead(200,{'Content-Length':1});r.end(marker)});
s.on('connect',(q,c)=>{c.write('HTTP/1.1 200 Connection Established\r\n\r\n');c.once('data',()=>c.end('HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n'+marker));});
servers.push(s);s.listen(0,'127.0.0.1',()=>{addresses.push(s.address().port);resolve(s.address().port)});
}))).then(ports=>{fs.writeFileSync(process.argv[2],JSON.stringify(ports));
const timer=setInterval(async()=>{let q;try{q=JSON.parse(fs.readFileSync(process.argv[3],'utf8').replace(/^\uFEFF/,''))}catch{return}
if(q.revision===revision)return;revision=q.revision;
for(let i=0;i<3;i++){if(q.enabled[i]&&!servers[i].listening)await new Promise(r=>servers[i].listen(ports[i],'127.0.0.1',r));else if(!q.enabled[i]&&servers[i].listening)await new Promise(r=>servers[i].close(r));}
fs.writeFileSync(process.argv[3]+'.ack',revision);if(q.stop){clearInterval(timer);process.exit(0)}
},50);});
'@)
    $fixture=Start-Process -FilePath $node -ArgumentList ('"'+$fixtureScript+'" "'+$portsFile+'" "'+$controlFile+'"') -WindowStyle Hidden -PassThru
    $deadline=[DateTime]::UtcNow.AddSeconds(10);while(-not [IO.File]::Exists($portsFile) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
    $ports=[IO.File]::ReadAllText($portsFile)|ConvertFrom-Json
    $reserve=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$reserve.Start();$port=$reserve.LocalEndpoint.Port;$reserve.Stop()
    $env:PROXY_SWITCH_TEST_HEALTH_URL='http://127.0.0.1:'+$ports[2]+'/health'
    . (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory (Join-Path $qa 'data')
    $script:Profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(
        @{Id='gateway';Name='Isolated gateway';Protocol='http';Host='127.0.0.1';Port=$port;CorePath=$testCore},
        @{Id='a';Name='A';Protocol='http';Host='127.0.0.1';Port=$ports[0];CorePath=''},
        @{Id='b';Name='B';Protocol='http';Host='127.0.0.1';Port=$ports[1];CorePath=''}
    );Routing=@{Adapter='standalone';ProfileId='gateway';UnifiedMode='gateway';Failover=@{Enabled=$true;Order=@('a','b');AllowDirect=$false}}})
    Write-LocalJson $script:ConfigPath $script:Profiles
    $script:FakeSystem=[pscustomobject]@{Flags=1;Server='';Bypass='localhost'}
    $script:FakeEnv=[pscustomobject]@{HTTP_PROXY=$null;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='localhost'}
    $originalSystem=$script:FakeSystem;$originalEnv=$script:FakeEnv
    function Get-SystemSnapshot {$script:FakeSystem}
    function Get-UserProxyEnv {$script:FakeEnv}
    function Set-SystemSnapshot($Value){$script:FakeSystem=$Value}
    function Set-UserProxyEnv($Value,$ExpectedBefore=$null){if($ExpectedBefore -and -not (Test-SameEnv $script:FakeEnv $ExpectedBefore)){throw 'Simulated environment conflict'};$script:FakeEnv=$Value}
    function Use-ChangeLock([scriptblock]$Action){& $Action}
    function Get-NodeRuntimePath {$node}
    function Get-IndependentCoreSource {$testCore}
    function Get-ClientInterference {[pscustomobject]@{Running=$false;Tun=$false;Guard=$false;SystemProxy=$false}}
    function Get-ItemPropertyValue {param($LiteralPath,$Name,$ErrorAction);throw 'Isolated registration absent'}
    function Remove-ItemProperty {throw 'Must not alter real RunOnce'}
    function Start-IndependentProtection([int]$OwnerPID,$BeforeSystem,$BeforeEnv,$TargetSystem,$TargetEnv){
        $owned=Get-Content -LiteralPath (Join-Path $script:DataRoot 'gateway\process.json') -Raw|ConvertFrom-Json
        Write-LocalJson (Get-IndependentSessionPath) @{OwnerPID=$OwnerPID;OwnerStart=(Get-ProcessStartTicks $OwnerPID);CorePID=$owned.core;CoreStart=(Get-ProcessStartTicks $owned.core);SupervisorPID=$owned.supervisor;SupervisorStart=(Get-ProcessStartTicks $owned.supervisor);BeforeSystem=$BeforeSystem;BeforeEnv=$BeforeEnv;TargetSystem=$TargetSystem;TargetEnv=$TargetEnv;Version=1;Started=(Get-Date).ToString('o')}
    }
    function Read-TestBody([int]$ProxyPort){
        $tcp=New-Object Net.Sockets.TcpClient
        try{$tcp.Connect('127.0.0.1',$ProxyPort);$stream=$tcp.GetStream();$stream.ReadTimeout=3000
            $bytes=[Text.Encoding]::ASCII.GetBytes("GET http://127.0.0.1:$($ports[2])/probe HTTP/1.1`r`nHost: 127.0.0.1:$($ports[2])`r`nConnection: close`r`n`r`n")
            $stream.Write($bytes,0,$bytes.Length);$reader=New-Object IO.StreamReader($stream);$reply=$reader.ReadToEnd()
            if($reply -notmatch 'HTTP/1.[01] 200'){throw 'Isolated HTTP probe failed'}
            return $reply.Substring($reply.IndexOf("`r`n`r`n")+4).Trim()
        }finally{$tcp.Dispose()}
    }
    # Replace public health targets only; probes still traverse real sockets and actual core.
    function Test-ProxyRoute([string]$Key,[switch]$Fast){
        if($script:RejectProbe){return [pscustomobject]@{Key=$Key;Usable=$false;Results=@()}}
        $p=Get-Profile $Key;try{$body=Read-TestBody $p.Port}catch{$body='FAILED'}
        [pscustomobject]@{Key=$Key;Usable=($body -match '[ABD]');Results=@()}
    }
    $realIngressProbe=${function:Invoke-ManagedIngressTransportProbe}
    function Invoke-ManagedIngressTransportProbe($Ingress,$Urls,$Deadline,$Cancellation){
        & $realIngressProbe $Ingress @('http://network.invalid:'+($ports[2])+'/launch-readiness') $Deadline $Cancellation
    }
    function Set-FixtureServers([bool]$A,[bool]$B,[switch]$Stop){
        $revision=[Guid]::NewGuid().ToString('N');Write-LocalJson $controlFile @{revision=$revision;enabled=@($A,$B,(-not $Stop));stop=[bool]$Stop}
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        do{try{if([IO.File]::ReadAllText($controlFile+'.ack') -ceq $revision){return}}catch{};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline)
        throw 'Own upstream fixture did not apply its server-control request'
    }

    # Ordinary Qt-like client has no Chromium adapter. It reads only a simulated
    # system-entry file per new request; TCP transfers and process identities are real.
    $qtDir=Join-Path $qa 'ordinary-client';[void][IO.Directory]::CreateDirectory($qtDir)
    $exe=Join-Path $qtDir 'CalabiyauFixture.exe';$workerExe=Join-Path $qtDir 'QtWebEngineFixture.exe'
    $clientCode=@'
using System;using System.IO;using System.Net.Sockets;using System.Diagnostics;using System.Threading;
public static class OrdinaryClientFixture {
 public static void Main(string[] args) {
  string root=args[0];bool child=args.Length>1&&args[1]=="--child";
  if(!child) {var psi=new ProcessStartInfo(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"QtWebEngineFixture.exe"),"\""+root+"\" --child");psi.UseShellExecute=false;psi.CreateNoWindow=true;using(var p=Process.Start(psi))File.WriteAllText(Path.Combine(root,"worker.pid"),p.Id.ToString());}
  string role=child?"worker":"root";File.WriteAllText(Path.Combine(root,role+".ready"),Process.GetCurrentProcess().Id.ToString());
  while(!File.Exists(Path.Combine(root,"stop-clients"))) {
   try {int port=int.Parse(File.ReadAllText(Path.Combine(root,"client-proxy-port")));string target=File.ReadAllText(Path.Combine(root,"request.url"));using(var c=new TcpClient()) {c.Connect("127.0.0.1",port);c.ReceiveTimeout=2000;var stream=c.GetStream();var bytes=System.Text.Encoding.ASCII.GetBytes("GET "+target+" HTTP/1.1\r\nHost: "+new Uri(target).Authority+"\r\nConnection: close\r\n\r\n");stream.Write(bytes,0,bytes.Length);string response=new StreamReader(stream).ReadToEnd();File.WriteAllText(Path.Combine(root,role+".result"),response);}}
   catch {File.WriteAllText(Path.Combine(root,role+".result"),"FAILED");}
   Thread.Sleep(150);
  }
 }
}
'@
    Add-Type -TypeDefinition $clientCode -OutputAssembly $exe -OutputType WindowsApplication
    Copy-Item -LiteralPath $exe -Destination $workerExe
    $otherDir=Join-Path $qa 'supported-other';[void][IO.Directory]::CreateDirectory($otherDir)
    $otherExe=Join-Path $otherDir 'OtherFixture.exe';Copy-Item -LiteralPath $exe -Destination $otherExe
    foreach($name in @('resources.pak','chrome_100_percent.pak')){[IO.File]::WriteAllText((Join-Path $otherDir $name),'isolated adapter fixture')}
    Check ((Get-ProgramProxyAdapter $exe) -ne 'chromium') 'Ordinary client fixture has no Chromium launch adapter'
    Check ((Get-ProgramProxyAdapter $otherExe) -eq 'chromium') 'The unrelated saved application supports a managed ingress'
    [IO.File]::WriteAllText((Join-Path $qa 'request.url'),('http://127.0.0.1:'+$ports[2]+'/program-access'))
    function Set-SystemSnapshot($Value){
        $script:FakeSystem=$Value
        if($Value.Flags -band 2){$uri=[uri]('http://'+$Value.Server);[IO.File]::WriteAllText((Join-Path $qa 'client-proxy-port'),[string]$uri.Port)}
    }
    function Wait-ClientResult([string]$Marker){
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        do{
            $ok=$true;foreach($role in @('root','worker')){try{$body=[IO.File]::ReadAllText((Join-Path $qa ($role+'.result')));if($body -notmatch 'HTTP/1.[01] 200' -or -not $body.Trim().EndsWith($Marker)){$ok=$false}}catch{$ok=$false}}
            if($ok){return $true};Start-Sleep -Milliseconds 100
        }while([DateTime]::UtcNow -lt $deadline)
        return $false
    }
    function Get-TestChildProcess {
        $deadline=[DateTime]::UtcNow.AddSeconds(6)
        do{
            try{
                $ownedChildPID=0
                if([int]::TryParse([IO.File]::ReadAllText((Join-Path $qa 'worker.pid')),[ref]$ownedChildPID) -and $ownedChildPID -gt 0){return [Diagnostics.Process]::GetProcessById($ownedChildPID)}
            }catch{}
            Start-Sleep -Milliseconds 30
        }while([DateTime]::UtcNow -lt $deadline)
        throw 'Own child PID receipt was not fully readable within the fixture deadline'
    }
    Set-UniversalProxy 'a'|Out-Null
    $otherConfigured=Set-ManagedApplicationRoute $otherExe 'a';$otherIngress=Get-ManagedProgramIngress $otherExe
    $sites=Get-WebsiteRules
    Set-WebsiteRules @(@{Id='';Domain='localhost';Match='exact';Route='Direct';Executable=$otherExe}) $sites.Revision|Out-Null
    Set-FixtureServers $false $true
    $deadline=[DateTime]::UtcNow.AddSeconds(18)
    do{$beforeLive=Invoke-AppRouter @{action='status'};if($beforeLive.effectiveDefaultRoute -eq 'b' -and $beforeLive.programIngresses[0].effectiveRoute -eq 'b'){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $deadline)
    Check ($beforeLive.defaultRoute -eq 'a' -and $beforeLive.effectiveDefaultRoute -eq 'b') 'Offline preferred default A falls back to real B while saved A remains unchanged'
    Check ($beforeLive.programIngresses[0].effectiveRoute -eq 'b' -and $otherIngress.route -eq 'a') 'Unrelated managed A preference retains its selected fallback B'
    Check ((Read-TestBody $port) -eq 'B' -and (Read-TestBody $otherIngress.port) -eq 'B') 'Main and unrelated program entries really forward to B before repair'
    $saved=Set-ManagedApplicationRoute $exe 'Direct'
    Check (-not $saved.Managed -and @((Get-RoutingSnapshot).entries|Where-Object {$_.path -ieq $exe -and $_.route -eq 'Direct'}).Count -eq 1) 'The ordinary root has a saved Direct engine rule'
    # Third-party overwrite is a stub value only; Windows/user environment unchanged.
    $outsideSystem=[pscustomobject]@{Flags=3;Server=('127.0.0.1:'+$ports[1]);Bypass='localhost;<local>'}
    $outsideEnv=[pscustomobject]@{HTTP_PROXY=('http://127.0.0.1:'+$ports[1]);HTTPS_PROXY=('http://127.0.0.1:'+$ports[1]);ALL_PROXY=('http://127.0.0.1:'+$ports[1]);NO_PROXY='localhost'}
    Set-SystemSnapshot $outsideSystem;Set-UserProxyEnv $outsideEnv
    $client=Start-Process -FilePath $exe -ArgumentList ('"'+$qa+'"') -WindowStyle Hidden -PassThru
    Check (Wait-ClientResult 'B') 'Actual ordinary root and networking child use external B before repair'
    $child=Get-TestChildProcess
    Check (Wait-ClientResult 'B') 'An already saved Direct rule cannot take over requests after external proxy overwrite'
    $snapshotBefore=Get-RoutingSnapshot;$sitesBefore=(@($snapshotBefore.siteRules)|ConvertTo-Json -Depth 12 -Compress);$ingressesBefore=(@($snapshotBefore.programIngresses)|ConvertTo-Json -Depth 12 -Compress)
    $plan=Get-ProgramRouteAccessPlan -Path $exe -Route 'Direct'
    Check ($plan.CanApply -and $plan.SystemNeedsAccess -and $plan.EnvironmentNeedsAccess -and $plan.EffectiveDefaultRoute -eq 'b') ('Fresh preview identifies missing engine entry and retains actual backup B; '+$plan.BlockedReason)
    Check (@($plan.FamilyPlan.Members|Where-Object {$_.Path -ieq $workerExe -and $_.State -eq 'Missing'}).Count -eq 1) 'Real ordinary child identity is verified for additive Direct routing'
    $applied=Set-ProgramRouteAccess -Plan $plan -Confirmed
    Check (Wait-ClientResult 'D') 'Confirmed repair sends real ordinary root and child through main entry to direct origin D'
    Check (-not $client.HasExited -and -not $child.HasExited) 'Repair never terminates client processes'
    $snapshotAfter=Get-RoutingSnapshot;$afterLive=Invoke-AppRouter @{action='status'}
    Check ($snapshotAfter.defaultRoute -eq 'a' -and $afterLive.effectiveDefaultRoute -eq 'b') 'Repair preserves preferred default A and current verified backup B'
    Check ((@($snapshotAfter.siteRules)|ConvertTo-Json -Depth 12 -Compress) -ceq $sitesBefore -and (@($snapshotAfter.programIngresses)|ConvertTo-Json -Depth 12 -Compress) -ceq $ingressesBefore) 'Unrelated managed entries and website exceptions remain identical'
    Check ((Read-TestBody $port) -eq 'B' -and (Read-TestBody $otherIngress.port) -eq 'B') 'Unconfigured clients and unrelated managed application still really use B'
    Check (@($snapshotAfter.entries|Where-Object {$_.path -ieq $workerExe -and $_.route -eq 'Direct'}).Count -eq 1 -and @($snapshotAfter.entries|Where-Object {$_.path -ieq $exe -and $_.route -eq 'Direct'}).Count -eq 1) 'Root and only verified child have explicit Direct engine rules'
    $session=Get-Content -LiteralPath (Get-IndependentSessionPath) -Raw -Encoding UTF8|ConvertFrom-Json
    Check ((Test-SameSnapshot $session.BeforeSystem $outsideSystem) -and (Test-SameEnv $session.BeforeEnv $outsideEnv)) 'Restoration baseline updates to external B settings present before confirmation'
    Check ((Test-SameSnapshot $session.TargetSystem $script:FakeSystem) -and (Test-SameEnv $session.TargetEnv $script:FakeEnv)) 'Protection session owns newly applied system and environment targets'
    $corePID=$session.CorePID;$supervisorPID=$session.SupervisorPID
    [IO.File]::WriteAllText((Join-Path $qa 'stop-clients'),'stop')
    Check ($client.WaitForExit(5000) -and $child.WaitForExit(5000)) 'Actual root and child exit naturally through own fixture channel'
    $client.Dispose();$client=$null;$child.Dispose();$child=$null
    Restore-IndependentSession
    Check ((Test-SameSnapshot $script:FakeSystem $outsideSystem) -and (Test-SameEnv $script:FakeEnv $outsideEnv)) 'Normal stop restores external B baseline rather than stale startup settings'
    Check (-not (Test-Path -LiteralPath (Get-IndependentSessionPath))) 'Normal stop clears completed owned restoration session'
    $deadline=[DateTime]::UtcNow.AddSeconds(6)
    do{$alive=@(@($corePID,$supervisorPID)|ForEach-Object {try{Get-Process -Id $_ -ErrorAction Stop}catch{}});if(-not $alive.Count){break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
    Check (-not $alive.Count) 'Isolated core and supervisor finish after normal stop'
    # Regression: the unrelated default being Blocked must not prevent a verified
    # explicit Direct program from using the healthy fixed main entry.
    Set-FixtureServers $false $false
    foreach($name in @('stop-clients','root.result','worker.result','worker.pid','root.ready','worker.ready')){
        $path=Join-Path $qa $name;if([IO.File]::Exists($path)){[IO.File]::Delete($path)}
    }
    Set-ManagedApplicationRoute $exe 'Direct'|Out-Null
    $deadline=[DateTime]::UtcNow.AddSeconds(18)
    do{$blockedLive=Invoke-AppRouter @{action='status'};if($blockedLive.effectiveDefaultRoute -eq 'Blocked'){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $deadline)
    Check ($blockedLive.defaultLoaded -eq $true -and $blockedLive.effectiveDefaultRoute -eq 'Blocked') 'All proxy upstreams are offline and the actual default is explicitly Blocked'
    $outsideSystem=[pscustomobject]@{Flags=1;Server='';Bypass='localhost'}
    $outsideEnv=[pscustomobject]@{HTTP_PROXY=$null;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='localhost'}
    Set-SystemSnapshot $outsideSystem;Set-UserProxyEnv $outsideEnv
    # The client fixture can still remember the old dead B address, independently
    # of current Windows settings, until it observes the new confirmed main entry.
    [IO.File]::WriteAllText((Join-Path $qa 'client-proxy-port'),[string]$ports[1])
    $client=Start-Process -FilePath $exe -ArgumentList ('"'+$qa+'"') -WindowStyle Hidden -PassThru
    $child=Get-TestChildProcess
    $blockedBefore=Get-RoutingSnapshot
    $blockedPlan=Get-ProgramRouteAccessPlan -Path $exe -Route 'Direct'
    Check ($blockedPlan.CanApply -and $blockedPlan.SystemNeedsAccess -and $blockedPlan.EffectiveDefaultRoute -eq 'Blocked') ('Explicit Direct preview remains applicable while unrelated default is Blocked; '+$blockedPlan.BlockedReason)
    Check ($blockedPlan.Impact -match '不可用|未恢复|失败|阻断|不影响|停止') 'Blocked-default impact warns that other applications are not restored'
    Set-ProgramRouteAccess -Plan $blockedPlan -Confirmed|Out-Null
    Check (Wait-ClientResult 'D') 'With every proxy offline, actual ordinary root and child still reach direct origin D after confirmed access'
    $blockedAfter=Get-RoutingSnapshot;$blockedLive=Invoke-AppRouter @{action='status'}
    Check ($blockedLive.effectiveDefaultRoute -eq 'Blocked' -and $blockedAfter.defaultRoute -eq 'a') 'Direct repair leaves unrelated blocked default and saved preferred A unchanged'
    $unruledRefused=$false;try{$unruledRefused=(Read-TestBody $port) -notin @('A','B','D')}catch{$unruledRefused=$true}
    Check ($unruledRefused) 'Actual unconfigured main-entry request is refused rather than silently going direct'
    Check ((@($blockedAfter.programIngresses)|ConvertTo-Json -Depth 12 -Compress) -ceq (@($blockedBefore.programIngresses)|ConvertTo-Json -Depth 12 -Compress) -and (@($blockedAfter.siteRules)|ConvertTo-Json -Depth 12 -Compress) -ceq (@($blockedBefore.siteRules)|ConvertTo-Json -Depth 12 -Compress)) 'Blocked-default Direct repair also preserves unrelated managed and website rules'
    $session=Get-Content -LiteralPath (Get-IndependentSessionPath) -Raw -Encoding UTF8|ConvertFrom-Json
    Check ((Test-SameSnapshot $session.BeforeSystem $outsideSystem) -and (Test-SameEnv $session.BeforeEnv $outsideEnv)) 'Blocked-default repair owns a current Direct restoration baseline'
    $corePID=$session.CorePID;$supervisorPID=$session.SupervisorPID
    [IO.File]::WriteAllText((Join-Path $qa 'stop-clients'),'stop')
    Check ($client.WaitForExit(5000) -and $child.WaitForExit(5000)) 'Blocked-default client fixtures also exit naturally'
    $client.Dispose();$client=$null;$child.Dispose();$child=$null
    Restore-IndependentSession
    Check ((Test-SameSnapshot $script:FakeSystem $outsideSystem) -and (Test-SameEnv $script:FakeEnv $outsideEnv) -and -not (Test-Path -LiteralPath (Get-IndependentSessionPath))) 'Blocked-default normal stop restores Direct and clears its completed session'
    $deadline=[DateTime]::UtcNow.AddSeconds(6)
    do{$alive=@(@($corePID,$supervisorPID)|ForEach-Object {try{Get-Process -Id $_ -ErrorAction Stop}catch{}});if(-not $alive.Count){break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
    Check (-not $alive.Count) 'Blocked-default isolated core and supervisor also finish naturally'
    Set-FixtureServers $false $false -Stop;Check ($fixture.WaitForExit(5000)) 'All upstream/origin servers finish through own control file'
    Write-Output ('PASS: '+$checks+' real program-entry checks; real ordinary root/child/core/A-B-D HTTP; Windows/environment/RunOnce stubbed; no real game login or third-party TUN tested.')
}catch{
    Write-Output ('FAILED FIXTURE: '+$_.Exception.Message)
    throw
}finally{
    if($qa){[IO.File]::WriteAllText((Join-Path $qa 'stop-clients'),'stop')}
    foreach($p in @($client,$child)){if($p){try{if(-not $p.WaitForExit(6000)){throw 'Own client did not exit naturally'}}finally{$p.Dispose()}}}
    if($script:DataRoot -and [IO.File]::Exists((Join-Path $script:DataRoot 'gateway-session.json'))){
        # Failure cleanup may intentionally change only the fixture's in-memory
        # Windows stub so safety guards can stop own service; never real Windows.
        if($outsideSystem){$script:FakeSystem=$outsideSystem;$script:FakeEnv=$outsideEnv}
        Restore-IndependentSession
    }
    $stop=Join-Path $qa 'data\gateway\stop';if([IO.Directory]::Exists([IO.Path]::GetDirectoryName($stop))){[IO.File]::WriteAllText($stop,'stop')}
    if($fixture){
        if(-not $fixture.HasExited){Set-FixtureServers $false $false -Stop;if(-not $fixture.WaitForExit(5000)){throw 'Own upstream fixture did not stop through control channel'}}
        $fixture.Dispose()
    }
}

[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RuntimeDirectory)
$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-dead-repair-chain-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qa)
$fixture=$null;$checks=0
$priorHealth=$env:PROXY_SWITCH_TEST_HEALTH_URL
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++;Write-Output ('PASS: '+$Message)}
try{
    $node=Join-Path $RuntimeDirectory 'node.exe';$sourceCore=Join-Path $RuntimeDirectory 'FlowSwitch.Core.exe'
    $testCore=Join-Path $qa 'FlowSwitch-TestEngine.exe';Copy-Item -LiteralPath $sourceCore -Destination $testCore
    $fixtureScript=Join-Path $qa 'servers.cjs';$portsFile=Join-Path $qa 'ports.json'
    [IO.File]::WriteAllText($fixtureScript,@'
const http=require('http'),fs=require('fs');
Promise.all(['A','B','D'].map(marker=>new Promise(resolve=>{
const s=http.createServer((q,r)=>{r.writeHead(200,{'Content-Length':1});r.end(marker)});
s.on('connect',(q,c)=>{c.write('HTTP/1.1 200 Connection Established\r\n\r\n');c.once('data',()=>c.end('HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n'+marker));});
s.listen(0,'127.0.0.1',()=>resolve(s.address().port));
}))).then(ports=>fs.writeFileSync(process.argv[2],JSON.stringify(ports)));
'@)
    $fixture=Start-Process -FilePath $node -ArgumentList ('"'+$fixtureScript+'" "'+$portsFile+'"') -WindowStyle Hidden -PassThru
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
    function Set-UserProxyEnv($Value){$script:FakeEnv=$Value}
    function Use-ChangeLock([scriptblock]$Action){& $Action}
    function Get-NodeRuntimePath {$node}
    function Get-IndependentCoreSource {$testCore}
    function Get-ClientInterference {[pscustomobject]@{Running=$false;Tun=$false;Guard=$false;SystemProxy=$false}}
    function Get-ItemPropertyValue {param($LiteralPath,$Name,$ErrorAction);throw 'Isolated registration absent'}
    function Remove-ItemProperty {throw 'Must not alter real RunOnce'}
    function Start-IndependentProtection([int]$OwnerPID,$BeforeSystem,$BeforeEnv,$TargetSystem,$TargetEnv){
        $owned=Get-Content -LiteralPath (Join-Path $script:DataRoot 'gateway\process.json') -Raw|ConvertFrom-Json
        Write-LocalJson (Get-IndependentSessionPath) @{OwnerPID=$OwnerPID;OwnerStart=(Get-ProcessStartTicks $OwnerPID);CorePID=$owned.core;CoreStart=(Get-ProcessStartTicks $owned.core);SupervisorPID=$owned.supervisor;SupervisorStart=(Get-ProcessStartTicks $owned.supervisor);BeforeSystem=$BeforeSystem;BeforeEnv=$BeforeEnv;TargetSystem=$TargetSystem;TargetEnv=$TargetEnv;Started=(Get-Date).ToString('o')}
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
        if($script:RejectProbe -or ($script:RejectGateway -and $Key -eq 'owned')){return [pscustomobject]@{Key=$Key;Usable=$false;Results=@()}}
        $p=Get-Profile $Key;$body=Read-TestBody $p.Port
        [pscustomobject]@{Key=$Key;Usable=($body -match '[ABD]');Results=@()}
    }


    function Free-Port {$l=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);try{$l.Start();$l.LocalEndpoint.Port}finally{$l.Stop()}}
    $gatewayPort=Free-Port;$deadPort=Free-Port;$privatePort=Free-Port
    $exe=Join-Path $qa 'SavedProgram.exe';Copy-Item "$env:SystemRoot\System32\cmd.exe" $exe
    $config=[pscustomobject]@{Version=3;Profiles=@(@{Id='a';Name='Deleted A';Protocol='http';Host='127.0.0.1';Port=$deadPort;AutoPort=$false},@{Id='b';Name='B';Protocol='http';Host='127.0.0.1';Port=$ports[1];AutoPort=$false},@{Id='owned';Name='Owned';Protocol='http';Host='127.0.0.1';Port=$gatewayPort;CorePath=$testCore;AutoPort=$false});Routing=@{Adapter='standalone';ProfileId='owned';UnifiedMode='gateway';Failover=@{Enabled=$true;Order=@('b','a');AllowDirect=$false}}}
    Write-LocalJson $script:ConfigPath $config;$script:Profiles=Read-ProfileSettings
    $id='8'*32;$siteId='9'*32
    $rules=@{version=3;installed=$true;entries=@();defaultRoute='a';programIngresses=@(@{id=$id;path=$exe;port=$privatePort;route='b'});siteRules=@(@{id=$siteId;scope='global';type='domain';domain='localhost';route='Direct'})}
    Write-LocalJson (Join-Path $script:DataRoot 'app-rules.json') $rules
    Write-LocalJson (Join-Path $script:DataRoot 'program-proxies.json') @{version=1;entries=@()}
    $launchBefore=[IO.File]::ReadAllText((Join-Path $script:DataRoot 'program-proxies.json'))
    $script:FakeSystem=[pscustomobject]@{Flags=3;Server=('127.0.0.1:'+$deadPort);Bypass='localhost'}
    $script:FakeEnv=[pscustomobject]@{HTTP_PROXY=('http://127.0.0.1:'+$deadPort);HTTPS_PROXY=('http://127.0.0.1:'+$deadPort);ALL_PROXY=('http://127.0.0.1:'+$deadPort);NO_PROXY='custom.local'}
    $d=Get-NetworkDiagnosis;Check ($d.RepairAction -eq 'repair-dead-entry') 'Closed A with missing upstream application produces repair plan'
    $fixed=Repair-NetworkDiagnosis $d.Revision
    Check ($script:FakeSystem.Server -eq ('127.0.0.1:'+$gatewayPort)) 'Repair activates real stable gateway rather than depending on removed A'
    Check ((Read-TestBody $gatewayPort) -eq 'B') 'Actual new HTTP request through repaired gateway reaches B'
    Check ((Read-TestBody $privatePort) -eq 'B') 'Saved program private ingress is retained and really forwards to B'
    $live=Invoke-AppRouter @{action='status'}
    Check ($live.available -and $live.defaultLoaded -and $live.effectiveDefaultRoute -eq 'b') 'Controller verifies repaired default outlet B'
    $saved=Get-Content (Join-Path $script:DataRoot 'app-rules.json') -Raw|ConvertFrom-Json
    Check ($saved.programIngresses[0].id -eq $id -and $saved.programIngresses[0].port -eq $privatePort -and $saved.programIngresses[0].route -eq 'b' -and $saved.siteRules[0].id -eq $siteId) 'Repair preserves program selection, private port and domain policy'
    Check ([IO.File]::ReadAllText((Join-Path $script:DataRoot 'program-proxies.json')) -ceq $launchBefore) 'Legacy launch records remain byte-identical'
    $curl=Join-Path $env:SystemRoot 'System32\curl.exe'
    $body=& $curl --silent --show-error --max-time 5 --noproxy '' --proxy ('http://127.0.0.1:'+$gatewayPort) ('http://localhost:'+$ports[2]+'/probe')
    Check ($LASTEXITCODE -eq 0 -and $body -eq 'D') 'Real domain exception still reaches direct marker D after repair'
    Restore-IndependentSession
    Check (-not (Test-Path (Get-IndependentSessionPath)) -and ($script:FakeSystem.Flags -band 2) -eq 0) 'Explicit exit restores direct instead of resurrecting dead A'
    $failed=$false;try{$c=New-Object Net.Sockets.TcpClient;$c.Connect('127.0.0.1',$gatewayPort)}catch{$failed=$true}finally{if($c){$c.Dispose()}}
    Check $failed 'Owned fixed port is closed after explicit recovery'

    $script:FakeSystem=[pscustomobject]@{Flags=3;Server=('127.0.0.1:'+$deadPort);Bypass='localhost'}
    $beforeFailure=[IO.File]::ReadAllText((Join-Path $script:DataRoot 'app-rules.json'))
    $script:RejectGateway=$true;$d=Get-NetworkDiagnosis;$failed=$false
    try{Repair-NetworkDiagnosis $d.Revision|Out-Null}catch{$failed=$true}
    Check ($failed -and $script:FakeSystem.Server -eq ('127.0.0.1:'+$deadPort)) 'Gateway request verification failure never writes Windows entry'
    Check ([IO.File]::ReadAllText((Join-Path $script:DataRoot 'app-rules.json')) -ceq $beforeFailure) 'Real gateway verification failure restores exact prior routing state'
    Check (-not (Test-Path (Get-IndependentSessionPath))) 'Failed gateway repair leaves no recovery session claiming success'
    Write-Output ('PASS: '+$script:checks+' real dead-entry repair and exit checks; actual core and HTTP, Windows writes isolated.')
}finally{
    try{if(Test-Path (Get-IndependentSessionPath)){Restore-IndependentSession}}catch{Write-Warning $_.Exception.Message}
    if($fixture -and -not $fixture.HasExited){$fixture.Kill();$fixture.WaitForExit()}
    $env:PROXY_SWITCH_TEST_HEALTH_URL=$priorHealth
}

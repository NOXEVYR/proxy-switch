$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-ExternalObservation-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
[void][IO.Directory]::CreateDirectory($qa)
$script:checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++}
$script:fixturePath=Join-Path $qa 'external-fixture.yaml'
function Get-ExternalMihomoConfigPath {$script:fixturePath}
function Write-FixtureConfig([string]$Text){[IO.File]::WriteAllText($script:fixturePath,$Text,(New-Object Text.UTF8Encoding($true)))}
$secret='fixture-private-controller-value'
foreach($controller in @('192.0.2.1:9097','0.0.0.0:9097','https://127.0.0.1:9097','127.0.0.1:9097/path','user@127.0.0.1:9097','127.0.0.1:9097?token=hidden','127.0.0.1:0','127.0.0.1:65536')){
    Write-FixtureConfig ("external-controller: "+$controller+"`r`nsecret: "+$secret)
    $result=Read-ExternalMihomoController
    Check ($result.State -eq 'controller-rejected' -and -not $result.PSObject.Properties['Secret']) 'non-loopback or malformed controller was not rejected'
}
Write-FixtureConfig ("external-controller: 'localhost:9097'`r`nsecret: '"+$secret+"'")
$controller=Read-ExternalMihomoController
Check ($controller.State -eq 'configured' -and $controller.Uri -eq 'http://127.0.0.1:9097/connections' -and $controller.Secret -eq $secret) 'existing single-quoted config not read safely'
Write-FixtureConfig ('external-controller: "[::1]:9097"'+"`r`n"+'secret: ""')
Check ((Read-ExternalMihomoController).Uri -eq 'http://[::1]:9097/connections') 'IPv6 loopback or empty quoted secret failed'
Write-FixtureConfig "external-controller: 127.0.0.1:9097`r`nexternal-controller: 127.0.0.1:9098"
Check ((Read-ExternalMihomoController).State -eq 'config-unknown') 'duplicate YAML keys are not safely rejected'
Write-FixtureConfig ('external-controller: 127.0.0.1:9097'+"`r`nsecret: !tag invalid")
Check ((Read-ExternalMihomoController).State -eq 'config-unknown') 'complex YAML scalar is not safely rejected'
Write-FixtureConfig ('external-controller: 127.0.0.1:9097'+"`r`nsecret: '"+$secret+"'`r`n#"+('x'*500000))
Check ((Read-ExternalMihomoController).State -eq 'configured') 'realistic configuration above 256 KiB lost its controller'
Write-FixtureConfig ('#'+('x'*2097153))
Check ((Read-ExternalMihomoController).State -eq 'config-unknown') 'oversized existing configuration not bounded'

# Isolated loopback HTTP fixture; never starts an actual proxy or controller.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class ExternalObservationHttpFixture : IDisposable {
    TcpListener listener; Thread thread; TcpClient client;
    public int Port; public string Request = "";
    public ExternalObservationHttpFixture(string status, string body, int delay, string headers, bool lengthHeader) {
        listener = new TcpListener(IPAddress.Loopback,0); listener.Start(); Port=((IPEndPoint)listener.LocalEndpoint).Port;
        thread = new Thread(delegate() {
            try {
                client=listener.AcceptTcpClient(); client.ReceiveTimeout=1000; client.SendTimeout=1000;
                using(var stream=client.GetStream()) {
                    var reader=new StreamReader(stream,Encoding.ASCII,false,1024,true);
                    string line; var text=new StringBuilder();
                    while(!string.IsNullOrEmpty(line=reader.ReadLine())) text.AppendLine(line);
                    Request=text.ToString(); if(delay>0)Thread.Sleep(delay);
                    byte[] payload=Encoding.UTF8.GetBytes(body);
                    string head="HTTP/1.1 "+status+"\r\nConnection: close\r\n"+headers+(lengthHeader?"Content-Length: "+payload.Length+"\r\n":"")+"\r\n";
                    byte[] prefix=Encoding.ASCII.GetBytes(head); stream.Write(prefix,0,prefix.Length);stream.Write(payload,0,payload.Length);
                }
            }catch {} finally {if(client!=null)client.Close();}
        });thread.IsBackground=true;thread.Start();
    }
    public void Dispose() {listener.Stop();if(client!=null)client.Close();thread.Join(1500);}
}
'@
function Invoke-Fixture([string]$Status,[string]$Body,[int]$Delay=0,[string]$Headers='',[bool]$LengthHeader=$true,[int]$Limit=2097152){
    $server=New-Object ExternalObservationHttpFixture($Status,$Body,$Delay,$Headers,$LengthHeader)
    try{
        $config=[pscustomobject]@{Uri=('http://127.0.0.1:'+$server.Port+'/connections');Secret=$secret}
        $result=Invoke-ExternalMihomoConnections $config -TimeoutMilliseconds 400 -MaxBytes $Limit
        [pscustomobject]@{Result=$result;Request=$server.Request}
    }finally{$server.Dispose()}
}
$fixture=Invoke-Fixture '200 OK' '{"connections":[]}'
Check ($fixture.Result.State -eq 'observed' -and $fixture.Request.StartsWith('GET /connections HTTP/') -and $fixture.Request.Contains('Authorization: Bearer '+$secret)) 'bounded GET request or existing in-memory authentication failed'
foreach($status in @('401 Unauthorized','403 Forbidden')){
    $fixture=Invoke-Fixture $status ('private error '+$secret)
    Check ($fixture.Result.State -eq 'authentication-failed' -and ($fixture.Result|ConvertTo-Json) -notmatch $secret) 'authentication failure leaked response content or lost status'
}
$fixture=Invoke-Fixture '302 Found' '' 0 "Location: http://192.0.2.1/private?token=hidden`r`n"
Check ($fixture.Result.State -eq 'response-rejected') 'controller redirect not rejected'
$fixture=Invoke-Fixture '200 OK' '{"connections":[]}' 800
Check ($fixture.Result.State -eq 'timeout') 'controller timeout not bounded'
$fixture=Invoke-Fixture '200 OK' ('x'*4096) 0 '' $true 1024
Check ($fixture.Result.State -eq 'response-too-large') 'Content-Length cap failed'
$fixture=Invoke-Fixture '200 OK' ('x'*4096) 0 '' $false 1024
Check ($fixture.Result.State -eq 'response-too-large') 'stream cap without Content-Length failed'
$fixture=Invoke-Fixture '200 OK' ('not json '+$secret)
Check ($fixture.Result.State -eq 'unavailable' -and ($fixture.Result|ConvertTo-Json) -notmatch $secret) 'malformed response leaked content'
Check ((Invoke-ExternalMihomoConnections ([pscustomobject]@{Uri='http://192.0.2.1:9097/connections';Secret=$secret})).State -eq 'controller-rejected') 'transport boundary accepted remote controller'

$tcp=[pscustomobject]@{Available=$true;Rows=@([pscustomobject]@{State='Established';LocalAddress='198.18.0.1';LocalPort=50001;OwningProcess=123})}
function Get-ProcessInventory {param($Id);[pscustomobject]@{Id=$Id;ProcessName='ChatGPT';Path='C:\Fixture\ChatGPT.exe';StartTime=[DateTime]::UtcNow}}
$connection=[pscustomobject]@{metadata=[pscustomobject]@{host='chatgpt.com';type='Tun';sourceIP='198.18.0.1';sourcePort='50001';processPath='private-path';url=('https://chatgpt.com/?token='+$secret)};rule='DomainSuffix';rulePayload='private-payload';chains=@('🇯🇵 日本S02 | IEPL','选择节点');id='private-id'}
$data=[pscustomobject]@{connections=@($connection,$connection,[pscustomobject]@{metadata=[pscustomobject]@{host='chatgpt.com.attacker.invalid';type='Tun'};chains=@($secret)})}
$observation=ConvertTo-ExternalMihomoObservation $data $tcp $secret
$json=$observation|ConvertTo-Json -Depth 8
Check ($observation.ConnectionCount -eq 2 -and $observation.Rows.Count -eq 1 -and $observation.Rows[0].Count -eq 2 -and $observation.Rows[0].Source -match '^ChatGPT') 'domain filtering, aggregation or unique TCP source correlation failed'
Check ($observation.Rows[0].Chains[0] -eq '选择节点' -and $observation.Rows[0].Chains[1] -eq '🇯🇵 日本S02 | IEPL' -and (Format-ExternalMihomoObservation $observation) -match '选择节点 → 🇯🇵 日本S02 \| IEPL') 'emoji or pipe node hidden, or policy-to-exit order reversed'
Check ($json -notmatch 'private-|198\.18|50001|token|attacker' -and -not $observation.AuthenticationVerified) 'raw connection metadata or credentials escaped safe projection'
$tcp.Rows+=@($tcp.Rows[0])
Check ((ConvertTo-ExternalMihomoObservation $data $tcp $secret).Rows[0].Source -eq '来源未知') 'ambiguous endpoint falsely identified a process'
$tcp.Rows=@();$connection.chains=@($secret,'https://private.invalid/?token=abc',"bad`r`nlog",'Bearer credential');$connection.rule='private-payload';$connection.metadata.type='private-type'
$observation=ConvertTo-ExternalMihomoObservation $data $tcp $secret
Check (($observation.Rows[0].Chains|Where-Object {$_ -ne '已隐藏'}).Count -eq 0 -and $observation.Rows[0].Type -eq '未知' -and $observation.Rows[0].Rule -eq '未知') 'free text rule, type or sensitive route names leaked'
Check ((Format-ExternalMihomoObservation $observation) -notmatch $secret) 'formatted report exposed a controller secret'
$empty=ConvertTo-ExternalMihomoObservation ([pscustomobject]@{connections=@()}) $tcp
Check ($empty.State -eq 'no-connections' -and (Format-ExternalMihomoObservation $empty) -match '采样间隙') 'absent connection evidence was described as network failure'
$many=@();for($i=0;$i -lt 20;$i++){$many+=[pscustomobject]@{metadata=[pscustomobject]@{host='ws.chatgpt.com';type='HTTP'};rule='Match';chains=@('Node '+$i)}}
$observation=ConvertTo-ExternalMihomoObservation ([pscustomobject]@{connections=$many}) $tcp
Check ($observation.Rows.Count -eq 6 -and $observation.ConnectionCount -eq 20 -and (Format-ExternalMihomoObservation $observation) -match '省略') 'aggregation exceeded six visible rows'
$bounded=ConvertTo-ExternalMihomoObservation ([pscustomobject]@{connections=@($connection)*4097}) $tcp $secret
Check ($bounded.Truncated -and $bounded.ConnectionCount -eq 4096 -and (Format-ExternalMihomoObservation $bounded) -match '不涵盖省略') 'processing bound overclaimed complete connection evidence'

$system=[pscustomobject]@{Flags=3;Server='127.0.0.1:7897'}
$views=[pscustomobject]@{Registry=[pscustomobject]@{Available=$true;Enabled=$false;Server='private-stale-entry'};WinHttpIE=[pscustomobject]@{Available=$true;Server='';HasPac=$false;AutoDetect=$false}}
$summary=ConvertTo-ApplicationProxyViewSummary $system $views
Check ($summary.Different -and $summary.Message -match '应用可能' -and ($summary|ConvertTo-Json) -notmatch 'private-stale-entry|7897') 'proxy views were overclaimed or raw view values escaped'

# Keep real Test-ProxyRoute, stub OS inventory and HTTP transport only.
$script:Profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@([pscustomobject]@{Id='external';Name='Fixture';Protocol='http';Host='127.0.0.1';Port=19001;CorePath='C:\Fixture\unreadable.exe'});Routing=[pscustomobject]@{Adapter='none';ProfileId=''}})
$script:tcpAvailable=$true;$script:listenerRows=@([pscustomobject]@{State='Listen';LocalAddress='127.0.0.1';LocalPort=19001;OwningProcess=123});$script:httpCalls=0
function Get-Listener {param($Profile,[switch]$ProbeRemote,$TcpRows);$null}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$script:tcpAvailable;Rows=$script:listenerRows}}
function Test-HttpEndpoint {param($Profile,$Url);$script:httpCalls++;[pscustomobject]@{Accepted=$true;Site='Fixture';Note='fixture';Seconds=0}}
$check=Test-ProxyRoute 'external'
Check ($check.Ready -and -not $check.OwnerVerified -and $check.Usable -and $script:httpCalls -eq 3) 'manual route probe rejected actual listener with unknown ownership'
$calls=$script:httpCalls;$rejected=$false;try{Test-ProxyRoute 'external' -Fast|Out-Null}catch{$rejected=$true}
Check ($rejected -and $script:httpCalls -eq $calls) 'Fast mutation precheck relaxed ownership'
$script:tcpAvailable=$false;$rejected=$false;try{Test-ProxyRoute 'external'|Out-Null}catch{$rejected=$true}
Check ($rejected -and $script:httpCalls -eq $calls) 'unknown TCP observation authorized manual probe'
$script:tcpAvailable=$true;$script:listenerRows=@([pscustomobject]@{State='Listen';LocalAddress='::';LocalPort=19001;OwningProcess=123})
$rejected=$false;try{Test-ProxyRoute 'external'|Out-Null}catch{$rejected=$true}
Check ($rejected -and $script:httpCalls -eq $calls) 'ambiguous IPv6-only listener authorized IPv4 probe'
Write-Output ('PASS: '+$script:checks+' bounded external observation checks; isolated files, loopback fixture and OS stubs only.')

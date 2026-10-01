param([Parameter(Mandatory=$true)][string]$RuntimeDirectory)
$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-coexistence-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qa)
$node=Join-Path $RuntimeDirectory 'node.exe';$core=Join-Path $qa 'FlowSwitch.Core.exe'
Copy-Item -LiteralPath (Join-Path $RuntimeDirectory 'FlowSwitch.Core.exe') -Destination $core
$fixture=$null;$checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++}
function New-Port {$s=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);try{$s.Start();[int]$s.LocalEndpoint.Port}finally{$s.Stop()}}
try{
 $serverFile=Join-Path $qa 'servers.cjs';$portsFile=Join-Path $qa 'ports.json'
 [IO.File]::WriteAllText($serverFile,@'
const http=require('http'),fs=require('fs');
Promise.all(['A','B','D'].map(x=>new Promise(resolve=>{const s=http.createServer((q,r)=>r.end(x));s.on('connect',(q,c)=>{c.write('HTTP/1.1 200 Connection Established\r\n\r\n');c.once('data',()=>c.end('HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n'+x));});s.listen(0,'127.0.0.1',()=>resolve(s.address().port));}))).then(p=>fs.writeFileSync(process.argv[2],JSON.stringify(p)));
'@)
 $fixture=Start-Process $node -ArgumentList ('"'+$serverFile+'" "'+$portsFile+'"') -WindowStyle Hidden -PassThru
 $deadline=[DateTime]::UtcNow.AddSeconds(8);while(-not [IO.File]::Exists($portsFile) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
 $ports=[IO.File]::ReadAllText($portsFile)|ConvertFrom-Json
 $env:PROXY_SWITCH_TEST_HEALTH_URL='http://127.0.0.1:'+$ports[2]+'/health'
 . (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory (Join-Path $qa 'data')
 $gatewayPort=New-Port;$programPort=New-Port
 $script:Profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(@{Id='gateway';Name='Owned';Protocol='http';Host='127.0.0.1';Port=$gatewayPort;CorePath=$core},@{Id='a';Name='A';Protocol='http';Host='127.0.0.1';Port=$ports[0]},@{Id='b';Name='B';Protocol='http';Host='127.0.0.1';Port=$ports[1]});Routing=@{Adapter='standalone';ProfileId='gateway';UnifiedMode='gateway';Failover=@{Enabled=$true;Order=@('b','a');AllowDirect=$false}}})
 Write-LocalJson $script:ConfigPath $script:Profiles
 Write-LocalJson $script:StatePath @{Key='a';NetworkKey='a';external=$true}
 $selection=[IO.File]::ReadAllText($script:StatePath)
 Write-LocalJson (Join-Path $script:DataRoot 'app-rules.json') @{version=3;installed=$true;defaultRoute='a';entries=@(@{path='C:\Fixture\Other.exe';route='b'});programIngresses=@(@{id='11111111111111111111111111111111';path='C:\Fixture\Qt.exe';port=$programPort;route='Direct'});siteRules=@(@{id='22222222222222222222222222222222';domain='example.invalid';type='domain';scope='global';route='b'})}
 $script:sys=[pscustomobject]@{Flags=3;Server=('127.0.0.1:'+$ports[0]);Bypass='external.local'}
 $script:envs=[pscustomobject]@{HTTP_PROXY=('http://127.0.0.1:'+$ports[0]);HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='custom.local'}
 $originalSystem=Copy-RoutingSnapshot $script:sys;$originalEnv=Copy-RoutingSnapshot $script:envs
 function Get-SystemSnapshot {$script:sys}
 function Get-UserProxyEnv {$script:envs}
 function Set-SystemSnapshot {throw 'Coexistence must not write Windows'}
 function Set-UserProxyEnv {throw 'Coexistence must not write user variables'}
 function Get-NodeRuntimePath {$node}
 function Get-IndependentCoreSource {$core}
 function Use-ChangeLock([scriptblock]$Action){& $Action}
 function Get-ClientInterference {[pscustomobject]@{Tun=$script:Tun;Guard=$true;SystemProxy=$true}}
 function Get-ItemPropertyValue {param($LiteralPath,$Name,$ErrorAction);throw 'No fixture RunOnce'}
 function Remove-ItemProperty {throw 'Must not change RunOnce'}
 function Start-IndependentProtection([int]$OwnerPID,$BeforeSystem,$BeforeEnv,$TargetSystem,$TargetEnv,[switch]$PreserveWindowsSettings){
  Check $PreserveWindowsSettings 'Actual startup requests a program-only protection journal'
  $p=Get-Content (Join-Path $script:DataRoot 'gateway\process.json') -Raw|ConvertFrom-Json
  Write-LocalJson (Get-IndependentSessionPath) @{Version=1;Started=(Get-Date).ToString('o');OwnerPID=$OwnerPID;OwnerStart=(Get-ProcessStartTicks $OwnerPID);SupervisorPID=$p.supervisor;SupervisorStart=$p.supervisorStartTicks;CorePID=$p.core;CoreStart=$p.coreStartTicks;BeforeSystem=$BeforeSystem;BeforeEnv=$BeforeEnv;TargetSystem=$TargetSystem;TargetEnv=$TargetEnv;PreserveWindowsSettings=$true;OwnGatewayEndpoint=('127.0.0.1:'+$gatewayPort)}
 }
 function Read-Body([int]$Port){
  $t=New-Object Net.Sockets.TcpClient
  try{$t.Connect('127.0.0.1',$Port);$s=$t.GetStream();$s.ReadTimeout=4000;$b=[Text.Encoding]::ASCII.GetBytes("GET http://127.0.0.1:$($ports[2])/test HTTP/1.1`r`nHost: 127.0.0.1:$($ports[2])`r`nConnection: close`r`n`r`n");$s.Write($b,0,$b.Length);$r=New-Object IO.StreamReader($s);$v=$r.ReadToEnd();if($v -notmatch '^HTTP/1.[01] 200'){throw 'HTTP request failed'};$v.Substring($v.IndexOf("`r`n`r`n")+4).Trim()}finally{$t.Dispose()}
 }
 $script:Tun=$true;$failed=$false;try{Enable-IndependentGateway -OwnerPID $PID -PreserveWindowsSettings|Out-Null}catch{$failed=$true}
 Check ($failed -and -not (Test-Path (Get-IndependentSessionPath))) 'Known TUN is refused before service startup'
 $script:Tun=$false
 Enable-IndependentGateway -OwnerPID $PID -PreserveWindowsSettings|Out-Null
 $live=Invoke-AppRouter @{action='status'}
 Check ($live.available -and $live.defaultLoaded -and $live.effectiveDefaultRoute -eq 'a') 'Coexisting real core preserves default selector'
 Check ((Read-Body $programPort) -eq 'D' -and (Read-Body $gatewayPort) -eq 'A') 'Real program ingress reaches direct target while default goes through A'
 Check ((Test-SameSnapshot $originalSystem $script:sys) -and (Test-SameEnv $originalEnv $script:envs) -and [IO.File]::ReadAllText($script:StatePath) -ceq $selection) 'Startup leaves Windows, user environment and unified selection untouched'
 $rules=Get-RoutingSnapshot
 Check ($rules.entries.Count -eq 1 -and $rules.siteRules.Count -eq 1 -and $script:Profiles.Routing.Failover.Order[0] -eq 'b') 'Other program, site and backup policies survive actual startup'
 $next=Copy-RoutingSnapshot $rules;$next.programIngresses[0].route='b';$next|Add-Member NoteProperty resetIngressSelections @('11111111111111111111111111111111')
 Set-RoutingSnapshot $next $rules
 Check ((Read-Body $programPort) -eq 'B') 'Same program port switches Direct to B with a real request'
 $before=Get-RoutingSnapshot;$next=Copy-RoutingSnapshot $before;$next.programIngresses[0].route='a';$next|Add-Member NoteProperty resetIngressSelections @('11111111111111111111111111111111')
 Set-RoutingSnapshot $next $before
 Check ((Read-Body $programPort) -eq 'A') 'Same program port switches B to A with a real request'
 $session=Get-Content (Get-IndependentSessionPath) -Raw -Encoding UTF8|ConvertFrom-Json
 $plan=New-ExitRecoveryPlan $session $script:sys $script:envs
 Check ((Test-SameSnapshot $plan.System $script:sys) -and (Test-SameEnv $plan.Environment $script:envs)) 'Exit does not mistake a third-party baseline for an owned proxy'
 $claimed=New-ProgramRouteAccessSession $session $script:sys $script:envs ([pscustomobject]@{Flags=3;Server=('127.0.0.1:'+$gatewayPort);Bypass='external.local'}) (New-EnvTarget $script:envs 'gateway')
 Check ($claimed.PreserveWindowsSettings -eq $false -and (Test-SameSnapshot $claimed.BeforeSystem $script:sys)) 'Later explicit global takeover creates a normal recovery claim with current baseline'
 $owned=Get-Content (Join-Path $script:DataRoot 'gateway\process.json') -Raw|ConvertFrom-Json
 Restore-IndependentSession -GracefulOnly
 Check (-not (Test-Path (Get-IndependentSessionPath)) -and -not (Test-SessionProcess $owned.supervisor $owned.supervisorStartTicks) -and -not (Test-SessionProcess $owned.core $owned.coreStartTicks)) 'Graceful stop confirms only the isolated supervisor and core stopped'
 Check ((Test-SameSnapshot $originalSystem $script:sys) -and (Test-SameEnv $originalEnv $script:envs)) 'Stopping the program-only service preserves the external proxy and user environment'
 # A later explicit global selection must convert the journal before Windows
 # starts pointing at this core; failed conversion must remain recoverable.
 Enable-IndependentGateway -OwnerPID $PID -PreserveWindowsSettings|Out-Null
 function Get-ClientInterference {[pscustomobject]@{Tun=$false;Guard=$false;SystemProxy=$true}}
 function Test-ProxyRoute {param($Key,[switch]$Fast);[pscustomobject]@{Usable=((Read-Body (Get-Profile $Key).Port) -in @('A','B','D'))}}
 function Set-SystemSnapshot($Value){
  if($script:RejectGlobal){throw 'Injected isolated Windows setter failure'}
  $script:sys=$Value
  if($script:ChangeJournal){$script:ChangeJournal=$false;[IO.File]::AppendAllText((Get-IndependentSessionPath),' ');$script:OutsideJournal=[IO.File]::ReadAllText((Get-IndependentSessionPath))}
 }
 function Set-UserProxyEnv($Value,$ExpectedBefore){if(-not (Test-SameEnv $ExpectedBefore $script:envs)){throw 'Environment CAS failed'};$script:envs=$Value}
 $journalBefore=[IO.File]::ReadAllText((Get-IndependentSessionPath));$script:RejectGlobal=$true;$failed=$false
 try{Set-SelectedProxy 'b'|Out-Null}catch{$failed=$true}
 Check ($failed -and [IO.File]::ReadAllText((Get-IndependentSessionPath)) -ceq $journalBefore -and (Test-SameSnapshot $originalSystem $script:sys) -and (Test-SameEnv $originalEnv $script:envs)) 'Failed explicit global takeover rolls back owned environment and restores program-only journal'
 $script:RejectGlobal=$false
 $script:ChangeJournal=$true;$failed=$false
 try{Set-SelectedProxy 'b'|Out-Null}catch{$failed=$true}
 Check ($failed -and [IO.File]::ReadAllText((Get-IndependentSessionPath)) -ceq $script:OutsideJournal) 'Post-commit external journal edit is preserved instead of overwriting it with the old program-only journal'
 Check ((Test-SameSnapshot $originalSystem $script:sys) -and (Test-SameEnv $originalEnv $script:envs) -and (Get-RoutingSnapshot).defaultRoute -eq 'a') 'Failed post-commit session CAS rolls back only owned Windows/environment and routing changes'
 # Restore the fixture-owned original session image for another explicit test.
 # This is isolated test setup, never the product rollback path.
 [IO.File]::WriteAllText((Get-IndependentSessionPath),$journalBefore,(New-Object Text.UTF8Encoding($false)))
 Set-SelectedProxy 'b'|Out-Null
 $claimed=Get-Content (Get-IndependentSessionPath) -Raw -Encoding UTF8|ConvertFrom-Json
 Check ($claimed.PreserveWindowsSettings -eq $false -and $script:sys.Server -eq ('127.0.0.1:'+$gatewayPort) -and (Test-SameSnapshot $claimed.BeforeSystem $originalSystem)) 'Actual unified selection claims the owned gateway with the external recovery baseline'
 Check ((Read-Body $gatewayPort) -eq 'B' -and (Read-Body $programPort) -eq 'B') 'Explicit unified selection routes both stable listeners to B'
 Restore-IndependentSession -GracefulOnly
 Check ((Test-SameSnapshot $originalSystem $script:sys) -and (Test-SameEnv $originalEnv $script:envs) -and -not (Test-Path (Get-IndependentSessionPath))) 'After global takeover, graceful exit restores the still-owned external baseline'
 Write-Output ('PASS: '+$checks+' real coexisting core, Direct/B/A requests, policy and graceful stop assertions; Windows and protection registration are fixture stubs. '+$qa)
}finally{
 if($script:DataRoot -and (Test-Path (Get-IndependentSessionPath))){try{Restore-IndependentSession -GracefulOnly}catch{}}
 if($fixture -and -not $fixture.HasExited){$fixture.Kill();$fixture.WaitForExit();$fixture.Dispose()}
}

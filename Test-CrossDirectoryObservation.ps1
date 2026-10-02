$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-cross-observation-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory (Join-Path $qa 'data')
. (Join-Path $PSScriptRoot 'ProgramFamilyTracking.ps1')
$script:Pass=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:Pass++}
function Get-RegisteredProgramPackages {return @()}
function Get-SystemSnapshot {[pscustomobject]@{Flags=3;Server='127.0.0.1:18790'}}
function Test-ManagedProgramSession {return $true}
function Get-ClientInterference {[pscustomobject]@{Running=$false;Tun=$false;Guard=$false;SystemProxy=$false}}
function Set-SystemSnapshot {throw 'Network writes forbidden'}
function Set-UserProxyEnv {throw 'Environment writes forbidden'}
$rootDir=Join-Path $qa 'app';$externalDir=Join-Path $qa 'external-runtime'
foreach($dir in @($rootDir,$externalDir)){[void][IO.Directory]::CreateDirectory($dir)}
$exe=Join-Path $rootDir 'IDE.exe';$cli=Join-Path $externalDir 'cli.exe';$node=Join-Path $externalDir 'node.exe'
foreach($file in @($exe,$cli,$node)){[IO.File]::WriteAllText($file,'identity fixture only; never executed')}
$shell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$birth=[DateTime]::UtcNow.AddMinutes(-1)
function ProcessRow([int]$Id,[int]$Parent,[string]$Path,[int]$Age=0){[pscustomobject]@{Id=$Id;ParentId=$Parent;Path=$Path;PathStatus='Available';StartTime=$birth.AddSeconds($Age);ProcessName=[IO.Path]::GetFileNameWithoutExtension($Path);MainWindowHandle=$(if($Id -eq 10){[IntPtr]1}else{[IntPtr]::Zero})}}
function Socket([int]$Owner,[int]$Source,[int]$Port){[pscustomobject]@{OwningProcess=$Owner;State='Established';LocalAddress='127.0.0.1';LocalPort=$Source;RemoteAddress='127.0.0.1';RemotePort=$Port}}
function Engine([string]$Path,[int]$Source,[string]$Route='b'){
    [pscustomobject]@{path=$Path;sourceAddress='127.0.0.1';sourcePort=$Source;network='tcp';inbound='HTTP';ingressId='cross-ingress';inboundName='FS-Program-cross-ingress';route=$Route;expectedRoute=$Route;policyMatches=$true}
}
$script:Profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(
    @{Id='gateway';Name='Gateway';Protocol='http';Host='127.0.0.1';Port=18790;CorePath='C:\Test\core.exe'},
    @{Id='a';Name='A';Protocol='http';Host='127.0.0.1';Port=21001},
    @{Id='b';Name='B';Protocol='http';Host='127.0.0.1';Port=21002}
);Routing=@{Adapter='standalone';ProfileId='gateway';UnifiedMode='gateway'}})
$script:Ingress=[pscustomobject]@{id='cross-ingress';path=$exe;port=22111;route='b';managed=$true;loaded=$true;ready=$true;effectiveRoute='b'}
$script:Rules=@();$script:Rows=@((ProcessRow 10 1 $exe),(ProcessRow 11 10 $shell 1),(ProcessRow 12 11 $cli 2),(ProcessRow 13 12 $node 3))
$script:Connections=@((Engine $exe 50010),(Engine $cli 50012),(Engine $node 50013))
function Get-ProcessInventory {return @($script:Rows)}
function Get-RoutingSnapshot {[pscustomobject]@{entries=@($script:Rules);programIngresses=@($script:Ingress);launchEntries=@();defaultRoute='b'}}
function Invoke-AppRouter {[pscustomobject]@{available=$true;rulesAvailable=$true;connectionsAvailable=$true;proxiesAvailable=$true;programIngresses=@($script:Ingress);entries=@($script:Rules|ForEach-Object {[pscustomobject]@{path=$_.path;route=$_.route;loaded=$true;effectiveRoute=$_.route}});connections=@($script:Connections);defaultRoute='b';defaultLoaded=$true}}
$tcp=@((Socket 10 50010 22111),(Socket 12 50012 22111),(Socket 13 50013 22111))
$before=Get-RoutingSnapshot|ConvertTo-Json -Depth 8 -Compress
$snapshot=Get-ApplicationRoutes -TcpRows $tcp
$row=$snapshot.Rows|Where-Object Path -eq $exe
Check ($row.PIDs -eq '10,11,12,13' -and $row.CrossDirectoryPIDs -eq '11,12,13' -and $row.ObservationOnlyPIDs -eq '11,12,13') 'The saved root observes current System32-shell and external CLI/runtime descendants with explicit cross-directory scope'
Check ($row.Loaded -and $row.Status -match '含已验证子进程' -and $row.ControllerObservedCount -eq 3) 'Real observation functions correlate the external descendants with controller-backed private-ingress evidence'
Check (@($snapshot.Rows).Count -eq 1 -and $row.Coverage -match '不写程序规则') 'Unsaved private-ingress helpers fold into their observed root without implying writable scope'
$raw=Get-ProgramFamilyTrackingSnapshot $exe $script:Rows (New-ProgramIdentityContext -Processes $script:Rows -Packages @())
Check ($raw.Members.Count -eq 1 -and $raw.Members.Id -eq 10) 'Cross-directory observation never enlarges original writable or launch-refusal Members'
$bypass=@($tcp|Where-Object OwningProcess -ne 12)+@(Socket 12 50012 21001)
$snapshot=Get-ApplicationRoutes -TcpRows $bypass;$row=$snapshot.Rows|Where-Object Path -eq $exe
Check (-not $row.Loaded -and $row.ProgramEntryState -eq 'Partial' -and $row.Actual -match 'A ×1' -and $row.Status -notmatch '网站分流') 'An external CLI still using old A is visible in the parent and cannot be certified by root B'
$script:Rules=@([pscustomobject]@{path=$cli;route='Direct'})
$cliEngine=[pscustomobject]@{path=$cli;sourceAddress='127.0.0.1';sourcePort=50012;network='tcp';inbound='HTTP';route='Direct'}
$nodeEngine=$cliEngine.PSObject.Copy();$nodeEngine.path=$node;$nodeEngine.sourcePort=50013
$script:Connections=@((Engine $exe 50010),$cliEngine,$nodeEngine)
$splitTcp=@((Socket 10 50010 22111),(Socket 12 50012 18790),(Socket 13 50013 18790))
$snapshot=Get-ApplicationRoutes -TcpRows $splitTcp;$parent=$snapshot.Rows|Where-Object Path -eq $exe;$child=$snapshot.Rows|Where-Object Path -eq $cli
Check ($parent.PIDs -eq '10,11' -and $parent.Loaded -and $parent.Actual -eq 'B ×1') 'A separately saved external child keeps its entire observed subtree out of the parent route evidence'
Check ($child.PIDs -eq '12,13' -and $child.Loaded -and $child.Policy -eq 'Direct' -and @($snapshot.Rows).Count -eq 2) 'The explicit child policy retains its own runtime observations and route status'
$script:Rules=@();$script:Connections=@((Engine $exe 50010),(Engine $cli 50012),(Engine $node 50013))
$script:Rows+=@(ProcessRow 20 1 $cli 5)
$unrelatedTcp=$tcp+@(Socket 20 50020 21001)
$snapshot=Get-ApplicationRoutes -TcpRows $unrelatedTcp
Check (@($snapshot.Rows|Where-Object Path -eq $cli).Count -eq 1 -and ($snapshot.Rows|Where-Object Path -eq $exe).PIDs -notmatch '20') 'An unrelated process using the same external executable keeps its own row and is not claimed by parent ancestry'
$script:Rows=@($script:Rows|Where-Object Id -ne 10)
$snapshot=Get-ApplicationRoutes -TcpRows $tcp;$row=$snapshot.Rows|Where-Object Path -eq $exe
Check (-not $row.Loaded -and -not $row.PIDs -and $row.ObservationState -eq 'NotRunning') 'A vanished root cannot keep cross-directory descendants using a cached parent PID'
Check ((Get-RoutingSnapshot|ConvertTo-Json -Depth 8 -Compress) -ceq $before) 'All routing observations preserve saved program entrances and rules'
Write-Output ('PASS: '+$script:Pass+' cross-directory observation assertions; isolated files and synthetic process/TCP/controller snapshots only.')

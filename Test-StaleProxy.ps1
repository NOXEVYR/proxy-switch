$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-residue-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($qa)
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
. (Join-Path $PSScriptRoot 'StaleProxy.ps1')
$script:checks=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Must-Block($Action,[string]$Message){$blocked=$false;try{& $Action}catch{$blocked=$true};Check $blocked $Message}
function Set-SystemSnapshot {throw 'Forbidden Windows write'}
function Set-UserProxyEnv {throw 'Forbidden user environment write'}
function Set-RoutingSnapshot {throw 'Forbidden routing write'}
function Start-ManagedProgram {throw 'Forbidden managed launch'}
function Enable-IndependentGateway {throw 'Forbidden gateway startup'}
function Get-Listener { [pscustomobject]@{PID=17} }
$proc=[pscustomobject]@{Id=700001;Path='C:\Fixture\Reader.exe';StartTime=[DateTime]::UtcNow;MainWindowHandle=[IntPtr]1}
$ctx=[pscustomobject]@{Endpoint=[pscustomobject]@{Host='127.0.0.1';Port=17897}}
$tcp=[pscustomobject]@{Available=$true;Rows=@()}
function Observation([string]$State='Observed',[int]$Port=17777){[pscustomobject]@{State=$State;ReasonCode='Verified';Variables=@([pscustomobject]@{Name='HTTPS_PROXY';State='Observed';EndpointKind='Loopback';LoopbackHost='127.0.0.1';Port=$Port;HasCredentials=$false});NoProxyBroadBypass=$false}}
$o=Observation
$row=ConvertTo-StaleProxyMember $proc $o $tcp $ctx
Check ($row.State -eq 'StaleLocal' -and $row.Entries[0].Listening -eq $false) 'dead local variable is residue'
Check ($row.Detail -match '可能' -and -not $row.Entries[0].ConnectionObserved) 'variable is not claimed as actual routing'
$tcp.Rows=@([pscustomobject]@{State='SynSent';RemoteAddress='::1';RemotePort=17777;OwningProcess=$proc.Id})
Check (-not (ConvertTo-StaleProxyMember $proc $o $tcp $ctx).Entries[0].ConnectionObserved) 'IPv6 connection cannot confirm literal IPv4 proxy'
$tcp.Rows[0].RemoteAddress='127.0.0.1'
Check ((ConvertTo-StaleProxyMember $proc $o $tcp $ctx).Entries[0].ConnectionObserved) 'exact IPv4 process connection is observed'
$o.Variables[0].LoopbackHost='::1'
Check (-not (ConvertTo-StaleProxyMember $proc $o $tcp $ctx).Entries[0].ConnectionObserved) 'IPv4 connection cannot confirm literal IPv6 proxy'
$o.Variables[0].LoopbackHost='localhost'
Check ((ConvertTo-StaleProxyMember $proc $o $tcp $ctx).Entries[0].ConnectionObserved) 'localhost can match either loopback family'
$o=Observation;$tcp.Rows=@()
$tcp.Available=$false
Check ((ConvertTo-StaleProxyMember $proc $o $tcp $ctx).State -eq 'Unknown') 'failed TCP collection stays unknown'
$tcp.Available=$true;$tcp.Rows=@([pscustomobject]@{State='Listen';LocalAddress='::';LocalPort=17777;OwningProcess=17})
Check ((ConvertTo-StaleProxyMember $proc $o $tcp $ctx).State -eq 'Unknown') 'IPv6 wildcard does not prove IPv4 stopped'
$tcp.Rows=@([pscustomobject]@{State='Listen';LocalAddress='127.0.0.1';LocalPort=17777;OwningProcess=17})
Check ((ConvertTo-StaleProxyMember $proc $o $tcp $ctx).State -eq 'Different') 'live dedicated endpoint is not dead'
$o.Variables[0].Port=17897;$tcp.Rows[0].LocalPort=17897
Check ((ConvertTo-StaleProxyMember $proc $o $tcp $ctx).State -eq 'Aligned') 'same live endpoint is aligned only'
$o.NoProxyBroadBypass=$true
Check ((ConvertTo-StaleProxyMember $proc $o $tcp $ctx).State -eq 'Bypass') 'broad bypass is visible without clearing it'
$o=Observation 'Unknown'
Check ((ConvertTo-StaleProxyMember $proc $o $tcp $ctx).State -eq 'Unknown') 'reader unknown never becomes absent'
$o=Observation 'Absent';$o.Variables=@()
Check ((ConvertTo-StaleProxyMember $proc $o $tcp $ctx).State -eq 'Absent') 'absence retains system proxy caveat'
$o=Observation;$o.Variables[0].EndpointKind='External';$o.Variables[0].Port=0;$o.Variables[0].LoopbackHost=''
Check ((ConvertTo-StaleProxyMember $proc $o $tcp $ctx).State -eq 'Different') 'external value is not treated as stopped'
$o=Observation;$o.Variables[0].State='Unknown';$o.Variables[0].EndpointKind='Unknown'
Check ((ConvertTo-StaleProxyMember $proc $o $tcp $ctx).State -eq 'Unknown') 'unsupported variable remains unknown'
$script:Profiles=[pscustomobject]@{Profiles=@();Routing=[pscustomobject]@{Adapter='none'}}
function Get-ProgramProxyAdapter {'chromium'}
Check (-not (Test-StaleProxySupportedPath 'F:\steam\steamapps\common\Game\Game.exe')) 'games excluded from environment reads'
Check (-not (Test-StaleProxySupportedPath ($env:SystemRoot+'\app.exe'))) 'system images excluded'
$script:Profiles.Profiles=@([pscustomobject]@{AppPath='C:\Fixture\Client.exe';CorePath='C:\Fixture\Core.exe'})
Check (-not (Test-StaleProxySupportedPath 'C:\Fixture\Client.exe')) 'proxy client excluded'
Check (Test-StaleProxySupportedPath 'C:\Fixture\Reader.exe') 'supported desktop app eligible'

# Report collection is isolated; only explicit calls may inspect an environment.
$script:reads=0;$script:contextCalls=0;$script:changeDuringScan=$false
function Get-StaleProxyCurrentContext {$script:contextCalls++;[pscustomobject]@{Key='Clash';Endpoint=[pscustomobject]@{Host='127.0.0.1';Port=17897};Fingerprint=$(if($script:changeDuringScan -and $script:contextCalls -gt 1){'changed'}else{'stable'})}}
$script:inventoryCalls=0;$script:pidChanged=$false
function Get-ProcessInventory { $script:inventoryCalls++;if($script:pidChanged -and $script:inventoryCalls -gt 1){return @()};@($proc) }
function Get-ProgramLaunchEntries { @() }
$script:extraMembers=@();$script:savedRules=[pscustomobject]@{entries=@();programIngresses=@();launchEntries=@()}
function Get-RoutingSnapshot {$script:savedRules}
function Get-ProgramFamilyTrackingSnapshot {[pscustomobject]@{Available=$true;Members=@($proc)+@($script:extraMembers);UnknownIds=@();ObservationTruncated=$false}}
function ConvertTo-ProgramObservationFamily($Snapshot){$Snapshot}
function Get-ProcessProxyEnvironmentObservation {$script:reads++;Observation}
$script:tcpCalls=0;$script:recoverDuringScan=$false
function Get-TcpObservationSnapshot {$script:tcpCalls++;[pscustomobject]@{Available=$true;Rows=@(if($script:recoverDuringScan -and $script:tcpCalls -gt 1){[pscustomobject]@{State='Listen';LocalAddress='127.0.0.1';LocalPort=17777;OwningProcess=17}})}}
$report=Get-StaleProxyReport -Path $proc.Path
Check ($script:reads -eq 1 -and $report.StaleCount -eq 1 -and $report.Rows[0].Members[0].PID -eq $proc.Id) 'explicit report attributes exact process'
foreach($excluded in @(($env:SystemRoot+'\app.exe'),'F:\Steam\steamapps\common\Game\Game.exe','C:\Fixture\Client.exe')){
    $script:extraMembers=@([pscustomobject]@{Id=700002;Path=$excluded;StartTime=$proc.StartTime;MainWindowHandle=[IntPtr]::Zero});$before=$script:reads
    $report=Get-StaleProxyReport -Path $proc.Path
    Check ($script:reads -eq $before+1 -and $report.Rows[0].CoverageLimited -and $report.Rows[0].Members.Count -eq 1) 'excluded family member is never read'
}
$script:extraMembers=@();$script:savedRules.launchEntries=@([pscustomobject]@{path=$proc.Path;adapter='environment';route='Follow'})
$report=Get-StaleProxyReport -Path $proc.Path
Check ($report.Rows[0].HasSavedRoute -and -not $report.Rows[0].CanPrepareLaunch) 'existing environment adapter uses route guidance instead of impossible repair'
$script:savedRules.launchEntries=@();$script:inventoryCalls=0;$script:pidChanged=$true
$report=Get-StaleProxyReport -Path $proc.Path
Check ($report.StaleCount -eq 0 -and $report.Rows[0].Members[0].ReasonCode -eq 'IdentityChanged') 'process disappearance invalidates old residue evidence'
$script:pidChanged=$false
$script:changeDuringScan=$true;$script:contextCalls=0
$report=Get-StaleProxyReport -Path $proc.Path
Check ($report.SettingsChanged -and $report.StaleCount -eq 0 -and -not $report.Rows[0].CanPrepareLaunch) 'changed settings invalidate comparisons'
$script:changeDuringScan=$false;$script:contextCalls=0
$script:tcpCalls=0;$script:recoverDuringScan=$true
$report=Get-StaleProxyReport -Path $proc.Path
Check ($report.StaleCount -eq 0 -and $report.Rows[0].Members[0].ReasonCode -eq 'EndpointChanged') 'recovered listener is not published as dead'
$script:recoverDuringScan=$false
$cancel=New-Object Threading.CancellationTokenSource;$cancel.Cancel();$before=$script:reads
$report=Get-StaleProxyReport -Path $proc.Path -Cancellation $cancel
Check ($report.CoverageLimited -and $script:reads -eq $before) 'cancelled scan performs no process reads'
$cancel.Dispose()

# Real isolated child verifies repair changes only its inherited proxy block.
$fixture=Join-Path $qa 'Fixture.exe';$out=Join-Path $qa 'launch-result.txt'
$source=@'
using System; using System.IO;
public static class Entry { public static void Main() {
 string p=Environment.GetEnvironmentVariable("HTTPS_PROXY");
 string n=Environment.GetEnvironmentVariable("NO_PROXY");
 File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"launch-result.txt"),
 (p=="http://127.0.0.1:17897"?"proxy-ok":"proxy-bad")+"|"+(n!=null&&n.Contains("company.local")&&n.Contains("127.0.0.1")?"bypass-ok":"bypass-bad"));
} }
'@
Add-Type -TypeDefinition $source -OutputAssembly $fixture -OutputType ConsoleApplication
$script:policyContext=[pscustomobject]@{System=[pscustomobject]@{Flags=2;Server='127.0.0.1:17897'};WindowsViews=[pscustomobject]@{WinHttpIE=[pscustomobject]@{AutoDetect=$false;HasPac=$false};Summary=[pscustomobject]@{Different=$false}};Environment=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:17897';HTTPS_PROXY='http://127.0.0.1:17897';ALL_PROXY='http://127.0.0.1:17897';NO_PROXY='company.local'};Rules=$script:savedRules}
$script:endpointState='Ready';$script:endpointIdentity='fixture-core-1';$script:viewsReady=$true
function Get-DailyProxyContext {$script:policyContext}
function Test-DailyProxyWindowsTarget {$script:viewsReady}
function Get-SystemKey {'Clash'}
function Get-EndpointKey($Value){if(-not $Value){return 'Unset'};if($Value -eq 'http://127.0.0.1:17897'){return 'Clash'};return 'Other'}
function Get-Profile {[pscustomobject]@{Protocol='http';Host='127.0.0.1';Port=17897}}
function Get-DailyProxyEndpoint {[pscustomobject]@{State=$script:endpointState;Identity=$script:endpointIdentity}}
$first=Get-StaleProxyLaunchContext $fixture
Check ($first.ProxyUri -eq 'http://127.0.0.1:17897' -and $first.Revision) 'real launch context binds file identity and ready endpoint'
$script:endpointIdentity='fixture-core-2';$second=Get-StaleProxyLaunchContext $fixture
Check ($first.Revision -ne $second.Revision) 'endpoint owner change invalidates revision'
$script:endpointState='Unknown';Must-Block {Get-StaleProxyLaunchContext $fixture} 'unknown endpoint cannot prepare launch';$script:endpointState='Ready'
$script:policyContext.Environment.HTTPS_PROXY='http://127.0.0.1:17777';Must-Block {Get-StaleProxyLaunchContext $fixture} 'conflicting persistent proxy blocks repair';$script:policyContext.Environment.HTTPS_PROXY='http://127.0.0.1:17897'
$script:policyContext.Environment.NO_PROXY='*';Must-Block {Get-StaleProxyLaunchContext $fixture} 'broad bypass cannot be silently rewritten';$script:policyContext.Environment.NO_PROXY='company.local'
$script:viewsReady=$false;Must-Block {Get-StaleProxyLaunchContext $fixture} 'unknown Windows view blocks repair';$script:viewsReady=$true
$script:policyContext.WindowsViews.WinHttpIE.HasPac=$true;Must-Block {Get-StaleProxyLaunchContext $fixture} 'PAC is not replaced by manual child proxy';$script:policyContext.WindowsViews.WinHttpIE.HasPac=$false
foreach($slot in @('entries','programIngresses','launchEntries')){
    $script:savedRules.$slot=@([pscustomobject]@{path=$fixture;route='Follow'})
    Must-Block {Get-StaleProxyLaunchContext $fixture} ('existing '+$slot+' preserved')
    $script:savedRules.$slot=@()
}
$script:launchContext=[pscustomobject]@{Path=$fixture;Key='Clash';ProxyUri='http://127.0.0.1:17897';NoProxy='company.local';Revision='fixture-current'}
$script:running=$true;$script:stoppedChecks=0
function Get-StaleProxyLaunchContext {$script:launchContext}
function Assert-CleanProgramStopped {$script:stoppedChecks++;if($script:running){throw 'fixture still running'}}
function Use-ChangeLock($Action){& $Action}
$plan=Get-StaleProxyLaunchPlan $fixture
Check (-not $plan.CanLaunch -and $plan.Reason -match '不会结束') 'running app receives a useful refusal'
Must-Block {Start-StaleProxyProgram $plan -Confirmed} 'running preview cannot launch'
Check (-not (Test-Path -LiteralPath $out)) 'refused operation produced no child output'
$script:running=$false;$plan=Get-StaleProxyLaunchPlan $fixture
Must-Block {Start-StaleProxyProgram $plan} 'explicit confirmation required'
$plan.Revision='changed';Must-Block {Start-StaleProxyProgram $plan -Confirmed} 'stale revision rejected'
$plan=Get-StaleProxyLaunchPlan $fixture;$plan.CreatedAt-=121
Must-Block {Start-StaleProxyProgram $plan -Confirmed} 'expired plan rejected'
$plan=Get-StaleProxyLaunchPlan $fixture;$script:running=$true
Must-Block {Start-StaleProxyProgram $plan -Confirmed} 'program restarted after preview rejected'
$script:running=$false;$beforeEnv=[Environment]::GetEnvironmentVariable('HTTPS_PROXY','Process');$beforeUser=[Environment]::GetEnvironmentVariable('HTTPS_PROXY','User')
$start=New-StaleProxyStartInfo $script:launchContext
Check ($start.EnvironmentVariables['HTTPS_PROXY'] -eq 'http://127.0.0.1:17897' -and -not $start.UseShellExecute) 'fresh child has requested proxy'
Check ($start.EnvironmentVariables['NO_PROXY'] -match 'company.local' -and $start.EnvironmentVariables['NO_PROXY'] -ne '*') 'preserves bypass without disabling all proxy use'
$plan=Get-StaleProxyLaunchPlan $fixture;$launch=Start-StaleProxyProgram $plan -Confirmed
$limit=[DateTime]::UtcNow.AddSeconds(5);while(-not (Test-Path -LiteralPath $out) -and [DateTime]::UtcNow -lt $limit){Start-Sleep -Milliseconds 50}
Check ((Get-Content -LiteralPath $out -Raw) -eq 'proxy-ok|bypass-ok') 'real child received fresh proxy and bypass'
Check ([Environment]::GetEnvironmentVariable('HTTPS_PROXY','Process') -ceq $beforeEnv) 'parent process environment unchanged'
Check ([Environment]::GetEnvironmentVariable('HTTPS_PROXY','User') -ceq $beforeUser) 'persistent user environment unchanged'
Check ($script:stoppedChecks -ge 4) 'stop state rechecked at apply boundary'
Write-Output ('PASS: '+$script:checks+' residue orchestration checks; isolated child; no system or user-program changes.')

$ErrorActionPreference='Stop'
# Extract only pure topology/client observation functions: no user configuration,
# operating-system network writes, or real adapter/process queries in this test.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'ProxyBackend.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Backend parse failed'}
foreach($name in @('ConvertTo-NetworkTopologyObservation','Get-NetworkTopologyObservation','Get-ClientInterference','Get-ClientWarnings')){
    $node=$ast.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name},$true)|Select-Object -First 1
    if(-not $node){throw ('Missing topology function: '+$name)}
    Invoke-Expression $node.Extent.Text
}
$script:Checks=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
function Adapter([int]$Index,[string]$Description='tun2socks Tunnel',[int]$Type=53,[bool]$Hardware=$false,[string]$Status='Up'){
    [pscustomobject]@{ifIndex=$Index;Name='fixture';InterfaceDescription=$Description;InterfaceType=$Type;HardwareInterface=$Hardware;Status=$Status}
}
function Route([int]$Index,[string]$Prefix){[pscustomobject]@{InterfaceIndex=$Index;DestinationPrefix=$Prefix;State='Alive'}}
$tunnel=Adapter 47;$physical=Adapter 12 'Ethernet' 6 $true
$dual=ConvertTo-NetworkTopologyObservation @($tunnel,$physical) @((Route 47 '0.0.0.0/0'),(Route 47 '::/0'),(Route 12 '0.0.0.0/0'))
Check ($dual.State -eq 'Evidence' -and $dual.IPv4 -eq 'Evidence' -and $dual.IPv6 -eq 'Evidence' -and $dual.InterfaceIndices -contains 47) 'An active tun2socks interface with IPv4 and IPv6 broad routes is detected without a VPN brand'
Check ($dual.Coverage -match '不证明特定请求.*全部流量' -and $dual.Coverage -match '不等于隧道已关闭') 'Route evidence never certifies every request or declares all tunnels closed'
$v4=ConvertTo-NetworkTopologyObservation @($tunnel) @((Route 47 '0.0.0.0/0'))
Check ($v4.State -eq 'Evidence' -and $v4.IPv6 -eq 'NoEvidence') 'IPv4 evidence does not imply IPv6 coverage'
$typed=ConvertTo-NetworkTopologyObservation @((Adapter 48 'generic interface' 131)) @((Route 48 '::/0'))
Check ($typed.IPv6 -eq 'Evidence') 'Tunnel interface type and a broad route work without technical or product names'
$namedOnly=ConvertTo-NetworkTopologyObservation @($tunnel) @()
Check ($namedOnly.State -eq 'NoEvidence' -and -not $namedOnly.HasTunnelRouteEvidence) 'A technical adapter name alone does not prove routed interception'
$vendorOnly=ConvertTo-NetworkTopologyObservation @((Adapter 49 '365VPN' 6)) @((Route 49 '0.0.0.0/0'))
Check ($vendorOnly.State -eq 'Unknown' -and -not $vendorOnly.HasTunnelRouteEvidence) 'A vendor name on an opaque virtual interface is unknown instead of proof'
$misnamed=ConvertTo-NetworkTopologyObservation @((Adapter 12 'VPN Tunnel' 6 $true)) @((Route 12 '0.0.0.0/0'))
Check ($misnamed.State -eq 'NoEvidence') 'A physical adapter name cannot invent a tunnel'
$plain=ConvertTo-NetworkTopologyObservation @($physical) @((Route 12 '0.0.0.0/0'),(Route 12 '::/0'))
Check ($plain.State -eq 'NoEvidence' -and $plain.Available) 'Ordinary dual-stack physical routes have no broad tunnel evidence'
$split=ConvertTo-NetworkTopologyObservation @($tunnel) @((Route 47 '0.0.0.0/1'),(Route 47 '128.0.0.0/1'),(Route 47 '::/1'),(Route 47 '8000::/1'))
Check ($split.IPv4 -eq 'Evidence' -and $split.IPv6 -eq 'Evidence') 'Paired split-default routes identify broad IPv4 and IPv6 tunnel routes'
$single=ConvertTo-NetworkTopologyObservation @($tunnel,$physical) @((Route 47 '0.0.0.0/1'),(Route 12 '128.0.0.0/1'))
Check ($single.State -eq 'NoEvidence') 'Split defaults on different interfaces are not combined into broad tunnel evidence'
$stale=ConvertTo-NetworkTopologyObservation @((Adapter 47 'tun2socks Tunnel' 53 $false 'Down')) @((Route 47 '0.0.0.0/0'))
Check ($stale.State -eq 'Unknown') 'An inactive interface with a retained route is inconsistent evidence, not an active tunnel'
$missing=ConvertTo-NetworkTopologyObservation @($physical) @((Route 47 '::/0'))
Check ($missing.State -eq 'Unknown') 'An unreadable route owner cannot be interpreted as a closed tunnel'
$duplicate=ConvertTo-NetworkTopologyObservation @($tunnel,$tunnel) @((Route 47 '::/0'))
Check ($duplicate.State -eq 'Unknown') 'Conflicting duplicate adapter identity is not guessed'
foreach($available in @(@($false,$true),@($true,$false))){
    $unreadable=ConvertTo-NetworkTopologyObservation @($tunnel) @((Route 47 '::/0')) $available[0] $available[1]
    Check ($unreadable.State -eq 'Unknown' -and -not $unreadable.Available -and -not $unreadable.HasTunnelRouteEvidence) 'Adapter or route read failure remains explicitly unknown'
}
$script:Adapters=@($tunnel);$script:Routes=@((Route 47 '0.0.0.0/0'),(Route 47 '::/0'));$script:FailAdapters=$false;$script:FailRoutes=$false;$script:Reads=0
function Get-NetAdapter {param([switch]$IncludeHidden,$ErrorAction) $script:Reads++;if($script:FailAdapters){throw 'fixture error'};@($script:Adapters)}
function Get-NetRoute {param($PolicyStore,$ErrorAction) $script:Reads++;if($script:FailRoutes){throw 'fixture error'};@($script:Routes)}
function Get-Process {param($Name,$ErrorAction) @()}
$script:Profiles=[pscustomobject]@{Routing=[pscustomobject]@{UnifiedMode='gateway'}}
$client=Get-ClientInterference
Check ($client.Tun -and $client.TunSource -eq 'NetworkRoutes' -and $client.Topology.State -eq 'Evidence' -and -not $client.Running) 'Generic routes feed the compatible TUN boolean without pretending Clash is running'
$warning=@(Get-ClientWarnings) -join ' '
Check ($warning -match '外部隧道.*广域路由证据' -and $warning -match '直连出口仍受系统 VPN 路由影响') 'Warnings describe the external layer and the Direct boundary'
$script:FailAdapters=$true;$client=Get-ClientInterference
Check (-not $client.Tun -and $client.Topology.State -eq 'Unknown' -and $client.TunSource -eq 'Unconfirmed') 'The compatibility false boolean retains its independent unknown topology evidence'
Check ((@(Get-ClientWarnings) -join ' ') -match '未知状态.*已关闭') 'Unavailable topology remains visible to users'
$script:FailAdapters=$false;$script:FailRoutes=$true
Check ((Get-NetworkTopologyObservation).State -eq 'Unknown') 'The live wrapper preserves route collection failure without raw exception text'
$script:FailRoutes=$false;$script:Adapters=@($physical);$script:Routes=@((Route 12 '0.0.0.0/0'))
Check ((Get-NetworkTopologyObservation).State -eq 'NoEvidence') 'Each observation re-reads the injected network snapshots rather than retaining a previous tunnel'
Check ($script:Reads -eq 12) 'All six wrapper observations use only the injected adapter and route providers'
Write-Output ('PASS: '+$script:Checks+' network topology assertions; injected adapters, routes and process presence only.')

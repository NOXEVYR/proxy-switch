$ErrorActionPreference='Stop'
$env:PROXY_SWITCH_DATA_DIR=Join-Path $env:TEMP ('FlowSwitch-self-discovery-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1')
$script:Pass=0
function Check($Condition,$Message){if(-not $Condition){throw $Message};$script:Pass++}
$gateway=[pscustomobject]@{Id='own';Name='Own entry';Protocol='http';Host='127.0.0.1';Port=18832;CorePath=(Join-Path $script:DataRoot 'gateway\runtime\FlowSwitch.Core.exe');AppPath='';AutoPort=$false}
$script:Profiles=ConvertTo-ValidProfileSettings @{Version=3;Profiles=@($gateway);Routing=@{Adapter='standalone';ProfileId='own';UnifiedMode='gateway'};DiscoveryIgnored=@()}
Write-LocalJson (Join-Path $script:DataRoot 'app-rules.json') @{version=3;entries=@();programIngresses=@(@{port=19563})}
function Endpoint($port,$path=''){[pscustomobject]@{Id=('p'+$port);Name='mihomo';Host='127.0.0.1';Port=$port;Path=$path;CorePath=$path;Protocol='http';AppPath='';AutoPort=$false}}
$own=Endpoint 18832 $gateway.CorePath;$program=Endpoint 19563;$upstream=Endpoint 7892 'C:\Fixtures\mihomo.exe'
Check (Test-DiscoveryOwnEndpoint $own) 'Gateway port is excluded without hardcoded 18790'
Check (Test-DiscoveryOwnEndpoint $program) 'Program port is excluded without hardcoded 19080'
Check (Test-DiscoveryOwnEndpoint (Endpoint 19955 $gateway.CorePath)) 'Owned runtime is excluded even before its ingress appears in state'
Check (-not (Test-DiscoveryOwnEndpoint $upstream)) 'A different proxy remains discoverable'
Check (@(Get-ProxyDiscoveryListeners -Automatic -Inventory @($own,$program,$upstream)).Count -eq 1) 'Active discovery excludes owned endpoints before probing'
function Test-LocalProxyProtocol {throw 'Owned endpoint must never be probed'}
Check (@(Find-LocalProxies @($own,$program)).Count -eq 0) 'Explicit discovery cannot probe own listeners'
$merged=Merge-DiscoveredProfiles $script:Profiles @($own,$program,$upstream)
Check ($merged.Added.Count -eq 1 -and $merged.Added[0].Port -eq 7892 -and $merged.Settings.Profiles.Count -eq 2) 'Cached candidates are rechecked while saving, preserving legitimate own profile'
function Get-SystemSnapshot {[pscustomobject]@{Flags=2;Server='127.0.0.1:19563';Bypass=''}}
function Get-UserProxyEnv {[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:18832';HTTPS_PROXY='';ALL_PROXY=''}}
Check (@(Get-ConfiguredLocalProxies @($own,$program)).Count -eq 0) 'System and environment discovery cannot reimport own gateway'
[IO.File]::WriteAllText((Join-Path $script:DataRoot 'app-rules.json'),'invalid')
$rejected=$false;try{Merge-DiscoveredProfiles $script:Profiles @($upstream)|Out-Null}catch{$rejected=$true}
Check $rejected 'Unreadable routing state pauses discovery instead of guessing'
Write-Output ('PASS: '+$script:Pass+' self-ingress discovery checks; isolated configuration only.')

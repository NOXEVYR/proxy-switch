$ErrorActionPreference='Stop'
# Isolated in-memory fixture: never load real user configuration or start a client.
. (Join-Path $PSScriptRoot 'NetworkDoctor.ps1')
$script:realDoctorRoamingDirectory=${function:Get-NetworkDoctorRoamingDirectory}
$script:realDoctorClientBuild=${function:Get-NetworkDoctorClientBuild}
$script:checks=0;$script:starts=0;$script:probes=0;$script:locks=0;$script:locked=$false
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Pattern){$message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message};Check ($message -match $Pattern) ('Expected '+$Pattern+', got '+$message)}
function Get-DailyProxyHash($Value){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 32 -Compress))))}finally{$sha.Dispose()}}
function Reset-Fixture {
    $script:Profiles=[pscustomobject]@{Routing=[pscustomobject]@{Adapter='none'};Profiles=@([pscustomobject]@{Id='home_a';Protocol='http';Host='127.0.0.1';Port=17897;CorePath='C:\Fixture\verge-mihomo.exe'},[pscustomobject]@{Id='work_b';Protocol='http';Host='127.0.0.1';Port=15777;CorePath='C:\FixtureVPN\other.exe'})}
    $script:context=[pscustomobject]@{Settings=$script:Profiles;System=[pscustomobject]@{Flags=3;Server='127.0.0.1:17897';Bypass='<local>'};Environment=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:17897';HTTPS_PROXY='http://127.0.0.1:17897';ALL_PROXY='http://127.0.0.1:17897';NO_PROXY='private-fixture'};WindowsViews=[pscustomobject]@{Registry=[pscustomobject]@{Available=$true};WinHttpIE=[pscustomobject]@{Available=$true;AutoDetect=$false;HasPac=$false}};Client=[pscustomobject]@{Tun=$false;Guard=$false;Topology=[pscustomobject]@{Available=$true;State='NoEvidence';IPv4='NoEvidence';IPv6='NoEvidence'}};Files=[pscustomobject]@{'gateway-session.json'='<missing>';config='fixture-v1'};Rules=[pscustomobject]@{Entries=@('preserve-program-route')};Selection='home_a'}
    $script:endpointState='Stopped';$script:endpointStates=@{};$script:endpointKeys=@();$script:identity='generation1';$script:rows=@();$script:unknownFile=$false;$script:fileGeneration=1;$script:throwInventory=$false;$script:probeUsable=$true;$script:probeRace=$false;$script:mismatch=$false;$script:NetworkDoctorConsumedPlans=@{};$script:throwStart=$false
    $script:startupText="enable_tun_mode: false`nenable_proxy_guard: false`nenable_system_proxy: true`nstartup_script: null`n";$script:startupReadFails=$false
    $script:knownRoaming='C:\FixtureKnownRoaming';$script:startupReadPath=''
    $script:clientBuild=[pscustomobject]@{Status='Available';ProductName='Clash Verge';CompanyName='Clash Verge Rev';FileVersion='2.5.8';ProductVersion='2.5.8';SHA256='DC1D520954A2B44F8AD9C0801413A3A7303209681013084D6EC46893ABF3216A'}
}
function Get-NetworkDoctorRoamingDirectory {$script:knownRoaming}
function Get-NetworkDoctorClientBuild([string]$Path){$script:clientBuild}
function Read-NetworkDoctorClashStartupBytes([string]$Path){$script:startupReadPath=$Path;if($script:startupReadFails){throw 'PRIVATE-startup-read-exception'};return ,([Text.Encoding]::UTF8.GetBytes($script:startupText))}
function Get-DailyProxyContext {$script:context}
function Get-NetworkDoctorFileIdentity([string]$Path){[pscustomobject]@{Status=$(if($script:unknownFile){'Unknown'}else{'Available'});FileId=$Path+':'+$script:fileGeneration;CanonicalPath=$Path}}
function Get-ProcessInventory {if($script:throwInventory){throw 'PRIVATE-fixture-exception'};$script:rows}
function Get-DailyProxyEndpoint([string]$Key){$script:endpointKeys+=@($Key);[pscustomobject]@{Key=$Key;State=$(if($script:endpointStates.ContainsKey($Key)){$script:endpointStates[$Key]}else{$script:endpointState});Identity=$script:identity}}
function Test-DailyProxyEffectiveTarget($Context,[string]$Key){(-not $script:mismatch -and $Context.System.Flags -eq 3)}
function Get-DailyProxyPlan([string]$Key){[pscustomobject]@{CanApply=$true;NoChange=$false}}
function Test-ProxyRoute([string]$Key,[switch]$Fast){Check ($Key -eq 'home_a' -and $Fast) 'Only trusted fixed target and Fast permitted';$script:probes++;if($script:probeRace){$script:identity='changed'};[pscustomobject]@{Usable=$script:probeUsable}}
function Use-ChangeLock([scriptblock]$Action){$script:locks++;$script:locked=$true;try{& $Action}finally{$script:locked=$false}}
function Start-Process {param($FilePath,$WorkingDirectory,$WindowStyle,[switch]$PassThru,$ErrorAction);Check $script:locked 'Launch must hold change lock';Check ($FilePath -eq 'C:\Fixture\clash-verge.exe' -and $WorkingDirectory -eq 'C:\Fixture' -and $WindowStyle -eq 'Hidden') 'Only verified GUI with hidden launch allowed';$script:starts++;if($script:throwStart){throw 'PRIVATE-start-exception'};$null}
function Set-SystemSnapshot {throw 'FORBIDDEN network write'}
function Set-UserProxyEnv {throw 'FORBIDDEN environment write'}
function Set-RoutingSnapshot {throw 'FORBIDDEN program write'}
function Stop-Process {throw 'FORBIDDEN kill'}
function Start-Service {throw 'FORBIDDEN service start'}
function Restart-Service {throw 'FORBIDDEN restart'}
function New-Row([string]$Name,[string]$Path,[int]$Id){[pscustomobject]@{ProcessName=$Name;Path=$Path;Id=$Id;StartTime=[DateTime]::Parse('2026-10-20T00:00:00Z')}}
Reset-Fixture
$original=Get-DailyProxyHash $script:context
$r=Get-NetworkDoctorReport
Check ($r.Kind -eq 'NetworkDoctor' -and $r.State -eq 'ClientStopped' -and $r.CanStartClient -and $r.TargetKey -eq 'home_a') 'Registered custom profile must identify cold stopped Clash'
Check ($script:probes -eq 0 -and $script:starts -eq 0 -and (Get-DailyProxyHash $script:context) -eq $original) 'Passive report must not probe, launch or mutate'
$script:rows=@(New-Row 'clash-verge-service' '' 7)
$r=Get-NetworkDoctorReport
Check ($r.State -eq 'ClientStopped' -and $r.Message -match '服务') 'Service alone is not a core or healthy network'
$script:context.System.Flags=1
$r=Get-NetworkDoctorReport
Check ($r.State -eq 'ClientStopped' -and $r.TargetKey -eq 'home_a') 'Windows direct plus all three stale user variables must detect stopped Clash'
$script:rows+=@(New-Row 'clash-verge' 'C:\Fixture\clash-verge.exe' 8)
$r=Get-NetworkDoctorReport
Check ($r.State -eq 'CoreStopped' -and -not $r.CanStartClient) 'Running GUI without core must instruct opening existing GUI'
Check (-not (Get-NetworkDoctorStartPlan 'home_a').CanApply) 'Already running GUI cannot launch twice'
Reset-Fixture
$script:endpointState='Ready'
$r=Get-NetworkDoctorReport
Check ($r.State -eq 'Healthy' -and -not $r.CanApplyProxy -and -not $r.CanStartClient -and $r.Message -match '尚未') 'Healthy passive state must avoid reapplying or claiming HTTP success'
Check $r.CanProbe 'Unique ready current target should enable explicit probe'
$r=Get-NetworkDoctorReport -Probe
Check ($r.State -eq 'Healthy' -and $r.Probe.Usable -and $script:probes -eq 1 -and $r.Message -notmatch '尚未发送') 'Explicit ready probe permitted and must not retain the passive no-request claim'
$script:probeRace=$true
$r=Get-NetworkDoctorReport -Probe
Check ($r.State -eq 'ProbeFailed' -and -not $r.CanApplyProxy) 'Endpoint change during probe must invalidate success'
$script:probeRace=$false;$script:probeUsable=$false
Check ((Get-NetworkDoctorReport -Probe).State -eq 'ProbeFailed') 'Actual failed probe must remain failed'
$script:probeUsable=$true;$script:mismatch=$true
Check ((Get-NetworkDoctorReport).CanApplyProxy) 'Ready mismatch may offer existing daily plan preview'
Reset-Fixture
foreach($state in @('Unknown','Unsupported')){$script:endpointState=$state;$count=$script:probes;$r=Get-NetworkDoctorReport -Probe;Check ($r.State -eq 'PortUnknown' -and -not $r.CanStartClient -and -not $r.CanApplyProxy -and -not $r.CanProbe -and $script:probes -eq $count) 'Unknown endpoint must not probe, start or apply'}
Reset-Fixture
$script:context.System.Server='[::1]:17897'
Check ((Get-NetworkDoctorReport).State -eq 'PortUnknown') 'IPv6 must not be equated to IPv4 evidence'
Reset-Fixture
$script:context.System.Flags=1;$script:context.Environment.ALL_PROXY=$null
Check ((Get-NetworkDoctorReport).State -eq 'PortUnknown') 'Incomplete stale variables cannot invent a target'
Reset-Fixture
$script:context.System.Server='127.0.0.1:15777';$script:context.Environment.HTTP_PROXY='http://127.0.0.1:15777';$script:context.Environment.HTTPS_PROXY='http://127.0.0.1:15777';$script:context.Environment.ALL_PROXY='http://127.0.0.1:15777'
Check (-not (Get-NetworkDoctorStartPlan 'home_a').CanApply -and -not (Get-NetworkDoctorStartPlan 'work_b').CanApply) 'Active alternate target must not launch Clash'
Reset-Fixture
$script:context.System.Server='127.0.0.1:15777';$script:rows=@((New-Row 'clash-verge' 'C:\Fixture\clash-verge.exe' 8),(New-Row 'verge-mihomo' 'C:\Fixture\verge-mihomo.exe' 9))
$r=Get-NetworkDoctorReport -Probe
Check ($r.State -eq 'SettingsMismatch' -and $r.Message -match '首页明确选择' -and -not $r.CanApplyProxy -and -not $r.CanStartClient -and -not $r.CanProbe) 'Stale stopped alternate system target versus Clash environment must show explicit choice, not blame Clash or switch'
Check (@($r.Checks|Where-Object {$_.Name -eq 'EnvironmentProxy' -and $_.State -eq 'Different'}).Count -eq 1) 'Environment conflict should have its own layered evidence'
$script:context.Client.Topology.IPv6='Unknown'
$r=Get-NetworkDoctorReport
Check ($r.State -eq 'SettingsMismatch' -and $r.Message -match '首页明确选择' -and -not $r.CanApplyProxy -and @($r.Checks|Where-Object {$_.Name -eq 'TopologyIPv6' -and $_.State -eq 'Unknown'}).Count -eq 1) 'Target disagreement remains explicit while unknown IPv6 evidence is retained'
Reset-Fixture
$script:endpointStates=@{home_a='Ready';work_b='Stopped'}
$r=Get-NetworkDoctorReport
Check ($r.State -eq 'Healthy' -and $r.CanProbe -and $script:endpointKeys -notcontains 'work_b') 'Stopped unused alternate candidate must not make healthy current Clash fail'
Reset-Fixture
foreach($flag in @('Tun','Guard')){$script:context.Client.$flag=$true;Check ((Get-NetworkDoctorReport).State -eq 'ClientStopped' -and -not (Get-NetworkDoctorStartPlan 'home_a').CanApply) 'Third-party TUN/Guard must block launch but not hide the missing client/core';$script:context.Client.$flag=$false}
$script:context.System.Flags=7
Check ((Get-NetworkDoctorReport).State -eq 'PortUnknown' -and -not (Get-NetworkDoctorStartPlan 'home_a').CanApply) 'PAC leaves effective target unknown and must block automatic advice'
Reset-Fixture
$script:context.Settings.Routing.Adapter='standalone'
Check ((Get-NetworkDoctorReport).State -eq 'ClientStopped' -and -not (Get-NetworkDoctorStartPlan 'home_a').CanApply) 'Advanced routing must retain dedicated workflow while reporting stopped client'
Reset-Fixture
$script:context.Client.Topology.IPv6='Unknown'
Check ((Get-NetworkDoctorReport).State -eq 'ClientStopped' -and (Get-NetworkDoctorStartPlan 'home_a').CanApply) 'Unknown IPv6 must remain a warning while verified ordinary Clash startup stays available'
$script:endpointState='Ready'
$r=Get-NetworkDoctorReport -Probe
Check ($r.CanProbe -and $r.State -eq 'Healthy' -and $r.Probe.Usable -and -not $r.CanStartClient -and -not $r.CanApplyProxy -and ($r.Steps -join ' ') -match '未知') 'Ready current endpoint may be explicitly tested while IPv6 unknown remains a separate warning'
Reset-Fixture
$script:unknownFile=$true
Check (-not (Get-NetworkDoctorStartPlan 'home_a').CanApply) 'Unverified file identity cannot launch'
Reset-Fixture
$script:rows=@(New-Row 'clash-verge' '' 55)
Check ((Get-NetworkDoctorReport).State -eq 'PortUnknown') 'Inaccessible process path cannot be treated as absent'
Reset-Fixture
$script:throwInventory=$true
$r=Get-NetworkDoctorReport
Check ($r.State -eq 'Unavailable' -and ($r|ConvertTo-Json -Depth 12) -notmatch 'PRIVATE') 'Collection errors must redact raw exception'
Reset-Fixture
$plan=Get-NetworkDoctorStartPlan 'home_a';Reject {Start-NetworkDoctorClient $plan} '明确确认'
$plan.CreatedAt=[DateTimeOffset]::UtcNow.AddSeconds(-121).ToString('o');Reject {Start-NetworkDoctorClient $plan -Confirmed} '过期'
$plan=Get-NetworkDoctorStartPlan 'home_a';$script:context.Environment.NO_PROXY='external';Reject {Start-NetworkDoctorClient $plan -Confirmed} '已变化'
$plan=Get-NetworkDoctorStartPlan 'home_a';$script:fileGeneration++;Reject {Start-NetworkDoctorClient $plan -Confirmed} '已变化'
$plan=Get-NetworkDoctorStartPlan 'home_a';$script:context.Files.config='fixture-v2';Reject {Start-NetworkDoctorClient $plan -Confirmed} '已变化'
$plan=Get-NetworkDoctorStartPlan 'home_a';$script:rows=@(New-Row 'clash-verge' 'C:\Fixture\clash-verge.exe' 91);Reject {Start-NetworkDoctorClient $plan -Confirmed} '不允许'
Reset-Fixture
$plan=Get-NetworkDoctorStartPlan 'home_a';$count=$script:starts;$r=Start-NetworkDoctorClient $plan -Confirmed
Check ($r.Started -and $script:starts -eq $count+1 -and $r.Message -match '尚未确认') 'GUI start must occur once and not claim restored networking'
Reject {Start-NetworkDoctorClient $plan -Confirmed} '已使用'
Check ($script:starts -eq $count+1) 'Same consumed plan cannot start again even before inventory catches GUI'
Remove-Variable NetworkDoctorConsumedPlans -Scope Script -ErrorAction SilentlyContinue
Reject {Start-NetworkDoctorClient ($plan|ConvertTo-Json -Depth 32|ConvertFrom-Json) -Confirmed} '已使用'
Reset-Fixture
$script:throwStart=$true;$plan=Get-NetworkDoctorStartPlan 'home_a'
Reject {Start-NetworkDoctorClient $plan -Confirmed} '启动请求未能完成'
Reject {Start-NetworkDoctorClient $plan -Confirmed} '已使用'
Check (($plan.Message) -match '可能自行接管' -and $script:locks -gt 0) 'Preview must disclose client side effects and use lock'
Reset-Fixture
$duplicate=$script:Profiles.Profiles[0]|ConvertTo-Json|ConvertFrom-Json;$duplicate.Id='ambiguous_same_endpoint';$script:Profiles.Profiles+=@($duplicate)
Check ((Get-NetworkDoctorReport).State -eq 'PortUnknown') 'Duplicate registered endpoint cannot silently select the first profile'
Reset-Fixture
$duplicate=$script:Profiles.Profiles[0]|ConvertTo-Json|ConvertFrom-Json;$duplicate.Id='second_install';$duplicate.Port=17898;$duplicate.CorePath='C:\OtherInstallation\verge-mihomo.exe';$script:Profiles.Profiles+=@($duplicate)
Check (-not (Get-NetworkDoctorStartPlan 'home_a').CanApply) 'Multiple verified installations cannot guess a launch target'
Reset-Fixture
$script:context.Environment.HTTPS_PROXY='http://127.0.0.1:15777'
Check (-not (Get-NetworkDoctorStartPlan 'home_a').CanApply) 'Other effective user proxy target must block Clash launch'
Reset-Fixture
$script:rows=@(New-Row 'verge-mihomo' 'C:\Fixture\verge-mihomo.exe' 93)
Check (-not (Get-NetworkDoctorStartPlan 'home_a').CanApply -and (Get-NetworkDoctorReport).State -eq 'EndpointStopped') 'Existing core without expected endpoint must not restart or start GUI'
Reset-Fixture
$plan=Get-NetworkDoctorStartPlan 'home_a'
function Use-ChangeLock([scriptblock]$Action){$script:context.System.Bypass='external-lock-race';& $Action}
Reject {Start-NetworkDoctorClient $plan -Confirmed} '已变化'
Reset-Fixture
$plan=Get-NetworkDoctorStartPlan 'home_a'
function Use-ChangeLock([scriptblock]$Action){throw 'PRIVATE-lock-exception'}
Reject {Start-NetworkDoctorClient $plan -Confirmed} '启动核验未完成'
function Use-ChangeLock([scriptblock]$Action){$script:locks++;$script:locked=$true;try{& $Action}finally{$script:locked=$false}}
Reset-Fixture
$snapshot=Get-NetworkDoctorClashStartupSnapshot
Check ($snapshot.Status -eq 'Available' -and $snapshot.Tun -eq $false -and $snapshot.Guard -eq $false -and $snapshot.SystemProxy -eq $true -and $snapshot.StartupScriptNull -eq $true -and $snapshot.Hash -match '^[0-9A-F]{64}$') 'Explicit ordinary Clash startup settings are safely summarized and hashed'
foreach($key in @('enable_tun_mode','enable_proxy_guard')){
    Reset-Fixture
    $script:startupText=$script:startupText.Replace(($key+': false'),($key+': true'))
    $plan=Get-NetworkDoctorStartPlan 'home_a';$r=Get-NetworkDoctorReport
    Check (-not $script:context.Client.Tun -and -not $script:context.Client.Guard -and -not $plan.CanApply -and $plan.Message -match '保存的启动配置' -and $r.State -eq 'ClientStopped' -and -not $r.CanStartClient -and $r.Message -match '暂不提供启动') 'Saved TUN or Guard must block GUI-off startup despite interference defaults while preserving fault diagnosis'
}
foreach($scriptValue in @('echo PRIVATE-STARTUP-SCRIPT',"|`n  echo PRIVATE-STARTUP-SCRIPT", "'null'",'null#PRIVATE-STARTUP-SCRIPT')){
    Reset-Fixture
    $script:startupText=$script:startupText.Replace('startup_script: null',('startup_script: '+$scriptValue))
    $snapshot=Get-NetworkDoctorClashStartupSnapshot;$plan=Get-NetworkDoctorStartPlan 'home_a'
    Check (-not $plan.CanApply -and $snapshot.StartupScriptNull -eq $false -and $plan.Message -match '自定义 startup_script' -and ($snapshot|ConvertTo-Json) -notmatch 'PRIVATE') 'Custom scalar, block or quoted-null startup script must be refused without revealing content'
}
Reset-Fixture
$script:startupReadFails=$true
$r=Get-NetworkDoctorReport
Check ($r.State -eq 'ClientStopped' -and -not $r.CanStartClient -and $r.Message -match '读取或格式未知' -and ($r|ConvertTo-Json -Depth 10) -notmatch 'PRIVATE') 'Unreadable startup settings refuse launch but do not hide missing core or leak read errors'
foreach($invalid in @("enable_tun_mode: true`n",'"enable_tun_mode": true',"startup_script: null`n  injected: true",'---')){
    Reset-Fixture
    $script:startupText+=$invalid
    Check ((Get-NetworkDoctorClashStartupSnapshot).Status -eq 'Unknown' -and -not (Get-NetworkDoctorStartPlan 'home_a').CanApply) 'Duplicate, quoted, nested or multidocument startup safety keys must remain unknown'
}
Reset-Fixture
$script:startupText=$script:startupText.Replace('enable_tun_mode: false','enable_tun_mode: TRUE')
Check ((Get-NetworkDoctorClashStartupSnapshot).Status -eq 'Unknown') 'Noncanonical boolean must not turn an enabled YAML boolean into false'
Reset-Fixture
$script:startupText=$script:startupText.Replace('enable_tun_mode: false','enable_tun_mode: false#not-a-yaml-comment')
Check ((Get-NetworkDoctorClashStartupSnapshot).Status -eq 'Unknown') 'A hash without separating whitespace is a scalar, not a YAML comment'
Reset-Fixture
$script:startupText=$script:startupText.Replace('enable_tun_mode: false','enable_tun_mode:false')
Check ((Get-NetworkDoctorClashStartupSnapshot).Status -eq 'Unknown') 'Missing map separator whitespace must not manufacture a false safety field'
Reset-Fixture
$plan=Get-NetworkDoctorStartPlan 'home_a';$script:startupText+="# externally updated startup configuration`n"
Reject {Start-NetworkDoctorClient $plan -Confirmed} '已变化'
Reset-Fixture
$script:context.Client.Topology.State='Unknown';$script:context.Client.Topology.IPv4='Unknown';$script:context.Client.Topology.IPv6='Unknown'
$r=Get-NetworkDoctorReport;$plan=Get-NetworkDoctorStartPlan 'home_a'
Check ($r.State -eq 'ClientStopped' -and $r.CanStartClient -and $plan.CanApply -and $plan.Message -match '其他 VPN 或双栈路由状态仍可能未知' -and ($r.Steps -join ' ') -match '双栈路由证据仍有未知') 'Unknown host topology allows explicit verified ordinary Clash recovery with a visible warning'
$script:rows=@(New-Row 'clash-verge' 'C:\Fixture\clash-verge.exe' 9)
$r=Get-NetworkDoctorReport
Check ($r.State -eq 'CoreStopped' -and -not $r.CanStartClient -and @($r.Checks|Where-Object {$_.Name -eq 'TopologyIPv6' -and $_.State -eq 'Unknown'}).Count -eq 1) 'Unknown host topology does not hide a stopped core behind a running GUI'
Reset-Fixture
$priorAppData=$env:APPDATA
$knownFolderBefore=& $script:realDoctorRoamingDirectory
try{
    $env:APPDATA='C:\FixtureUntrustedInheritedAppData'
    $knownFolderAfter=& $script:realDoctorRoamingDirectory
    $snapshot=Get-NetworkDoctorSnapshot
    $expectedPath=Join-Path $script:knownRoaming 'io.github.clash-verge-rev.clash-verge-rev\verge.yaml'
    Check ($knownFolderBefore -ceq $knownFolderAfter -and $snapshot.ClashStartup.Path -ceq $expectedPath -and $script:startupReadPath -ceq $expectedPath -and $snapshot.ClashStartup.Path -notlike ($env:APPDATA+'*')) 'Inherited APPDATA override must not replace the Windows Known Folder or bound stable configuration path'
}finally{$env:APPDATA=$priorAppData}
foreach($unsupported in @(@{Field='ProductName';Value='Clash Verge dev'},@{Field='CompanyName';Value='Custom Build'},@{Field='FileVersion';Value='2.5.8-dev'},@{Field='ProductVersion';Value='2.5.9'},@{Field='SHA256';Value=('0'*64)})){
    Reset-Fixture
    $script:clientBuild.($unsupported.Field)=$unsupported.Value
    $snapshot=Get-NetworkDoctorSnapshot;$r=Get-NetworkDoctorReport;$plan=Get-NetworkDoctorStartPlan 'home_a'
    Check ($snapshot.Runtime.Candidate -and -not $snapshot.Runtime.BuildSupported -and -not $snapshot.Runtime.Unknown -and $r.State -eq 'ClientStopped' -and -not $r.CanStartClient -and -not $plan.CanApply -and $plan.Message -match '稳定版 2.5.8' -and $snapshot.ClashStartup.Status -eq 'Unknown' -and -not $script:startupReadPath) 'Unverified or development builds retain diagnostic identity but refuse startup and do not guess configuration roots'
}
Reset-Fixture
$script:clientBuild.ProductName='Clash Verge dev';$script:rows=@(New-Row 'clash-verge' 'C:\Fixture\clash-verge.exe' 11)
Check ((Get-NetworkDoctorReport).State -eq 'CoreStopped') 'Unsupported build must not make an identified running GUI with missing core ambiguous'
Reset-Fixture
$plan=Get-NetworkDoctorStartPlan 'home_a';$script:knownRoaming='C:\ChangedKnownRoaming'
Reject {Start-NetworkDoctorClient $plan -Confirmed} '已变化'
Reset-Fixture
$plan=Get-NetworkDoctorStartPlan 'home_a';$script:clientBuild.ProductVersion='2.5.9'
Reject {Start-NetworkDoctorClient $plan -Confirmed} '不允许'
Reset-Fixture
$script:endpointState='Ready';$r=Get-NetworkDoctorReport
Check ($r.Headline -eq '当前代理入口已就绪' -and @($r.Checks|Where-Object {$_.Name -eq 'ClashStartupConfiguration' -and $_.Detail -eq '核对客户端启动时的接管开关和启动脚本；启动前会再次检查。'}).Count -eq 1) 'User-facing report wording should describe readiness and startup checks without implementation details'
Reset-Fixture
$plan=Get-NetworkDoctorStartPlan 'home_a';$script:clientBuild.SHA256='0'*64
Reject {Start-NetworkDoctorClient $plan -Confirmed} '不允许'
# Exercise the real bounded hashing code using only an owned temporary byte fixture.
# Metadata and process/file identity stay isolated; this is not an executable client.
function Get-NetworkDoctorClientVersionMetadata([string]$Path){
    $script:metadataReads++
    if($script:metadataFileRace -and $script:metadataReads -eq 2){$script:fileGeneration++}
    [pscustomobject]@{Status='Available';ProductName='Clash Verge';CompanyName='Clash Verge Rev';FileVersion='2.5.8';ProductVersion=$(if($script:metadataVersionRace -and $script:metadataReads -eq 2){'2.5.9'}else{'2.5.8'})}
}
$hashFixture=Join-Path ([IO.Path]::GetTempPath()) ('FlowSwitch-DoctorHash-'+[Guid]::NewGuid().ToString('N')+'.fixture')
try{
    Reset-Fixture;$script:metadataReads=0;$script:metadataFileRace=$false;$script:metadataVersionRace=$false
    [IO.File]::WriteAllBytes($hashFixture,[byte[]]@(1,2,3,4))
    $firstBuild=& $script:realDoctorClientBuild $hashFixture
    [IO.File]::WriteAllBytes($hashFixture,[byte[]]@(1,2,3,5))
    $secondBuild=& $script:realDoctorClientBuild $hashFixture
    Check ($firstBuild.Status -eq 'Available' -and $secondBuild.Status -eq 'Available' -and $firstBuild.SHA256 -cne $secondBuild.SHA256 -and $firstBuild.ProductVersion -ceq $secondBuild.ProductVersion) 'Real digest must change when GUI bytes change while version metadata stays identical'
    $script:clientBuild=$secondBuild
    Check (-not (Get-NetworkDoctorStartPlan 'home_a').CanApply) 'Unlisted digest must refuse startup even with the exact four stable version metadata fields'
    $script:metadataReads=0;$script:metadataFileRace=$true
    Check ((& $script:realDoctorClientBuild $hashFixture).Status -eq 'Unknown') 'File identity change during digest collection must invalidate the build observation'
    $script:metadataReads=0;$script:metadataFileRace=$false;$script:metadataVersionRace=$true
    Check ((& $script:realDoctorClientBuild $hashFixture).Status -eq 'Unknown') 'Metadata change during digest collection must invalidate the build observation'
    $script:metadataReads=0;$script:metadataVersionRace=$false
    $stream=[IO.File]::Open($hashFixture,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.SetLength(64MB+1)}finally{$stream.Dispose()}
    Check ((& $script:realDoctorClientBuild $hashFixture).Status -eq 'Unknown') 'Files over 64 MiB must be rejected before digest input is read'
}finally{if([IO.File]::Exists($hashFixture)){[IO.File]::Delete($hashFixture)}}
$source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'NetworkDoctor.ps1') -Raw -Encoding UTF8
Check ($source -notmatch '(?im)^\s*(Set-SystemSnapshot|Set-UserProxyEnv|Set-RoutingSnapshot|Stop-Process|Start-Service|Restart-Service|Set-Content|Write-LocalJson)\b') 'Source must contain no network writes, kill, service control or private persistence'
Write-Host ('NetworkDoctor passed: '+$script:checks+' assertions; isolated fixture only, no real settings/client/network writes.')

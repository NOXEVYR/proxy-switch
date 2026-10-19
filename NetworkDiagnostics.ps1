# Read-only diagnosis; all repairs require an explicit action and a fresh revision.
function Get-WindowsApplicationProxyViews {
    if(-not ('LocalProxySwitch.ApplicationProxyViews' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace LocalProxySwitch {
    public sealed class ApplicationProxyView {
        public bool Available;
        public string Server = "";
        public bool AutoDetect;
        public bool HasPac;
    }
    public static class ApplicationProxyViews {
        [StructLayout(LayoutKind.Sequential)] struct IeConfig {
            [MarshalAs(UnmanagedType.Bool)] public bool AutoDetect;
            public IntPtr Pac, Proxy, Bypass;
        }
        [DllImport("winhttp.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)] static extern bool WinHttpGetIEProxyConfigForCurrentUser(out IeConfig config);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr memory);
        public static ApplicationProxyView Read() {
            var result = new ApplicationProxyView(); var config = new IeConfig();
            try {
                if(!WinHttpGetIEProxyConfigForCurrentUser(out config)) return result;
                result.Available = true; result.AutoDetect = config.AutoDetect;
                result.HasPac = config.Pac != IntPtr.Zero;
                if(config.Proxy != IntPtr.Zero) result.Server = Marshal.PtrToStringUni(config.Proxy) ?? "";
                return result;
            } finally {
                if(config.Pac != IntPtr.Zero) GlobalFree(config.Pac);
                if(config.Proxy != IntPtr.Zero) GlobalFree(config.Proxy);
                if(config.Bypass != IntPtr.Zero) GlobalFree(config.Bypass);
            }
        }
    }
}
'@
    }
    $top=[pscustomobject]@{Available=$false;Enabled=$false;Server=''};$key=$null
    try{
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings',$false)
        if($key){$top.Available=$true;$top.Enabled=([int]$key.GetValue('ProxyEnable',0) -ne 0);$top.Server=[string]$key.GetValue('ProxyServer','')}
    }catch{}finally{if($key){$key.Dispose()}}
    $ie=[pscustomobject]@{Available=$false;Server='';AutoDetect=$false;HasPac=$false}
    try{$ie=[LocalProxySwitch.ApplicationProxyViews]::Read()}catch{}
    [pscustomobject]@{Registry=$top;WinHttpIE=$ie}
}
function ConvertTo-ApplicationProxyViewSummary($System,$Views) {
    $enabled=[bool]($System.Flags -band 2);$different=$false
    $states=@{WinINET=$(if($enabled){'开启'}else{'关闭'});Registry='未知';WinHttpIE='未知'}
    if($Views.Registry.Available){
        $states.Registry=if($Views.Registry.Enabled){'开启'}else{'关闭'}
        if($Views.Registry.Enabled -ne $enabled -or ($enabled -and [string]$Views.Registry.Server -cne [string]$System.Server)){$different=$true}
    }
    if($Views.WinHttpIE.Available){
        $ieEnabled=-not [string]::IsNullOrEmpty([string]$Views.WinHttpIE.Server)
        $states.WinHttpIE=if($ieEnabled){'开启'}else{'关闭'}
        if($ieEnabled -ne $enabled -or ($enabled -and [string]$Views.WinHttpIE.Server -cne [string]$System.Server)){$different=$true}
    }
    [pscustomobject]@{WinINET=$states.WinINET;Registry=$states.Registry;WinHttpIE=$states.WinHttpIE;Different=$different;Message=('Windows 手动代理视图：WinINET '+$states.WinINET+'；注册表顶层 '+$states.Registry+'；WinHTTP IE 当前用户接口 '+$states.WinHttpIE+'。'+$(if($different){'不同 API 或注册表字段不一致，应用可能读取不同视图而直连；这只是差异证据，尚不能推断根因。'}else{'这些读取结果不代表所有应用都会采用系统代理。'})+' 请在原代理客户端核对系统代理，再回目标应用检查；流向本次只读，不改第三方设置。')}
}
function Get-RecoveryOwnerState($Session) {
    if(-not $Session.OwnerPID -or -not $Session.OwnerStart){return 'unknown'}
    $process=$null
    try{
        $process=[Diagnostics.Process]::GetProcessById([int]$Session.OwnerPID)
        if($process.StartTime.ToUniversalTime().Ticks.ToString() -ceq [string]$Session.OwnerStart){return 'alive'}
        return 'stopped'
    }catch [ArgumentException]{return 'stopped'}
    catch{return 'unknown'}
    finally{if($process){$process.Dispose()}}
}
function Get-IndependentStoppedServiceState($Session) {
    $states=@(Get-RecoveryOwnerState ([pscustomobject]@{OwnerPID=$Session.SupervisorPID;OwnerStart=$Session.SupervisorStart}))
    $states+=Get-RecoveryOwnerState ([pscustomobject]@{OwnerPID=$Session.CorePID;OwnerStart=$Session.CoreStart})
    $trackedPath=Join-Path $script:DataRoot 'gateway\process.json'
    try{
        $tracked=Get-Content -LiteralPath $trackedPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        if($tracked.supervisor -ne $Session.SupervisorPID -or [string]$tracked.supervisorStartTicks -cne [string]$Session.SupervisorStart){return 'unknown'}
        $states+=Get-RecoveryOwnerState ([pscustomobject]@{OwnerPID=$tracked.core;OwnerStart=$tracked.coreStartTicks})
    }catch{return 'unknown'}
    if($states -contains 'alive'){return 'alive'}
    if($states -contains 'unknown'){return 'unknown'}
    'stopped'
}
function Get-NetworkRepairRevision($System,$Environment) {
    $parts=@(($System|ConvertTo-Json -Compress),($Environment|ConvertTo-Json -Compress))
    foreach($path in @((Get-IndependentSessionPath),$script:ConfigPath,(Join-Path $script:DataRoot 'app-rules.json'),(Join-Path $script:DataRoot 'program-proxies.json'),(Join-Path $script:DataRoot 'selection.json'))){
        $parts+= $(if(Test-Path -LiteralPath $path){[IO.File]::ReadAllText($path)}else{'<missing>'})
    }
    $hash=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts|ConvertTo-Json -Compress))))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Test-NetworkTargets($Profile) {
    $probes=@();$results=@();$finished=@{};$clock=[Diagnostics.Stopwatch]::StartNew()
    try{
        foreach($target in @(@('GitHub','https://github.com/'),@('OpenAI API','https://api.openai.com/'))){
            try{$probes+=[pscustomobject]@{Name=$target[0];Probe=(Start-HttpEndpointProbe $Profile $target[1] $true)}}
            catch{$results+=[pscustomobject]@{Name=$target[0];Stage='probe-unavailable';HttpCode=0;ConnectCode=0;CurlExitCode=$null;Seconds=$null;AuthenticationVerified=$false}}
        }
        # Both children share one absolute budget, including process creation.
        # Waiting independently per child can double the caller's deadline.
        do{
            foreach($item in $probes){
                if(-not $finished.ContainsKey($item.Name) -and $item.Probe.Process.HasExited){
                    $results+=Read-NetworkTargetProbe $Profile $item.Name $item.Probe
                    $finished[$item.Name]=$true
                }
            }
            if($finished.Count -eq $probes.Count){break}
            $remaining=12000-[int]$clock.ElapsedMilliseconds
            if($remaining -gt 0){Start-Sleep -Milliseconds ([Math]::Min(30,$remaining))}
        }while($clock.ElapsedMilliseconds -lt 12000)
        foreach($item in $probes){if(-not $finished.ContainsKey($item.Name)){
            if($item.Probe.Process.HasExited){$results+=Read-NetworkTargetProbe $Profile $item.Name $item.Probe}
            else{$results+=[pscustomobject]@{Name=$item.Name;Stage='probe-timeout';HttpCode=0;ConnectCode=0;CurlExitCode=$null;Seconds=$clock.Elapsed.TotalSeconds;AuthenticationVerified=$false}}
        }}
    }finally{foreach($item in $probes){Close-HttpEndpointProbe $item.Probe}}
    @($results)
}
function Read-NetworkTargetProbe($Profile,[string]$Name,$Probe) {
    $parts=$Probe.Output.Result.Trim() -split '\s+';$code=0;$connect=0;$seconds=0.0
    if($parts.Count -ge 3){
        [void][int]::TryParse($parts[0],[ref]$code);[void][int]::TryParse($parts[2],[ref]$connect)
        [void][double]::TryParse($parts[1],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$seconds)
    }
    $exit=[int]$Probe.Process.ExitCode;$stage='proxy-or-target-unreachable'
    $handshake=($Profile.Protocol -eq 'http' -and $connect -eq 200) -or ($Profile.Protocol -eq 'socks5' -and $code -gt 0)
    if($handshake -and $exit -eq 0 -and $code -ge 100){$stage='https-response'}
    elseif($connect -ge 300){$stage='proxy-rejected'}
    elseif($exit -eq 28){$stage='probe-timeout'}
    elseif($exit -in @(35,51,53,54,58,59,60,64,66,77,80,82,83,90,91)){$stage='target-tls-failed'}
    elseif($connect -eq 200){$stage='target-tls-or-timeout'}
    [pscustomobject]@{Name=$Name;Stage=$stage;Protocol=$Profile.Protocol;HttpCode=$code;ConnectCode=$connect;CurlExitCode=$exit;Seconds=$seconds;TimeoutPhase=$(if($exit -eq 28){if($Profile.Protocol -ne 'http'){'Unknown'}elseif($connect -eq 200){'AfterConnect'}else{'BeforeConnect'}}else{''});AuthenticationVerified=$false}
}
function ConvertTo-NetworkTopologySummary($Topology) {
    $values=@{};foreach($name in @('State','IPv4','IPv6')){
        $value=[string](Get-ProgramIdentityValue $Topology $name '')
        $values[$name]=$(if($value -in @('Evidence','NoEvidence','Unknown')){$value}else{'Unknown'})
    }
    $observed='';$date=[DateTimeOffset]::MinValue
    if([DateTimeOffset]::TryParse([string](Get-ProgramIdentityValue $Topology 'ObservedAt' ''),[ref]$date)){$observed=$date.ToUniversalTime().ToString('o')}
    [pscustomobject]@{State=$values.State;IPv4=$values.IPv4;IPv6=$values.IPv6;Available=((Get-ProgramIdentityValue $Topology 'Available' $false) -eq $true);Coverage='活动网卡与默认或成对拆分默认路由；不证明特定请求、全部流量或实际出口。未见证据不等于隧道已关闭。';ObservedAt=$observed}
}
# Only simple loopback endpoints are eligible; PAC, remote and per-protocol lists stay unknown.
function Get-LocalEndpointObservation([string]$Value,$Tcp,$ExpectedProfile=$null) {
    if($Value -notmatch '^(?:(?:http|https|socks5|socks5h)://)?(127\.0\.0\.1|localhost|\[::1\]):([0-9]{1,5})/?$'){return $null}
    $port=[int]$Matches[2];if($port -lt 1 -or $port -gt 65535){return $null}
    $profile=[pscustomobject]@{Host=$Matches[1].Trim('[',']');Port=$port;CorePath=''}
    $ready=$null;$listening=$null
    if($Tcp.Available){
        $listeners=@($Tcp.Rows|Where-Object {$_.State -eq 'Listen' -and $_.LocalPort -eq $port -and $_.LocalAddress -in @('127.0.0.1','0.0.0.0','::','::1')})
        $matching=$listeners;$ambiguous=$false
        if($profile.Host -eq '127.0.0.1'){
            $matching=@($listeners|Where-Object {$_.LocalAddress -in @('127.0.0.1','0.0.0.0')})
            $ambiguous=(-not $matching.Count -and @($listeners|Where-Object LocalAddress -eq '::').Count -gt 0)
        }elseif($profile.Host -eq '::1'){$matching=@($listeners|Where-Object {$_.LocalAddress -in @('::1','::')})}
        if(-not $matching.Count -and -not $ambiguous){$ready=$false;$listening=$false}
        elseif($matching.Count){
            $listening=$true
            # A listener with unreadable/exited ownership is not proof of a dead entry.
            $identityProfile=$profile;if($ExpectedProfile){$identityProfile=$ExpectedProfile}
            try{if(Get-Listener $identityProfile -TcpRows $matching){$ready=$true}}catch{}
        }
    }
    [pscustomobject]@{Port=$port;Ready=$ready;Listening=$listening;OwnerVerified=($ready -eq $true)}
}
function Test-BroadProxyBypass([string]$Value) {
    # Go recognizes a comma-delimited '*' as all destinations. Other clients,
    # including some curl builds, differ; never silently rewrite the user's list.
    $items=@($Value -split ','|ForEach-Object {$_.Trim()}|Where-Object {$_})
    return (@($items|Where-Object {$_ -in @('*','0.0.0.0/0','::/0')}).Count -gt 0)
}
function Get-BroadProxyBypassWarning {
    'NO_PROXY 含全局或整个地址族的绕过项。Go 会把逗号列表中的独立 * 视为全部绕过，部分 curl 版本解析不同；代理地址一致不代表实际走同一路线。请在原环境设置中核对绕过项，或使用流向的程序启动入口；不会自动删除你的绕过设置。'
}
function Assert-NetworkRepairCurrent([string]$Revision) {
    if($Revision -cne (Get-NetworkRepairRevision (Get-SystemSnapshot) (Get-UserProxyEnv))){throw '检测期间配置已变化，请重新排查；未采用旧修复方案。'}
    $client=Get-ClientInterference
    if($client.Tun -or $client.Guard){throw '其他客户端的 TUN 或代理守护仍在接管网络。请先关闭该开关并保留代理服务，再修复。'}
}
function Repair-DeadSystemEntry([string]$Revision) {
    Assert-NetworkRepairCurrent $Revision
    $before=Get-SystemSnapshot;$beforeEnv=Get-UserProxyEnv;$tcp=Get-TcpObservationSnapshot
    $entry=Get-LocalEndpointObservation $before.Server $tcp
    if(-not ($before.Flags -band 2) -or -not $entry -or $entry.Ready -ne $false -or (Test-Path (Get-IndependentSessionPath))){throw '失效入口或会话状态已经改变，请重新排查。'}
    # Respect the configured backup order, then remaining configured upstreams. No port scanning.
    $keys=@(@($script:Profiles.Routing.Failover.Order)+@($script:Profiles.Profiles|ForEach-Object Id)|Select-Object -Unique)
    foreach($key in $keys){
        if($key -notin (Get-ProfileKeys) -or ($script:Profiles.Routing.Adapter -eq 'standalone' -and $key -eq (Get-GatewayKey))){continue}
        $profile=Get-Profile $key
        $local=Get-LocalEndpointObservation (Get-EndpointAddress $profile) $tcp
        if($local -and $local.Ready -ne $true){continue}
        Write-OperationProgress ('正在检测备用线路「'+$profile.Name+'」…')
        $usable=(Test-ProxyRoute $key -Fast).Usable
        Assert-NetworkRepairCurrent $Revision
        if($usable){
            if($script:Profiles.Routing.Adapter -eq 'none'){
                $daily=Get-DailyProxyPlan -Key $key
                $repairRevision=$Revision
                $recheck={Assert-NetworkRepairCurrent $repairRevision}.GetNewClosure()
                return Set-DailyProxy -Plan $daily -Confirmed -PreApplyValidation $recheck
            }
            return Enable-IndependentGateway -OwnerPID $PID -InitialRoute $key -RepairEntry -RepairRevision $Revision
        }
    }
    Assert-NetworkRepairCurrent $Revision
    $fresh=Get-TcpObservationSnapshot;$current=Get-LocalEndpointObservation $before.Server $fresh
    if(-not $fresh.Available -or -not $current -or $current.Ready -ne $false){throw '入口已恢复或监听状态未知，未清除设置。请重新排查。'}
    $targetEnv=[ordered]@{};$clear=@()
    foreach($name in $script:ProxyNames){
        $targetEnv[$name]=$beforeEnv.$name
        if($name -ne 'NO_PROXY'){$observed=Get-LocalEndpointObservation ([string]$beforeEnv.$name) $fresh;if($observed -and $observed.Ready -eq $false){$targetEnv[$name]=$null;$clear+=$name}}
    }
    # Preserve PAC/autodetect flags and bypass; disable only the proven dead manual proxy.
    $target=[pscustomobject]@{Flags=(($before.Flags -band (-bnot 2)) -bor 1);Server='';Bypass=$before.Bypass}
    $verify={
        Assert-NetworkRepairCurrent $Revision
        $currentTcp=Get-TcpObservationSnapshot;$seen=Get-LocalEndpointObservation $before.Server $currentTcp
        if(-not $seen -or $seen.Ready -ne $false){throw '入口状态已变化，未执行清理。'}
        foreach($name in $clear){$local=Get-LocalEndpointObservation ([string]$beforeEnv.$name) $currentTcp;if(-not $local -or $local.Ready -ne $false){throw '代理变量的入口已恢复或状态未知，未执行清理。'}}
        Assert-NetworkRepairCurrent $Revision
    }.GetNewClosure()
    $backup=Invoke-ProxyTransaction $target ([pscustomobject]$targetEnv) (Get-Selection) $before $beforeEnv -VerifyAction $verify -PreserveSelection
    [pscustomobject]@{Message='未检测到可用备用代理。已备份并撤销失效的手动系统代理，清除确认失效的本地代理变量；保留其他变量、自动配置及程序规则。直连或现有自动配置是否能访问目标网站仍需验证，需要代理的网站仍需可用上游。';Backup=$backup}
}
function Repair-DeadProxyEnvironment([string]$Revision) {
    Assert-NetworkRepairCurrent $Revision
    $before=Get-SystemSnapshot;$beforeEnv=Get-UserProxyEnv
    if((Get-SystemKey $before) -ne 'Direct' -or (Test-Path -LiteralPath (Get-IndependentSessionPath))){throw '系统入口或托管会话已变化，请重新排查。'}
    $tcp=Get-TcpObservationSnapshot;$clear=@();$target=[ordered]@{}
    foreach($name in $script:ProxyNames){
        $target[$name]=$beforeEnv.$name
        if($name -ne 'NO_PROXY'){
            $observed=Get-LocalEndpointObservation ([string]$beforeEnv.$name) $tcp
            if($observed -and $observed.Ready -eq $false){$target[$name]=$null;$clear+=$name}
        }
    }
    if(-not $clear.Count){throw '未发现确认失效的本地代理变量；有效、未知和非本地变量均保留。'}
    $verify={
        Assert-NetworkRepairCurrent $Revision
        if((Test-Path -LiteralPath (Get-IndependentSessionPath)) -or (Get-SystemKey (Get-SystemSnapshot)) -ne 'Direct'){throw '系统入口或托管会话已变化，未清理变量。'}
        $fresh=Get-TcpObservationSnapshot
        foreach($name in $clear){$seen=Get-LocalEndpointObservation ([string]$beforeEnv.$name) $fresh;if(-not $seen -or $seen.Ready -ne $false){throw '本地入口已恢复或监听状态未知，未清理变量。'}}
        Assert-NetworkRepairCurrent $Revision
    }.GetNewClosure()
    $backup=Invoke-ProxyTransaction $before ([pscustomobject]$target) (Get-Selection) $before $beforeEnv -VerifyAction $verify -EnvironmentOnly -PreserveSelection
    [pscustomobject]@{Message='已备份并清理确认未监听的本地代理变量。保留系统代理、有效或未知变量、NO_PROXY、程序与网站规则及线路选择。普通应用可能仍保留旧环境，请保存工作后正常重开；清理不代表目标网站或账号已经可用。';Backup=$backup}
}
function Get-NetworkDiagnosis([switch]$Probe) {
    $script:Profiles=Read-ProfileSettings
    $system=Get-SystemSnapshot;$environment=Get-UserProxyEnv
    $revision=Get-NetworkRepairRevision $system $environment
    $tcp=Get-TcpObservationSnapshot
    $issues=@();$endpoints=@();$action='';$repairText='';$sessionId='';$owner='none'
    foreach($profile in $script:Profiles.Profiles){
        $ready=$null
        $observed=Get-LocalEndpointObservation (Get-EndpointAddress $profile) $tcp $profile
        if($observed){$ready=$observed.Ready}
        $endpoints+=[pscustomobject]@{Key=$profile.Id;Port=$profile.Port;Ready=$ready;Listening=$(if($observed){$observed.Listening}else{$null});OwnerVerified=($ready -eq $true)}
    }
    $systemKey=Get-SystemKey $system
    $systemReady=$null;$entry=$endpoints|Where-Object Key -eq $systemKey|Select-Object -First 1
    if($entry){$systemReady=$entry.Ready}
    $manual=$null
    if($system.Flags -band 2){
        $expectedProfile=$null;if($systemKey -in (Get-ProfileKeys)){$expectedProfile=Get-Profile $systemKey}
        $manual=Get-LocalEndpointObservation $system.Server $tcp $expectedProfile;if($manual){$systemReady=$manual.Ready}
    }
    $client=Get-ClientInterference
    if($client.Guard -or $client.Tun){$issues+=[pscustomobject]@{Code='external-proxy-control';Message='检测到其他客户端的代理守护或隧道路由，会阻止流向统一接管。支持的程序可用独立启动入口共存；“直连”不保证绕过外部 VPN/TUN。流向不会修改其他客户端开关或循环抢回入口。'}}
    $topology=Get-ProgramIdentityValue $client 'Topology' $null
    if($topology -and $topology.State -eq 'Unknown'){$issues+=[pscustomobject]@{Code='topology-unknown';Message='网卡或系统路由证据读取不完整，外部隧道状态未知；未发现证据不能等同 TUN 已关闭。'}}
    if(-not $tcp.Available){$issues+=[pscustomobject]@{Code='observation-unknown';Message='无法读取连接列表，监听状态未知。稍后重新排查；不会据此清空代理。'}}
    if($systemReady -eq $false){$issues+=[pscustomobject]@{Code='system-entry-down';Message='系统代理指向未监听的入口。请在代理管理启动对应代理，或检测并选择其他可用线路。'}}
    if($systemKey -eq 'Direct'){$issues+=[pscustomobject]@{Code='system-direct';Message=$(if($topology -and $topology.HasTunnelRouteEvidence){'系统应用代理已关闭，但存在外部隧道路由证据，不代表物理直连。请同时核对 VPN 线路及目标程序是否接入流向。'}elseif($client.Tun){'系统应用代理已关闭，已知客户端的 TUN 配置开启；实际隧道路由仍需核验，不能据此确认物理直连。'}else{'系统应用代理已关闭。若目标网站需要代理，请选择并检测可用线路；此状态不证明没有 VPN 或其他隧道。'})}}
    if($systemKey -eq 'Other'){$issues+=[pscustomobject]@{Code='system-unmanaged';Message='系统代理不在已配置列表中，无法验证其归属。请在代理管理核对并添加入口。'}}
    $mismatched=@();$dead=@();$unknownEnvironment=@();$environmentEndpoints=@()
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){
        $key=Get-EndpointKey $environment.$name
        if(($systemKey -ne 'Direct' -and $key -ne $systemKey) -or ($systemKey -eq 'Direct' -and $key -ne 'Unset')){$mismatched+=$name}
        $expectedProfile=$null;if($key -in (Get-ProfileKeys)){$expectedProfile=Get-Profile $key}
        $observed=Get-LocalEndpointObservation ([string]$environment.$name) $tcp $expectedProfile
        if($observed){
            $environmentEndpoints+=[pscustomobject]@{Name=$name;Port=$observed.Port;Ready=$observed.Ready}
            if($observed.Ready -eq $false){$dead+=$name}
            elseif($null -eq $observed.Ready){$unknownEnvironment+=$name}
            if($key -eq 'Other'){$endpoints+=[pscustomobject]@{Key=('environment:'+ $name);Port=$observed.Port;Ready=$observed.Ready}}
        }
    }
    if($dead.Count){$issues+=[pscustomobject]@{Code='environment-entry-down';Message=(($dead -join '、')+' 指向未监听的入口，终端工具可能连接失败。')}}
    if($unknownEnvironment.Count){$issues+=[pscustomobject]@{Code='environment-entry-unknown';Message=(($unknownEnvironment -join '、')+' 的本地入口监听或归属无法核验，状态未知；不会据此清除变量。')}}
    if(($system.Flags -band 2) -and $null -eq $systemReady){$issues+=[pscustomobject]@{Code='system-entry-unknown';Message='系统入口监听或归属无法核验，状态未知；不能把它报告为未监听或正常可用。'}}
    if(Test-BroadProxyBypass $environment.NO_PROXY){$issues+=[pscustomobject]@{Code='environment-bypass-all';Message=(Get-BroadProxyBypassWarning)}}
    if($mismatched.Count){$issues+=[pscustomobject]@{Code='environment-mismatch';Message=$(if(@(@('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')|Where-Object {(Get-EndpointKey $environment.$_) -ne 'Unset'}).Count -eq 0){'用户级代理变量未设置，终端工具是否采用系统代理取决于自身；这不等同于 ChatGPT 故障，也不要求补全局代理变量。'}else{'系统代理与用户代理变量不一致，不同软件可能走不同入口。'})}}
    $sessionPath=Get-IndependentSessionPath
    if(Test-Path -LiteralPath $sessionPath){
        try{
            $session=Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8|ConvertFrom-Json
            $owner=Get-RecoveryOwnerState $session;$sessionId=[string]$session.Started
            if($owner -eq 'alive' -and $session.PreserveWindowsSettings -ne $true -and $session.TargetSystem -and -not (Test-SameSnapshot $system $session.TargetSystem)){$issues+=[pscustomobject]@{Code='system-entry-overridden';Message='系统入口已偏离流向托管入口；使用系统代理的新请求可能绕过流向。无法仅凭端口确认修改者。请处理外部守护，再明确重新应用线路。'}}
            if($owner -eq 'stopped' -and $sessionId){
                $issues+=[pscustomobject]@{Code='abandoned-session';Message='发现上次运行遗留的会话，原宿主已退出。旧保护记录不代表当前网关可用。'}
                $action='recover-session';$repairText='恢复仍属于旧会话的系统代理与用户变量，核验后停止旧会话内核并归档。保留其他工具或你后来改过的设置。'
            }elseif($owner -eq 'unknown'){$issues+=[pscustomobject]@{Code='session-unknown';Message='会话身份无法核实。保留记录，暂不停止进程或自动恢复。'}}
            elseif($owner -eq 'alive'){
                $gateway=$endpoints|Where-Object Key -eq (Get-GatewayKey)|Select-Object -First 1
                $service=Get-IndependentStoppedServiceState $session
                if($sessionId -and $service -eq 'stopped'){
                    $issues+=[pscustomobject]@{Code='stopped-service-session';Message='流向界面仍在，但该会话的监督器及已记录内核均已停止。旧就绪记录不能证明入口可用。'}
                    $action='recover-stopped-service';$repairText='恢复仍属于此会话的代理设置并归档残留记录；保留其他工具后来设置的入口。不结束应用，已有应用可能需要正常重开。'
                }
                elseif($gateway -and $gateway.Ready -eq $false){$issues+=[pscustomobject]@{Code='gateway-down';Message='流向宿主仍在运行，但固定入口未监听。等待恢复；若持续失败，请停止服务后重新启用独立分流。'}}
                elseif($gateway -and $gateway.Ready -eq $true){
                    try{
                        $live=Invoke-AppRouter @{action='status'} -TimeoutMilliseconds 2500
                        if(-not $live.available -or -not $live.defaultLoaded){$issues+=[pscustomobject]@{Code='gateway-control-unready';Message='入口在监听，但控制接口或默认规则未就绪。请检查内核状态。'}}
                        elseif($live.effectiveDefaultRoute -in @('Blocked','Unknown',$null,'')){$issues+=[pscustomobject]@{Code='upstream-unavailable';Message='固定入口存在，但出口被暂停或未知。请检测上游代理并选择可用线路。'}}
                    }catch{$issues+=[pscustomobject]@{Code='gateway-control-unknown';Message='无法核验网关实际出口。端口监听不代表转发可用。'}}
                }
            }
        }catch{$owner='unknown';$issues+=[pscustomobject]@{Code='session-unreadable';Message='旧会话记录无法读取。请保留文件和备份，不会重置配置。'}}
    }
    # Environment-only alignment is offered only when no managed session owns it.
    if(-not $action -and $owner -eq 'none' -and -not ($client.Guard -or $client.Tun) -and $mismatched.Count -and $systemReady -eq $true -and $systemKey -notin @('Direct','Other','Unset',(Get-GatewayKey)) -and (Get-Profile $systemKey).Protocol -eq 'http'){
        $action='align-environment';$repairText='先检测当前系统代理的实际请求；通过后备份并将用户代理变量对齐到这个入口。保留系统代理和程序分流规则。'
    }
    if(-not $action -and $owner -eq 'none' -and $manual -and $manual.Ready -eq $false -and -not ($client.Guard -or $client.Tun)){
        $entranceText=if($script:Profiles.Routing.Adapter -eq 'none'){'直接切换到已登记的本地 HTTP 备用入口，不启动独立引擎，保留程序与网站规则'}else{'接入流向固定入口并保留程序与网站规则'}
        $action='repair-dead-entry';$repairText='检测已配置的备用代理，按备用顺序选择通过实际请求检测的线路，'+$entranceText+'；若没有可用备用，则备份后撤销失效的手动系统代理，只清理确认失效的本地代理变量，保留有效变量、自动配置和规则。已有专用程序规则不会被改成统一线路；需要代理的网站不保证能直连。'
    }
    if(-not $action -and $owner -eq 'none' -and $systemKey -eq 'Direct' -and $dead.Count -and -not ($client.Guard -or $client.Tun)){
        $action='clear-dead-environment';$repairText='备份后仅清理确认未监听的简单本地代理变量；保留系统设置、有效或未知变量、NO_PROXY 和程序规则。不自动选择代理或启动服务，需要代理的网站仍需可用线路。'
    }
    $targets=@();$external=$null;$views=$null
    if($Probe){
        $views=ConvertTo-ApplicationProxyViewSummary $system (Get-WindowsApplicationProxyViews)
        if($views.Different){$issues+=[pscustomobject]@{Code='windows-proxy-view-mismatch';Message='Windows 的代理读取视图不一致。部分软件可能读取到不同入口或关闭状态；需在原代理客户端核对后复试，尚不能据此断定根因。'}}
        $external=Get-ExternalMihomoObservation $tcp
        if(($systemReady -eq $true -or ($manual -and $manual.Listening -eq $true)) -and $systemKey -in (Get-ProfileKeys)){$targets=@(Test-NetworkTargets (Get-Profile $systemKey))}
    }
    if($revision -cne (Get-NetworkRepairRevision (Get-SystemSnapshot) (Get-UserProxyEnv))){throw '诊断期间配置发生变化，请重新排查。'}
    $report=[pscustomobject]@{Version=$script:ProductVersion;CheckedAt=[DateTimeOffset]::UtcNow.ToString('o');Issues=@($issues);Endpoints=@($endpoints);EnvironmentEndpoints=@($environmentEndpoints);Targets=$targets;ExternalMihomo=$external;ApplicationProxyViews=$views;RepairAction=$action;RepairText=$repairText;Revision=$revision;ExpectedSession=$sessionId;SystemKey=$systemKey;OwnerState=$owner;Message=''}
    $entryName=$(if($system.Flags -band 2){Get-RouteName $systemKey}else{'手动代理关闭'})
    $report|Add-Member NoteProperty TopologySummary (ConvertTo-NetworkTopologySummary $topology)
    $report|Add-Member NoteProperty CurrentEntry ([pscustomobject]@{Key=$systemKey;Name=$entryName;Source='WinINET';ManualEnabled=[bool]($system.Flags -band 2);Listening=$(if($manual){$manual.Listening}elseif($entry){$entry.Listening}else{$null});OwnerVerified=$(if($manual){$manual.OwnerVerified}elseif($entry){$entry.OwnerVerified}else{$false});Ready=$systemReady})
    $setEnvironment=@(@('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')|Where-Object {(Get-EndpointKey $environment.$_) -ne 'Unset'})
    $report|Add-Member NoteProperty UserProxyEnvironment ([pscustomobject]@{State=$(if(-not $setEnvironment.Count){'Unset'}elseif($mismatched.Count){'Different'}else{'Aligned'});SetCount=$setEnvironment.Count})
    $selection=Get-Selection
    $report|Add-Member NoteProperty HistoricalSelection ([pscustomobject]@{Available=[bool]$selection;Key=$(if($selection){[string]$selection.Key}else{''});IsHistorical=$true;DifferentFromCurrent=([bool]$selection -and [string]$selection.Key -cne [string]$systemKey)})
    $lines=@('网络排查结果：')+@($issues|ForEach-Object {'• '+$_.Message})
    if($views){$lines+=$views.Message}
    if($Probe -and $manual -and $manual.Listening -eq $true -and -not $manual.OwnerVerified){$lines+='当前本机入口确实在监听，进程归属未知。本次可显式探测该已配置入口，但不能据此授权切换、修复或认领第三方内核。'}
    if($external){$lines+=Format-ExternalMihomoObservation $external}
    if(-not $issues.Count){$lines+='本地入口与设置未发现明显异常。请继续检测所选代理或目标站点，尚未验证登录和持续对话。'}
    foreach($target in $targets){
        if($target.Stage -eq 'https-response'){$lines+=($target.Name+'：已收到 HTTPS 响应 HTTP '+$target.HttpCode+'；不代表登录或持续对话成功。'+$(if($target.HttpCode -ge 400){' 目标返回错误响应，请检查访问限制或出口。'}))}
        else{$lines+=($target.Name+'：'+(Get-NetworkTargetStageText $target.Stage $target))}
    }
    if($report.CurrentEntry.Listening -eq $true -and (Get-NetworkForwardingState $targets) -eq 'AllTimeout'){$lines+='入口监听仍存在，但HTTPS代测均超时：仅限本轮这些固定目标；请在原代理/VPN客户端检查上游与错误，再显式重新检测，尚不能确定唯一根因或永久失效。'}
    if($action){$lines+=('可处理：'+$repairText)}else{$lines+='当前没有可自动处理的项目，请按上面的建议操作。'}
    $lines+='已经运行的应用可能保留旧代理；修复后若仍断线，请保存工作并完整重开宿主应用。流向不会自动结束它们。'
    $report.Message=$lines -join "`r`n"
    Add-SystemNetworkDiagnosisSummary $report -Probe:$Probe
    $report
}
function New-NetworkDiagnosticFinding([string]$Code,[string]$Level,[string]$Layer,[string]$Title,[string]$Evidence,[string]$NextStep='',[string]$Scope='当前电脑') {
    [pscustomobject]@{Code=$Code;Level=$Level;Layer=$Layer;Title=$Title;Evidence=$Evidence;NextStep=$NextStep;Scope=$Scope}
}
function Complete-NetworkDiagnosticSummary($Report,$Findings,$Checks,[string]$Scope) {
    $rank=@{Problem=0;Retest=1;Passed=2;Info=3}
    $layerRank=@{Settings=0;Entry=1;Program=2;Route=3}
    $ordered=@($Findings|Sort-Object @{Expression={$rank[[string]$_.Level]}},@{Expression={if($_.Code -like '*-forwarding-timeout'){0}else{1}}},@{Expression={$layerRank[[string]$_.Layer]}},Code)
    $problems=@($ordered|Where-Object Level -eq 'Problem');$retest=@($ordered|Where-Object Level -eq 'Retest')
    $state=if($problems.Count){'ProblemFound'}elseif($retest.Count){'NeedsRetest'}else{'ChecksPassed'}
    $title=if($problems.Count){'发现需要处理的问题：'+$problems[0].Title}elseif($retest.Count){'需要复试或补充证据：'+$retest[0].Title}else{'本次已检查的范围通过；登录与持续使用仍需实测'}
    $next=@();$seen=@{}
    foreach($finding in $ordered){if($finding.NextStep -and -not $seen.ContainsKey($finding.NextStep)){$seen[$finding.NextStep]=$true;$next+=[pscustomobject]@{Order=($next.Count+1);Text=$finding.NextStep;Scope=$finding.Scope;Code=$finding.Code}}}
    if(-not $next.Count){$next=@([pscustomobject]@{Order=1;Text='回目标软件完成一次真实请求；若仍失败，排查该程序网络并核对具体错误。';Scope=$Scope;Code='real-request-required'})}
    $Report|Add-Member NoteProperty Conclusion ([pscustomobject]@{State=$state;Title=$title;Scope=$Scope;AuthenticationVerified=$false}) -Force
    $Report|Add-Member NoteProperty Findings $ordered -Force
    $Report|Add-Member NoteProperty Checks @($Checks) -Force
    $Report|Add-Member NoteProperty NextSteps $next -Force
    $stateNames=@{ProblemFound='发现问题';NeedsRetest='需要复试';ChecksPassed='检查通过';NotChecked='未检查'}
    $lines=@($title,('检查对象：'+$Scope))
    $systemReport=$Report;if($Report.PSObject.Properties['SystemDiagnosis']){$systemReport=$Report.SystemDiagnosis}
    if($Report.PSObject.Properties['Program']){$lines+='系统入口与整机问题见独立系统详情；不作为该程序失败的结论。'}
    elseif($systemReport -and $systemReport.CurrentEntry){$lines+=('当前系统入口：'+$systemReport.CurrentEntry.Name+'（WinINET 实读；历史选择不作为当前出口）。')}
    if($Report.ProbeScope){
        $probeState=@{Ready='本轮已核验';Unknown='尚未核验';Unavailable='当前不可用';Changed='检查期间发生变化'}
        if($Report.ProbeScope.Kind -eq 'Managed'){$lines+=('本次代测范围：程序专用入口'+$(if($Report.ProbeScope.Port){' 127.0.0.1:'+$Report.ProbeScope.Port}else{''})+'；'+$probeState[[string]$Report.ProbeScope.State]+$(if($Report.ProbeScope.State -eq 'Ready'){'；有效出口：'+(Get-RouteName $Report.ProbeScope.EffectiveRoute)}else{''})+'。')}
        elseif($Report.ProbeScope.Kind -eq 'SystemComparison'){$lines+='本次代测范围：独立系统入口对照，不证明目标程序实际采用该入口。'}
        else{$lines+='本次未代测程序入口：尚无已核验的入口，不替换为系统代理或直连。'}
    }
    if($Report.ObservedProxyScope){
        $observed=$Report.ObservedProxyScope
        $observedStates=@{Unknown='未核验';NotObserved='未观察到';Ambiguous='入口有歧义';Ready='本轮已核验';Changed='检查期间变化'}
        $forwardingStates=@{NotChecked='未代测';Unknown='未知';AllTimeout='本轮这些目标均超时';PartialResponse='部分目标响应，部分未完成';HttpsResponse='已获得 HTTPS 响应';Failed='代测未完成'}
        $lines+=('当前观察到的外部代理入口对照'+$(if($observed.Port){'（本机端口 '+$observed.Port+'）'}else{''})+'：'+$observedStates[[string]$observed.State]+'；转发代测：'+$forwardingStates[[string]$observed.ForwardingState]+'。独立于程序固定入口和系统对照；由流向发出，不证明程序实际请求成功。')
        if($observed.CoverageLimited){$lines+='此项仅检查已核验成员所见入口：程序家族观察不完整，其他成员和入口未知，不代表全程序。'}
    }
    if($Report.TopologySummary){
        $topologyNames=@{Evidence='已见隧道路由证据';Unknown='读取或覆盖未知';NoEvidence='未见隧道路由证据'}
        $lines+=('系统路由背景：IPv4 '+$topologyNames[[string]$Report.TopologySummary.IPv4]+'；IPv6 '+$topologyNames[[string]$Report.TopologySummary.IPv6]+'。不证明此程序已使用 VPN；流向直连也不保证绕过它。')
    }
    $lines+='下一步：';foreach($step in @($next|Select-Object -First 4)){$lines+=($step.Order.ToString()+'. '+$step.Text)}
    foreach($check in $Checks){$lines+=($check.Title+'：'+$stateNames[[string]$check.State]+'。'+$check.Evidence)}
    if($Report.PSObject.Properties['Program']){$lines+=('该程序保存线路：'+$Report.Program.Policy+'（保存意图，实际路径以当前观察为准）。');$lines+=('该程序当前观察：'+$Report.Program.Actual);$lines+=('该程序观察范围：'+$Report.Program.Coverage)}
    $showChatSupplement=-not $Report.PSObject.Properties['Program'] -or $Report.Program.Name -ieq 'ChatGPT'
    if($showChatSupplement -and $systemReport -and $systemReport.ExternalMihomo -and $systemReport.ExternalMihomo.State -eq 'observed'){
        $chatRows=@($systemReport.ExternalMihomo.Rows|Where-Object {$_.Source -ceq 'ChatGPT（本机 TCP 对应）'}|Select-Object -First 3)
        if($chatRows.Count){
            $lines+='ChatGPT 连接旁证（独立范围，不代表整机总出口或其他程序）：'
            foreach($row in $chatRows){$lines+=($row.Host+' · 入口 '+$row.Type+' · '+($row.Chains -join ' → ')+' ×'+$row.Count)}
        }
    }
    $important=@($ordered|Where-Object {$_.Level -in @('Problem','Retest')}|Select-Object -First 5)
    if($important.Count){$lines+='优先查看：';foreach($finding in $important){$lines+=('• '+$finding.Title+'：'+$finding.Evidence)}}
    $lines+='范围限制：监听、TCP 连接、HTTPS 响应分别是不同证据；均不证明账号认证或持续对话成功。短连接、UDP/QUIC、自带代理及其他 VPN 仍可能不在本次观察范围。'
    $Report|Add-Member NoteProperty Summary ($lines -join "`r`n") -Force
}
function Get-NetworkDiagnosticLayerCheck([string]$Layer,[string]$Title,$Findings,[string]$DefaultState='NotChecked',[string]$DefaultEvidence='本轮没有对应证据。') {
    $rank=@{Problem=0;Retest=1;Passed=2;Info=3}
    $rows=@($Findings|Where-Object Layer -eq $Layer|Sort-Object @{Expression={$rank[[string]$_.Level]}},Code)
    $state=$DefaultState
    if(@($rows|Where-Object Level -eq 'Problem').Count){$state='ProblemFound'}
    elseif(@($rows|Where-Object Level -eq 'Retest').Count){$state='NeedsRetest'}
    elseif(@($rows|Where-Object Level -eq 'Passed').Count){$state='ChecksPassed'}
    $evidence=$DefaultEvidence;if($rows.Count){$evidence=(@($rows|Select-Object -First 3|ForEach-Object Evidence) -join ' ')}
    [pscustomobject]@{Layer=$Layer;Title=$Title;State=$state;Evidence=$evidence}
}
function Add-SystemNetworkDiagnosisSummary($Report,[switch]$Probe) {
    $findings=New-Object 'Collections.Generic.List[object]'
    $Report|Add-Member NoteProperty ForwardingState (Get-NetworkForwardingState $Report.Targets) -Force
    $entry=$Report.CurrentEntry;$hasHttps=@($Report.Targets|Where-Object Stage -eq 'https-response').Count -gt 0
    $findings.Add((New-NetworkDiagnosticFinding 'current-entry' 'Info' 'Settings' '按当前实读入口判断' ('当前 WinINET 视图：'+$entry.Name+'。已保存的选择仅是历史意图，不作为当前实际出口。')))
    $problemCodes=@('system-entry-down','gateway-down','gateway-control-unready','upstream-unavailable','stopped-service-session','windows-proxy-view-mismatch')
    foreach($issue in @($Report.Issues)){
        $level='Retest';$layer='Settings';$title='设置或观察需要核对';$next='按此发现核对设置，再次开始网络检查；不要把未知状态当成已停止。'
        switch([string]$issue.Code){
            'system-entry-down'{$layer='Entry';$title='当前系统入口未监听';$next='在原代理客户端启动已配置的代理服务，再次开始网络检查。'}
            'system-entry-unknown'{$layer='Entry';$title='当前入口归属或监听尚未核验';$next='检测当前入口，并排查目标程序网络；不要仅凭进程路径不可读判断断网。';if($hasHttps){$level='Info'}}
            'system-unmanaged'{$layer='Entry';$title='当前系统入口未登记';$next='到代理入口核对当前客户端的地址；登记只为识别，随后检测入口。'}
            'windows-proxy-view-mismatch'{$title='Windows 代理读取视图不一致';$next='在原代理客户端核对系统代理状态，再完整重开受影响软件后复试；流向此次不会自动对齐注册表。'}
            'environment-mismatch'{$title='用户代理变量与系统设置不同';$next='仅当受影响工具使用代理变量时，核对它的环境；先排查目标程序，不要盲目补全局变量。';if($Report.UserProxyEnvironment.State -eq 'Unset'){$level='Info';$title='用户代理变量未设置';$next=''}}
            'system-direct'{$level='Info';$title='系统手动代理关闭';$next='若目标软件需要代理，先核对它是否使用自带代理或隧道，再检查可用入口。'}
            'external-proxy-control'{$level='Info';$title='存在额外网络接管方式';$next='结合目标程序的实际连接判断路径；TUN 或守护存在本身不代表网络失败。';$issueEvidence='已知客户端配置或隧道路由证据存在。可能影响统一接管，但不能据此认定目标软件无法联网。'}
            'environment-entry-down'{$title='部分用户代理变量指向未监听入口';$next='若故障发生在终端工具，核对这些变量；可查看现有修复预览，勿把它当作所有应用的故障。'}
            'environment-bypass-all'{$title='代理绕过规则可能影响工具';$next='在原环境设置中核对 NO_PROXY；不同工具可能有不同解析方式。'}
            'gateway-down'{$layer='Entry';$title='流向固定入口未监听';$next='查看服务状态及现有修复预览；先恢复入口再检查目标程序。'}
            'gateway-control-unready'{$layer='Entry';$title='入口存在但规则控制未就绪';$next='检查内核状态；规则载入后重新排查。'}
            'upstream-unavailable'{$layer='Route';$title='固定入口的出口暂停或未知';$next='检测已配置上游，并在明确确认后选择可用线路。'}
            'stopped-service-session'{$layer='Entry';$title='托管服务已停止但残留会话仍存在';$next='查看现有修复预览，核对影响后恢复残留会话。'}
            'observation-unknown'{$layer='Entry';$title='系统连接观察不可用';$next='稍后重新检查；采集失败不证明入口已停止。'}
            'topology-unknown'{$title='网卡或路由覆盖未知';$next='在原 VPN 或代理客户端核对状态，再通过目标程序的实际连接复试。'}
            default{$title=$issue.Message}
        }
        if([string]$issue.Code -in $problemCodes){$level='Problem'}
        $evidence=[string]$issue.Message;if([string]$issue.Code -eq 'external-proxy-control'){$evidence=$issueEvidence}
        if([string]$issue.Code -eq 'system-entry-unknown' -and $entry.Listening -eq $true){$title='本机入口监听已确认，进程归属未知';$evidence='本轮 TCP 确认当前本机入口在监听；进程路径或归属尚未核验，不能认领内核或授权切换。'}
        $findings.Add((New-NetworkDiagnosticFinding ([string]$issue.Code) $level $layer $title $evidence $next))
    }
    if($Report.ApplicationProxyViews -and -not $Report.ApplicationProxyViews.Different -and @(@('Registry','WinHttpIE')|Where-Object {$Report.ApplicationProxyViews.$_ -eq '未知'}).Count -eq 0){$findings.Add((New-NetworkDiagnosticFinding 'windows-views-agree' 'Passed' 'Settings' '本次代理视图一致' '本次 WinINET、顶层注册表与 WinHTTP IE 手动代理视图一致；应用仍可能采用自有配置。'))}
    elseif($Probe -and $Report.ApplicationProxyViews -and -not $Report.ApplicationProxyViews.Different){$findings.Add((New-NetworkDiagnosticFinding 'windows-views-unknown' 'Retest' 'Settings' '部分 Windows 代理视图读取未知' '不能用某一个读取结果代替其他 API 或所有软件的设置。' '重新检查；同时在原代理客户端和受影响软件核对代理设置。'))}
    if($entry.Listening -eq $true){$findings.Add((New-NetworkDiagnosticFinding 'entry-listening' 'Passed' 'Entry' '当前本机入口在监听' ('TCP 快照确认监听。'+$(if(-not $entry.OwnerVerified){'进程归属未知，不能据此认领内核或授权切换。'}else{'现有归属检查通过；监听仍不证明可转发。'}))))}
    if($Report.HistoricalSelection.DifferentFromCurrent){$findings.Add((New-NetworkDiagnosticFinding 'historical-selection' 'Info' 'Settings' '历史选择与当前入口不同' '本次以 Windows 当前实读入口为准，旧选择不会被当作已生效线路。'))}
    foreach($target in @($Report.Targets)){
        if($target.Stage -eq 'https-response'){
            $findings.Add((New-NetworkDiagnosticFinding ('https-'+$target.Name) 'Passed' 'Route' '当前入口获得 HTTPS 响应' ('流向通过当前已配置入口代测 '+$target.Name+'，HTTP '+$target.HttpCode+'；并非目标软件发出的请求。')))
            if($target.HttpCode -ge 400){$findings.Add((New-NetworkDiagnosticFinding ('target-response-'+$target.Name) 'Info' 'Route' '固定代测站点返回限制或认证响应' ($target.Name+' 返回 HTTP '+$target.HttpCode+'。这是该固定站点的无账号凭据代测响应，不代表其他软件故障；HTTPS 响应层已到达，账号或站点使用仍未验证。') '回目标软件完成真实请求；只有涉及这个代测站点时，再核对它的账号或出口限制。' '固定代测站点'))}
        }else{
            $findings.Add((New-NetworkDiagnosticFinding ('probe-'+$target.Name) 'Retest' 'Route' '代测请求未完成' ($target.Name+'：'+(Get-NetworkTargetStageText $target.Stage $target)) '先检测当前入口，再回目标软件复试并记录错误；不要仅凭某个站点失败判断全部网络失败。'))
        }
    }
    Add-NetworkForwardingTimeoutFinding $Report.Targets ($entry.Listening -eq $true) $findings 'system' '当前系统入口'
    if($Probe -and -not @($Report.Targets).Count){$findings.Add((New-NetworkDiagnosticFinding 'route-not-probed' 'Retest' 'Route' '当前通路尚未完成代测' '入口未满足已配置且可探测的条件；没有通过其他入口或直连补测。' '先核对当前入口，再检测此入口；随后排查受影响的目标程序。'))}
    if($Report.ExternalMihomo -and $Report.ExternalMihomo.State -eq 'observed'){$findings.Add((New-NetworkDiagnosticFinding 'openai-supplement' 'Info' 'Program' '另有固定 OpenAI 域名连接旁证' '已有本地 Mihomo 返回固定域名的连接快照；未知来源不会被认作目标程序，不能推广到其他程序或所有 VPN。'))}
    if($Report.RepairAction){$findings.Add((New-NetworkDiagnosticFinding 'existing-repair-plan' 'Info' 'Settings' '有现有修复方案可预览' '修复影响当前电脑的设置或会话；需再次确认，不代表已完成。' '点击查看并修复，阅读具体影响后决定；它属于整机诊断方案，不是目标程序的自动修复。'))}
    $checks=@(
        (Get-NetworkDiagnosticLayerCheck 'Settings' '1. 系统设置' $findings),
        (Get-NetworkDiagnosticLayerCheck 'Entry' '2. 当前入口' $findings),
        (Get-NetworkDiagnosticLayerCheck 'Route' '3. 代理通路' $findings),
        ([pscustomobject]@{Layer='Program';Title='4. 目标程序实际连接';State='NotChecked';Evidence='整机检查没有选中目标软件。请选择程序后排查；固定站点代测不证明它采用当前入口。'})
    )
    Complete-NetworkDiagnosticSummary $Report $findings $checks '当前电脑的系统入口与固定站点代测'
}
function Get-NetworkForwardingState($Targets,[bool]$Verified=$true) {
    if(-not $Verified){return 'Unknown'}
    $rows=@($Targets);if(-not $rows.Count){return 'NotChecked'}
    $responses=@($rows|Where-Object Stage -eq 'https-response').Count
    if($responses -eq $rows.Count){return 'HttpsResponse'}
    if($responses){return 'PartialResponse'}
    if(@($rows.Name|Select-Object -Unique).Count -ge 2 -and @($rows|Where-Object Stage -ne 'probe-timeout').Count -eq 0){return 'AllTimeout'}
    if(@($rows|Where-Object Stage -in @('probe-unavailable')).Count){return 'Unknown'}
    'Failed'
}
function Add-NetworkForwardingTimeoutFinding($Targets,[bool]$Listening,$Findings,[string]$Prefix,[string]$Source) {
    if($Listening -and (Get-NetworkForwardingState $Targets) -eq 'AllTimeout'){
        $Findings.Add((New-NetworkDiagnosticFinding ($Prefix+'-forwarding-timeout') 'Retest' 'Route' '入口监听仍存在，但HTTPS代测均超时' ($Source+'：仅本轮 '+(@($Targets.Name|Select-Object -Unique) -join '、')+' 的无凭据代测均超时；监听不等于能够转发，不能据此确定唯一根因或永久失效。') '在原代理/VPN 客户端检查上游状态与错误，再显式重新检测；需要换线时先检测备用，不自动清理设置。' $Source))
    }
}
# Rebuild the verified family from live identities before and after the probe.
# A display row or a matching helper name alone is never a probe authority.
function Get-ObservedProxyDiagnosticSnapshot($Row,[bool]$IdentityUnknown,[switch]$AllowClosedConnection) {
    $result=[pscustomobject]@{State='Unknown';ReasonCode='ProgramEvidence';Token='';Profile=$null;Listening=$null;OwnerVerified=$false;CurrentConnectionObserved=$null;CoverageLimited=$false;ClosedBeforeCheckCount=0;VerifiedDetails=@()}
    $result.CoverageLimited=([bool](Test-ObservationFlag $Row 'FamilyObservationTruncated' $false) -or @($Row.FamilyUnknownIds|Where-Object {$_}).Count -gt 0)
    if(-not $Row -or $IdentityUnknown -or $Row.RequiresRepair -or -not $Row.Path -or $Row.ObservationState -eq 'Unknown'){return $result}
    $details=@($Row.ConnectionDetails|Where-Object {$_.State -eq 'Established' -and $_.IngressKind -eq 'Proxy'})
    if(-not $details.Count){$result.State='NotObserved';return $result}
    if($details.Count -gt 128){return $result}
    try{
        $settings=Read-ProfileSettings
        # Get-NetworkDiagnosis refreshed the shared configuration this round.
        # Refuse a later drift rather than temporarily overwriting that context.
        if(($settings|ConvertTo-Json -Depth 30 -Compress) -cne ($script:Profiles|ConvertTo-Json -Depth 30 -Compress)){$result.ReasonCode='ConfigurationChanged';return $result}
        $routing=Get-RoutingSnapshot
        $tcp=Get-TcpObservationSnapshot;if($tcp.Available -ne $true){$result.ReasonCode='TcpUnavailable';return $result}
        $processes=@(Get-ProcessInventory)
        $context=New-ProgramIdentityContext -Processes $processes -Packages @()
        . (Join-Path $PSScriptRoot 'ProgramFamilyTracking.ps1')
        $family=ConvertTo-ProgramObservationFamily (Get-ProgramFamilyTrackingSnapshot $Row.Path $processes $context $true)
        if($family.Available -ne $true){$result.ReasonCode='FamilyUnavailable';return $result}
        $unknownIds=@($family.UnknownIds)+@($Row.FamilyUnknownIds)
        $result.CoverageLimited=($result.CoverageLimited -or [bool]$family.ObservationTruncated -or @($unknownIds|Where-Object {$_}).Count -gt 0)
        $members=@($family.Members|Where-Object {[int]$_.Id -notin $unknownIds})
        $root=Get-ProgramIdentityDescriptor $Row.Path $context
        if(-not $root.Exists -or -not $root.FileId -or -not $root.CanonicalPath){return $result}
        $pids=@(@($Row.PIDs)|ForEach-Object {([string]$_ -split ',')}|ForEach-Object {$_.Trim()}|Where-Object {$_ -match '^[1-9][0-9]*$'}|Select-Object -Unique)
        $sockets=@();$identities=@();$profiles=@();$result.CurrentConnectionObserved=$true
        foreach($detail in $details){
            if($pids -notcontains [string]$detail.PID -or -not $detail.Path -or $detail.RemoteAddress -notin @('127.0.0.1','::1') -or $detail.LocalAddress -notin @('127.0.0.1','::1')){return $result}
            $socket=@($tcp.Rows|Where-Object {$_.State -eq 'Established' -and $_.OwningProcess -eq $detail.PID -and $_.LocalAddress -ceq $detail.LocalAddress -and $_.LocalPort -eq $detail.LocalPort -and $_.RemoteAddress -ceq $detail.RemoteAddress -and $_.RemotePort -eq $detail.RemotePort})
            if($socket.Count -gt 1){$result.ReasonCode='SocketChanged';return $result}
            # Display observations precede this fresh snapshot. An ended socket
            # cannot authorize a probe, but must not invalidate other live ones.
            if($socket.Count -eq 0 -and -not $AllowClosedConnection){$result.ClosedBeforeCheckCount++;continue}
            $process=@($processes|Where-Object {$_.Id -eq $detail.PID})
            $member=@($members|Where-Object {$_.Id -eq $detail.PID})
            if($process.Count -ne 1 -or $member.Count -ne 1 -or $process[0].Path -ine $detail.Path -or $member[0].Path -ine $detail.Path -or $process[0].PathStatus -ne 'Available' -or $process[0].StartTime -le [DateTime]::MinValue){$result.ReasonCode='MemberIdentity';return $result}
            $file=Get-ProgramIdentityDescriptor $detail.Path $context
            if(-not $file.Exists -or -not $file.FileId -or -not $file.CanonicalPath){return $result}
            if($socket.Count -eq 0){$result.CurrentConnectionObserved=$false}
            $matching=@($settings.Profiles|Where-Object {$_.Port -eq $detail.RemotePort -and $_.Host -in @('127.0.0.1','::1','localhost')})
            if($matching.Count -ne 1){$result.State='Ambiguous';$result.ReasonCode='RegistrationAmbiguous';return $result}
            $profile=$matching[0]
            if(-not $profile.Id -or @($settings.Profiles|Where-Object {$_.Id -ceq $profile.Id}).Count -ne 1){$result.State='Ambiguous';return $result}
            if($profile.Id -eq (Get-GatewayKey) -or $profile.Protocol -notin @('http','socks5') -or ($profile.Host -ne 'localhost' -and $profile.Host -cne $detail.RemoteAddress) -or @($routing.programIngresses|Where-Object {$_.port -eq $profile.Port}).Count){$result.ReasonCode='NotExternalEntry';return $result}
            # The registered display attribution must agree with independent TCP.
            if($detail.EvidenceSource -ne 'RegisteredEndpoint' -or $detail.IngressId -cne $profile.Id){$result.ReasonCode='AttributionChanged';return $result}
            $profiles+=@($profile)
            $sockets+=@([pscustomobject]@{PID=[int]$detail.PID;LocalAddress=$detail.LocalAddress;LocalPort=[int]$detail.LocalPort;RemoteAddress=$detail.RemoteAddress;RemotePort=[int]$detail.RemotePort})
            $identities+=@([pscustomobject]@{PID=[int]$detail.PID;Start=([DateTime]$process[0].StartTime).ToUniversalTime().Ticks;Path=$file.CanonicalPath;FileId=$file.FileId})
            $result.VerifiedDetails+=@($detail)
        }
        if(-not $result.VerifiedDetails.Count){$result.State='NotObserved';$result.ReasonCode='SocketChanged';return $result}
        # Also reject a second live registered endpoint absent from the display
        # details, so a partial or stale row cannot choose the favourable one.
        $scanPids=@($members|ForEach-Object {[string]$_.Id})
        foreach($socket in @($tcp.Rows|Where-Object {$_.State -eq 'Established' -and [string]$_.OwningProcess -in $scanPids -and $_.RemoteAddress -in @('127.0.0.1','::1')})){
            $registered=@($settings.Profiles|Where-Object {$_.Port -eq $socket.RemotePort -and $_.Host -in @('127.0.0.1','::1','localhost') -and $_.Id -ne (Get-GatewayKey)})
            if($registered.Count -gt 1 -or ($registered.Count -eq 1 -and (@($profiles.Id) -notcontains $registered[0].Id -or @($sockets.RemoteAddress) -notcontains $socket.RemoteAddress))){$result.State='Ambiguous';return $result}
        }
        $keys=@($profiles.Id|Select-Object -Unique)
        if($keys.Count -ne 1){$result.State='Ambiguous';return $result}
        $profile=$profiles[0];$result.Profile=$profile
        # Match the address family of the actual socket. A dual-stack ambiguity
        # or two owners cannot be certified by whichever listener is found first.
        $addresses=@($sockets.RemoteAddress|Select-Object -Unique)
        if($addresses.Count -ne 1){$result.State='Ambiguous';return $result}
        $listeners=@($tcp.Rows|Where-Object {$_.State -eq 'Listen' -and $_.LocalPort -eq $profile.Port -and (($_.LocalAddress -in @('127.0.0.1','0.0.0.0') -and $addresses -contains '127.0.0.1') -or ($_.LocalAddress -in @('::1','::') -and $addresses -contains '::1'))})
        if(-not $listeners.Count){$result.ReasonCode='ListenerUnavailable';return $result};$result.Listening=$true
        $owners=@($listeners.OwningProcess|Select-Object -Unique);if($owners.Count -ne 1){$result.State='Ambiguous';return $result}
        $owner=@($processes|Where-Object {$_.Id -eq $owners[0]})
        if($owner.Count -ne 1 -or $owner[0].Id -ne $owners[0] -or -not $owner[0].Path -or $owner[0].PathStatus -ne 'Available' -or $owner[0].StartTime -le [DateTime]::MinValue -or ($profile.CorePath -and $owner[0].Path -ine $profile.CorePath)){$result.ReasonCode='OwnerIdentity';return $result}
        $ownerFile=Get-ProgramIdentityDescriptor $owner[0].Path $context
        if(-not $ownerFile.Exists -or -not $ownerFile.FileId -or -not $ownerFile.CanonicalPath){return $result}
        $result.OwnerVerified=$true
        # Tokens stay in this stack frame and are never exposed in the report.
        # Bind only participating identities and their verified ancestor chain.
        # An unrelated helper appearing, or the original socket naturally ending
        # while curl is in flight, must not erase this round's entry evidence.
        $bound=@{}
        foreach($identity in $identities){
            $next=[int]$identity.PID
            while($next -gt 0 -and -not $bound.ContainsKey($next)){
                $chain=@($members|Where-Object {$_.Id -eq $next});if($chain.Count -ne 1){break}
                $bound[$next]=$chain[0];$next=[int]$chain[0].ParentId
            }
        }
        $familyBinding=@(foreach($member in @($bound.Values|Sort-Object Id)){$identity=Get-ProgramIdentityDescriptor $member.Path $context;[pscustomobject]@{PID=$member.Id;ParentId=$member.ParentId;Start=([DateTime]$member.StartTime).ToUniversalTime().Ticks;FileId=$identity.FileId;Path=$identity.CanonicalPath}})
        $binding=[pscustomobject]@{Settings=$settings;Routing=$routing;Root=@($root.FileId,$root.CanonicalPath);Family=$familyBinding;Identities=@($identities|Sort-Object PID -Unique);Owner=@($owners[0],([DateTime]$owner[0].StartTime).ToUniversalTime().Ticks,$ownerFile.FileId,$ownerFile.CanonicalPath)}
        $hash=[Security.Cryptography.SHA256]::Create()
        try{$result.Token=[Convert]::ToBase64String($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($binding|ConvertTo-Json -Depth 35 -Compress))))}finally{$hash.Dispose()}
        # A localhost registration is allowed only after exact address matching;
        # curl uses that observed numeric loopback, never a new DNS selection.
        $result.Profile=[pscustomobject]@{Id=$profile.Id;Protocol=$profile.Protocol;Host=$addresses[0];Port=$profile.Port}
        $result.State='Ready';$result.ReasonCode='Verified'
    }catch{$result.ReasonCode='CollectionError'} # Never expose raw errors, which may contain private details.
    $result
}
function Get-ObservedProxyDiagnosticScope($Row,[bool]$IdentityUnknown) {
    $scope=[pscustomobject]@{Kind='ObservedExternalProxy';State='Unknown';ReasonCode='ProgramEvidence';ProfileId='';Port=$null;Listening=$null;OwnerVerified=$false;CurrentConnectionObserved=$null;CoverageLimited=$false;ClosedBeforeCheckCount=0;ObservedConnectionCount=0;ForwardingState='NotChecked';CheckedAt=[DateTimeOffset]::UtcNow.ToString('o');Targets=@();AuthenticationVerified=$false}
    $before=Get-ObservedProxyDiagnosticSnapshot $Row $IdentityUnknown
    $scope.State=$before.State;$scope.Listening=$before.Listening;$scope.OwnerVerified=$before.OwnerVerified;$scope.CoverageLimited=$before.CoverageLimited
    $scope.ReasonCode=$before.ReasonCode
    $scope.ClosedBeforeCheckCount=$before.ClosedBeforeCheckCount;$scope.ObservedConnectionCount=@($before.VerifiedDetails).Count
    if($before.State -ne 'Ready'){return $scope}
    $scope.ProfileId=[string]$before.Profile.Id;$scope.Port=[int]$before.Profile.Port
    # Only endpoint fields reach curl. No account, proxy credentials or response
    # body are requested, and no alternate/system endpoint is used on failure.
    $profile=[pscustomobject]@{Protocol=$before.Profile.Protocol;Host=$before.Profile.Host;Port=$before.Profile.Port}
    try{$scope.Targets=@(Test-NetworkTargets $profile)}catch{$scope.State='Unknown'}
    # Revalidate only connections that actually authorized this round. Bringing
    # an already-ended display socket back would change the binding spuriously.
    $checkedRow=$Row|Select-Object *;$checkedRow.ConnectionDetails=@($before.VerifiedDetails)
    $after=Get-ObservedProxyDiagnosticSnapshot $checkedRow $IdentityUnknown -AllowClosedConnection
    $scope.Listening=$after.Listening
    $scope.CurrentConnectionObserved=$after.CurrentConnectionObserved
    $scope.CoverageLimited=($scope.CoverageLimited -or $after.CoverageLimited)
    if($after.State -ne 'Ready' -or $before.Token -cne $after.Token){$scope.State='Changed';$scope.OwnerVerified=$false;$scope.ReasonCode=$(if($after.State -ne 'Ready'){$after.ReasonCode}else{'BindingChanged'})}
    $scope.ForwardingState=Get-NetworkForwardingState $scope.Targets ($scope.State -eq 'Ready')
    $scope
}
function Add-ObservedProxyProbeFindings($Scope,$Findings) {
    if($Scope.State -eq 'NotObserved'){return}
    if($Scope.State -ne 'Ready'){
        $reasons=@{ProgramEvidence='程序或文件身份证据不足';ConfigurationChanged='配置与本轮观察不一致';TcpUnavailable='当前 TCP 读取不可用';FamilyUnavailable='当前进程家族读取不可用';MemberIdentity='联网成员身份或父链未核验';SocketChanged='原 TCP 已结束或快照已变化，请重新检查';RegistrationAmbiguous='入口登记不唯一';NotExternalEntry='所见入口不满足独立外部入口条件';AttributionChanged='连接与登记的归属不一致';ListenerUnavailable='本轮未核验到对应监听';OwnerIdentity='监听进程身份或登记归属未核验';BindingChanged='检查期间身份或配置发生变化';CollectionError='采集过程未完成，可重新检查'}
        $reason=$reasons[[string]$Scope.ReasonCode];if(-not $reason){$reason='证据不足或有歧义'}
        $Findings.Add((New-NetworkDiagnosticFinding 'observed-proxy-unknown' $(if($Scope.State -eq 'Changed'){'Retest'}else{'Info'}) 'Route' '观察到的外部入口未完成核验' ($reason+'；不认证此路径，不借其他入口补测。') '' '独立外部代理入口对照'));return
    }
    $Findings.Add((New-NetworkDiagnosticFinding 'observed-proxy-listening' 'Info' 'Entry' '检测开始时所见外部入口已核验' ('检测开始时，唯一登记本机入口与程序精确 TCP 对应；前后进程身份、可信父链、入口归属与配置一致。'+$(if($Scope.CurrentConnectionObserved -eq $false){'原连接在代测期间已结束，不代表端口失效；本次仍只说明检测开始时所见入口。'}else{'后检仍见原 TCP。'})+'监听与归属不代表转发健康。') '' '独立外部代理入口对照'))
    if($Scope.ClosedBeforeCheckCount -gt 0){$Findings.Add((New-NetworkDiagnosticFinding 'observed-proxy-ended-display-sockets' 'Info' 'Entry' '旧快照中的部分连接已自然结束' ('本轮排除 '+$Scope.ClosedBeforeCheckCount+' 条已结束的旧连接，只用重读时仍存在的 '+$Scope.ObservedConnectionCount+' 条已核验连接确定此入口；不把连接结束当作端口失效。') '' '独立外部代理入口对照'))}
    if($Scope.CoverageLimited){$Findings.Add((New-NetworkDiagnosticFinding 'observed-proxy-limited-coverage' 'Retest' 'Program' '外部入口检查仅覆盖已核验成员' '程序家族观察不完整；这些成员所见入口可单独代测，其他成员及入口未知，结果不代表全程序。' '结合出错程序和后台的实际错误复查；不要把此入口结果推广到未知成员。' '已核验成员所见外部代理入口'))}
    foreach($target in @($Scope.Targets)){
        $ok=$target.Stage -eq 'https-response'
        $Findings.Add((New-NetworkDiagnosticFinding ('observed-proxy-'+$target.Name) $(if($ok){'Passed'}else{'Retest'}) 'Route' $(if($ok){'观察到的外部入口获得 HTTPS 响应'}else{'观察到的外部入口代测未完成'}) ($target.Name+'：'+$(if($ok){'HTTP '+$target.HttpCode+'；仅 HTTPS 可达，账号认证未验证。'}else{Get-NetworkTargetStageText $target.Stage $target})+' 请求由流向代测，不是程序实际请求。'+$(if($Scope.CoverageLimited){'仅已核验成员所见入口，其他成员未知。'}else{''})) $(if($ok){''}else{'在原代理/VPN 客户端检查此入口的上游和错误，再回目标软件复试。'}) '独立外部代理入口对照'))
    }
    Add-NetworkForwardingTimeoutFinding $Scope.Targets ($Scope.Listening -eq $true) $Findings 'observed-proxy' $(if($Scope.CoverageLimited){'已核验成员所见外部代理入口（家族观察不完整，其他成员未知）'}else{'当前观察到的外部代理入口'})
}
function Get-ProgramDiagnosticProbeScope($Row,[bool]$IdentityUnknown) {
    $scope=[pscustomobject]@{Kind='Unknown';State='Unknown';IngressId='';Port=$null;Listening=$null;CheckedAt=[DateTimeOffset]::UtcNow.ToString('o');EffectiveRoute='Unknown';EntrySource='未核验程序入口';Targets=@()}
    if(-not $Row -or $IdentityUnknown -or $Row.RequiresRepair){return $scope}
    if($Row.Mode -ne 'managed'){
        # An engine-specific rule or legacy launch environment is not the system
        # default route. A system comparison never certifies application adoption.
        if($Row.Mode -in @('observe','engine') -and (-not $Row.HasSavedRule -or $Row.Policy -eq 'Follow')){
            $scope.Kind='SystemComparison';$scope.EntrySource='当前系统入口对照；未证明此程序采用它'
        }
        return $scope
    }
    $scope.Kind='Managed';$scope.EntrySource='程序固定入口（本轮尚未核验）'
    try{
        if(-not $Row.Path -or -not $Row.SavedPath -or $Row.Path -ine $Row.SavedPath){return $scope}
        $ingress=Get-ManagedProgramIngress $Row.SavedPath
        if(-not $ingress -or -not $ingress.id -or $ingress.path -ine $Row.SavedPath -or [int]$ingress.port -lt 1 -or [int]$ingress.port -gt 65535){return $scope}
        $saved=@((Get-RoutingSnapshot).programIngresses|Where-Object {$_.path -ieq $Row.SavedPath -or $_.id -ceq $ingress.id -or $_.port -eq $ingress.port})
        if($saved.Count -ne 1 -or $saved[0].id -cne $ingress.id -or $saved[0].path -ine $ingress.path -or $saved[0].port -ne $ingress.port){return $scope}
        $scope.IngressId=[string]$ingress.id;$scope.Port=[int]$ingress.port
        $live=Invoke-AppRouter @{action='status'} -TimeoutMilliseconds 2500
        $matches=@($live.programIngresses|Where-Object {$_.id -ceq $ingress.id -or $_.path -ieq $ingress.path -or $_.port -eq $ingress.port})
        if($live.available -ne $true -or $live.rulesAvailable -ne $true -or $matches.Count -ne 1){return $scope}
        $current=$matches[0]
        if($current.id -cne $ingress.id -or $current.path -ine $ingress.path -or $current.port -ne $ingress.port){return $scope}
        if($current.loaded -eq $false -or $current.ready -eq $false -or $current.effectiveRoute -eq 'Blocked'){$scope.State='Unavailable';return $scope}
        if($current.loaded -ne $true -or $current.ready -ne $true -or $current.effectiveRoute -in @('Unknown','',$null)){return $scope}
        if($current.effectiveRoute -ne 'Direct' -and $current.effectiveRoute -notin (Get-ProfileKeys)){return $scope}
        $endpoint=[string](Get-ManagedIngressEndpoint $ingress)
        if($endpoint -cne ('http://127.0.0.1:'+$scope.Port)){return $scope}
        $scope.EffectiveRoute=[string]$current.effectiveRoute
        $listenBefore=Get-LocalEndpointObservation $endpoint (Get-TcpObservationSnapshot)
        $scope.Targets=@(Test-NetworkTargets ([pscustomobject]@{Protocol='http';Host='127.0.0.1';Port=$scope.Port}))
        $listenAfter=Get-LocalEndpointObservation $endpoint (Get-TcpObservationSnapshot)
        if($listenBefore.Listening -eq $true -and $listenAfter.Listening -eq $true){$scope.Listening=$true}
        # A successful request does not authorize attributing a changed selector
        # or a newly replaced ingress to the original saved program.
        $after=Invoke-AppRouter @{action='status'} -TimeoutMilliseconds 2500
        $verified=@($after.programIngresses|Where-Object {$_.id -ceq $ingress.id -or $_.path -ieq $ingress.path -or $_.port -eq $ingress.port})
        $savedAfter=Get-ManagedProgramIngress $Row.SavedPath
        if($after.available -eq $true -and $after.rulesAvailable -eq $true -and $verified.Count -eq 1 -and $verified[0].id -ceq $ingress.id -and $verified[0].path -ieq $ingress.path -and $verified[0].port -eq $ingress.port -and $verified[0].loaded -eq $true -and $verified[0].ready -eq $true -and $verified[0].effectiveRoute -ceq $scope.EffectiveRoute -and $savedAfter.id -ceq $ingress.id -and $savedAfter.path -ieq $ingress.path -and $savedAfter.port -eq $ingress.port -and $savedAfter.route -ceq $ingress.route){$scope.State='Ready';$scope.EntrySource='已保存且本轮控制器核验的程序固定入口'}
        else{$scope.State='Changed';$scope.EntrySource='程序固定入口（检查期间发生变化）'}
    }catch{$scope.State='Unknown'}
    $scope
}
function Add-ProgramProbeFindings($Scope,$Findings) {
    if($Scope.Kind -eq 'SystemComparison'){
        $Findings.Add((New-NetworkDiagnosticFinding 'system-comparison-only' 'Info' 'Settings' '系统入口仅作独立对照' '当前系统入口的检测结果在系统详情中；没有证明该软件实际采用这个入口。'))
        return
    }
    if($Scope.Kind -ne 'Managed' -or $Scope.State -ne 'Ready'){
        $Findings.Add((New-NetworkDiagnosticFinding 'program-ingress-unknown' 'Retest' 'Entry' '目标程序入口未完成本轮核验' '保存入口、载入、就绪或出口尚未核验一致；没有借用系统入口或直连补测，也没有启动服务。' '查看程序线路与服务状态；核对入口后重新排查。' '目标程序'))
        return
    }
    $Findings.Add((New-NetworkDiagnosticFinding 'program-ingress-ready' 'Passed' 'Entry' '程序固定入口已核验' '本轮保存记录与控制器的程序身份、固定端口、载入、就绪及有效出口一致；与系统默认入口分开。' '' '目标程序'))
    foreach($target in @($Scope.Targets)){
        if($target.Stage -eq 'https-response'){
            $Findings.Add((New-NetworkDiagnosticFinding ('program-probe-'+$target.Name) 'Passed' 'Route' '程序固定入口获得 HTTPS 响应' ($target.Name+' 返回 HTTP '+$target.HttpCode+'；请求由流向通过此程序固定入口代测，不是目标程序真实请求。') '' '目标程序'))
        }else{
            $Findings.Add((New-NetworkDiagnosticFinding ('program-probe-'+$target.Name) 'Retest' 'Route' '程序固定入口代测未完成' ($target.Name+'：'+(Get-NetworkTargetStageText $target.Stage $target)) '在代理入口核对此程序的上游，再回软件复试并记录具体错误。' '目标程序'))
        }
    }
    Add-NetworkForwardingTimeoutFinding $Scope.Targets ($Scope.Listening -eq $true) $Findings 'program' '程序固定入口'
    if(-not @($Scope.Targets).Count){$Findings.Add((New-NetworkDiagnosticFinding 'program-probe-missing' 'Retest' 'Route' '程序入口尚无请求证据' '本轮未取得固定入口代测结果。' '重新排查此程序。' '目标程序'))}
}
function Get-NetworkTargetStageText([string]$Stage,$Target=$null) {
    switch($Stage){
        'probe-unavailable'{'检测工具未能运行，结果未知。'}
        'proxy-rejected'{'代理拒绝了 CONNECT 隧道；请核对入口认证或上游策略。'}
        'target-tls-failed'{'目标 TLS 握手或证书校验失败；尚未取得 HTTPS 响应。'}
        'probe-timeout'{if($Target -and $Target.Protocol -eq 'socks5'){'SOCKS5 连接、TLS 或响应达到本次时限；当前指标不能区分握手阶段。'}elseif($Target -and $Target.ConnectCode -eq 200){'CONNECT 200 已完成，后续 TLS 或 HTTPS 响应达到本次时限；不代表永久故障。'}elseif($Target -and $Target.CurlExitCode -eq 28){'CONNECT 尚未完成（CONNECT=0），连接或隧道协商达到本次时限；不能仅据此区分 TCP 与代理处理停滞。'}else{'本次连接或请求达到外层时限，已完成阶段未知；不代表永久故障。'}}
        'target-tls-or-timeout'{'代理隧道已建立，目标 TLS 或请求尚未完成。'}
        default{'代理握手或目标连接未完成；原因尚未区分。'}
    }
}
function Get-ProgramNetworkDiagnosis([string]$Path) {
    $system=$null;$apps=$null;$row=$null;$tcp=$null;$selectionUnknown=$false
    # Refresh configuration and preserve independent system context without an
    # active request before the selected application's ingress is established.
    try{$system=Get-NetworkDiagnosis}catch{}
    try{
        $tcp=Get-TcpObservationSnapshot
        $apps=Get-ApplicationRoutes -TcpRows $tcp.Rows -TcpAvailable $tcp.Available
        $matches=@($apps.Rows|Where-Object {$Path -and ($_.Path -ieq $Path -or $_.SavedPath -ieq $Path)})
        if(-not $matches.Count -and $Path){$matches=@($apps.Rows|Where-Object {$_.Path -and (Test-ProgramPathEquivalent $Path $_.Path)})}
        if($matches.Count -eq 1){$row=$matches[0]}elseif($matches.Count -gt 1){$selectionUnknown=$true}
        elseif($Path -and (Test-ObservationFlag $apps 'ProcessesAvailable' $false)){
            # Non-windowed, unsaved applications may have no catalog row. Use the
            # same verified family and TCP observer, without inventing controller data.
            $processes=@(Get-ProcessInventory);$context=New-ProgramIdentityContext -Processes $processes
            $familySnapshot=ConvertTo-ProgramObservationFamily (Get-ProgramFamilyTrackingSnapshot $Path $processes $context $true)
            $family=@($familySnapshot.Members);$byId=@{};foreach($process in $processes){$byId[[int]$process.Id]=$process}
            $candidate=New-ApplicationCandidate $Path ([IO.Path]::GetFileNameWithoutExtension($Path))
            $core=[pscustomobject]@{available=$false;rulesAvailable=$false;connectionsAvailable=$false}
            $evidence=Get-ApplicationConnectionEvidence $family $tcp.Rows @() (Get-GatewayKey) $byId $Path $tcp.Available @() $familySnapshot
            $row=Get-ApplicationObservationRow $candidate $family $evidence $core $null $null $null $true $familySnapshot
        }
    }catch{$selectionUnknown=$true}
    $observedProxyScope=Get-ObservedProxyDiagnosticScope $row ($selectionUnknown -or -not (Test-ObservationFlag $apps 'TcpAvailable' $false))
    $probeScope=Get-ProgramDiagnosticProbeScope $row $selectionUnknown
    if($probeScope.Kind -eq 'SystemComparison'){try{$system=Get-NetworkDiagnosis -Probe}catch{$system=$null}}
    if($system -and $probeScope.Kind -eq 'SystemComparison'){$probeScope.State='Ready';$probeScope.Targets=@($system.Targets)}
    $findings=New-Object 'Collections.Generic.List[object]'
    $probeScope|Add-Member NoteProperty ForwardingState (Get-NetworkForwardingState $probeScope.Targets ($probeScope.State -eq 'Ready')) -Force
    Add-ProgramProbeFindings $probeScope $findings
    Add-ObservedProxyProbeFindings $observedProxyScope $findings
    if(-not $system){$findings.Add((New-NetworkDiagnosticFinding 'system-diagnosis-unknown' 'Info' 'Settings' '独立系统详情读取未知' '系统读取失败或配置发生变化；该结果不代替目标程序的入口与连接证据。'))}
    $processIds=@();if($row){$processIds=@(@($row.PIDs)|ForEach-Object {([string]$_ -split ',')}|ForEach-Object {$_.Trim()}|Where-Object {$_ -match '^[1-9][0-9]*$'}|Select-Object -Unique)}
    $running=$null;if($row){$running=($processIds.Count -gt 0);if([string]$row.ObservationState -eq 'Unknown' -and -not $processIds.Count){$running=$null}}
    $name='选中的程序';try{if($Path){$name=[IO.Path]::GetFileNameWithoutExtension($Path)}}catch{}
    $details=@();if($row){$details=@($row.ConnectionDetails|Where-Object {$_})}
    $external=@($details|Where-Object {$_.State -eq 'Established' -and $_.IngressKind -ne 'LocalInternal'})
    $controller=@($external|Where-Object {$_.EvidenceSource -eq 'Controller' -and $_.ActualRoute -notin @('Unknown','Blocked','LocalInternal')})
    if($row -and $row.RequiresRepair){$findings.Add((New-NetworkDiagnosticFinding 'program-identity-changed' 'Problem' 'Program' '保存的程序记录需要核对' '共享身份观察器已标记保存记录需要核对；这是记录问题，不代表当前软件无法联网或已确定故障根因。当前连接仍单独观察。' '在程序详情核对当前路径与保存记录，查看现有路径修复预览；同时保留当前连接证据，不盲目改系统入口。' '目标程序'))}
    if(-not $row -or $selectionUnknown){$findings.Add((New-NetworkDiagnosticFinding 'program-observation-unknown' 'Retest' 'Program' '目标程序身份或观察范围未知' '未取得唯一、可核验的程序行；没有凭名字或域名认领连接。' '在程序列表核对所选 EXE；保持软件运行并重试一次后再次排查。' '目标程序'))}
    elseif($row.ObservationState -eq 'Missing'){$findings.Add((New-NetworkDiagnosticFinding 'program-path-missing' 'Problem' 'Program' '目标程序路径已失效' '当前程序路径未找到，未启动任何替代文件。' '核对程序安装位置及保存记录，再重新选择 EXE。' '目标程序'))}
    elseif($running -eq $false){$findings.Add((New-NetworkDiagnosticFinding 'program-not-running' 'Retest' 'Program' '目标程序未运行' '没有运行中的已核验进程，无法观察它的实际请求。' '自行正常打开目标软件，发起一次原本失败的请求，再排查此程序网络。' '目标程序'))}
    elseif($row.ObservationState -eq 'Unknown' -or -not (Test-ObservationFlag $apps 'TcpAvailable' $false)){$findings.Add((New-NetworkDiagnosticFinding 'program-connections-unknown' 'Retest' 'Program' '目标程序连接采集不完整' '进程、TCP 或引擎证据读取失败；不能据此判定软件未联网。' '稍后重新排查，并在目标软件记录具体错误。' '目标程序'))}
    else{
        if($row.NeedsEntryConnection -or $row.ProgramEntryState -eq 'NeedsEntry'){$findings.Add((New-NetworkDiagnosticFinding 'program-entry-bypassed' 'Info' 'Program' '保存线路未接入当前系统入口' '线路已保存或载入，但当前观察未接入相应分流入口；这仅说明规则控制覆盖不同，不能据此推断软件断网。' '若需要流向控制这部分连接，核对软件自带代理及现有接入预览；网络失败另按实际入口代测与软件错误排查。' '目标程序'))}
        $bypassed=@($external|Where-Object IngressKind -eq 'Proxy')
        if($row.Mode -in @('engine','managed') -and $bypassed.Count){$findings.Add((New-NetworkDiagnosticFinding 'program-other-proxy-entry' 'Info' 'Program' '当前连接未经过流向固定入口' '发现程序直接连接已登记的外部代理，绕过流向固定入口。外部代理可能恰好就是保存的上游，但流向不能靠该规则切换这部分连接；这不等于已确认软件断网或选错上游。' '若需要流向控制这部分连接，核对软件自带代理与子程序设置；若请求失败，先检查实际代理入口及原代理/VPN 上游。' '目标程序'))}
        if($row.HasSavedRule -and $row.Mode -in @('engine','managed') -and -not $row.RuleLoaded){$findings.Add((New-NetworkDiagnosticFinding 'program-rule-not-loaded' 'Retest' 'Program' '程序规则仅保存或载入未知' '本轮未核验该规则已经载入，不能把保存状态当作实际连接路径。' '查看分流服务和规则状态；明确操作后重新排查程序连接。' '目标程序'))}
        if($controller.Count -and $row.HasSavedRule -and -not $row.Loaded){$findings.Add((New-NetworkDiagnosticFinding 'program-policy-unconfirmed' 'Retest' 'Program' '实际转发与保存线路尚未全部核验一致' '已见精确转发连接，但现有程序观察未确认保存策略的全部生效范围；可能仍有旧连接或出口读取未知。' '查看当前实际线路与程序详情；保存工作后正常重开或预览现有重连方案，再复试。' '目标程序'))}
        if(@($row.FamilyUnknownIds|Where-Object {$_}).Count -or (Test-ObservationFlag $row 'FamilyObservationTruncated' $false)){$findings.Add((New-NetworkDiagnosticFinding 'program-family-coverage-unknown' 'Retest' 'Program' '部分进程家族身份或范围未知' '仅已核验成员的连接可以归到此程序；不可读成员或有界观察之外的成员未被认领。' '在程序详情核对子程序范围，保持软件运行后重新排查；已核验的连接不能代表未知成员。' '目标程序'))}
        if($controller.Count){$findings.Add((New-NetworkDiagnosticFinding 'program-controller-connections' 'Passed' 'Program' '已观察到目标程序的转发连接' ('当前程序及已核验家族有 '+$controller.Count+' 条连接获得控制器精确对应；'+$(if($row.Loaded){'现有观察确认指定线路的生效范围。'}elseif(-not $row.HasSavedRule){'本轮仅确认这些连接的实际转发。'}else{'实际出口可见，但是否符合全部保存策略仍待核验。'})) '回目标软件完成真实请求；若仍失败，记录站点或账号错误，而不是仅重复改系统入口。' '目标程序'))}
        elseif($external.Count){$findings.Add((New-NetworkDiagnosticFinding 'program-tcp-only' 'Retest' 'Program' '已见 TCP，实际出口仍需确认' ('观察到 '+$external.Count+' 条外部或代理入口 TCP；未取得精确控制器出口证据，不能把入口外连接认定为物理直连。') '回目标软件复试并记录错误；必要时在原代理客户端核对对应连接。' '目标程序'))}
        else{$findings.Add((New-NetworkDiagnosticFinding 'program-no-external-connections' 'Retest' 'Program' '未观察到目标程序的外部连接' '软件可能空闲，或请求短暂、使用 UDP/QUIC、自有隧道；此快照不能证明断网。' '保持软件打开，发起一次失败请求，随后立即再次排查。' '目标程序'))}
        if($row.Pending -gt 0){$findings.Add((New-NetworkDiagnosticFinding 'program-pending' 'Retest' 'Program' '目标程序 TCP 正在建立' ('当前有 '+$row.Pending+' 条建立中的连接；单次快照不能证明永久失败。') '等待片刻后复试；持续失败时记录软件错误和发生时间。' '目标程序'))}
        if(@($external|Where-Object {$_.IngressKind -in @('Outside','UnknownLocal') -or $_.ActualRoute -in @('Unknown','Blocked')}).Count){$findings.Add((New-NetworkDiagnosticFinding 'program-partial-coverage' 'Retest' 'Program' '部分连接尚未确认接管' '可见连接仍有入口或出口未知部分；已确认的转发不能覆盖它们。' '核对子程序、自带代理与原客户端连接页，再发起真实请求复试。' '目标程序'))}
    }
    $checks=@();foreach($item in @(@('Settings','1. 程序检测范围'),@('Entry','2. 程序入口'),@('Route','3. 程序入口通路'))){$checks+=(Get-NetworkDiagnosticLayerCheck $item[0] $item[1] $findings)}
    $checks+=(Get-NetworkDiagnosticLayerCheck 'Program' '4. 目标程序实际连接' $findings)
    $policyName='未单独指定';if($row -and $row.HasSavedRule){$policyName=[string]$row.PolicyName;if(-not $policyName){$policyName=Get-RouteName $row.Policy};if(-not $policyName -or ($policyName -ceq [string]$row.Policy -and $row.Policy -notin @('Direct','Follow'))){$policyName='已保存线路（当前配置未识别）'}}
    $identityReason='';if($row -and $row.IdentityReason -in @('ExactPath','SameFile','PackageIdentity','PackageUpgradeCandidate','Ambiguous','MissingPath','PathUnavailable','NotRunning')){$identityReason=[string]$row.IdentityReason}
    $program=[pscustomobject]@{Path=$Path;SavedPath=$(if($row){[string]$row.SavedPath}else{''});ObservedPath=$(if($row){[string]$row.Path}else{''});Mode=$(if($row -and $row.Mode -in @('observe','managed','engine','launch')){[string]$row.Mode}else{'Unknown'});HasSavedRule=($row -and $row.HasSavedRule -eq $true);CanLaunch=$(if($row -and $row.PSObject.Properties['CanLaunch'] -and $row.CanLaunch -is [bool]){$row.CanLaunch}else{$null});NeedsRelaunch=$(if($row -and $row.PSObject.Properties['NeedsRelaunch'] -and $row.NeedsRelaunch -is [bool]){$row.NeedsRelaunch}else{$null});Name=$name;Running=$running;ProcessCount=$processIds.Count;ObservationState=$(if($row){$row.ObservationState}else{'Unknown'});Policy=$policyName;PolicyKey=$(if($row){$row.Policy}else{''});Actual=$(if($row){$row.Actual}else{'未知'});Coverage=$(if($row){$row.Coverage}else{'目标身份与连接范围未核验。'});RecordRequiresReview=($row -and [bool]$row.RequiresRepair);RecordCanRepair=($row -and [bool]$row.CanRepair);RecordIdentityReason=$identityReason;SavedPathMatchesObserved=$(if($row -and $row.SavedPath){$row.SavedPath -ieq $row.Path}else{$null});FamilyObservationTruncated=($row -and (Test-ObservationFlag $row 'FamilyObservationTruncated' $false));AuthenticationVerified=$false}
    $report=[pscustomobject]@{CheckedAt=[DateTimeOffset]::UtcNow.ToString('o');Program=$program;SystemDiagnosis=$system;TopologySummary=(ConvertTo-NetworkTopologySummary $(if($system){$system.TopologySummary}else{$null}));ProbeScope=$probeScope;ObservedProxyScope=$observedProxyScope;Targets=@($probeScope.Targets);Evidence=[pscustomobject]@{EstablishedCount=$external.Count;ControllerVerifiedCount=$controller.Count;PendingCount=$(if($row){[int]$row.Pending}else{0});ObservedAt=$(if($row){$row.ObservedAt}else{''});AuthenticationVerified=$false};RepairAction='';RepairScope='当前电脑；仅采用 SystemDiagnosis 中的现有确认方案';Message=''}
    Complete-NetworkDiagnosticSummary $report $findings $checks ('目标程序：'+$name+'；入口范围：'+$probeScope.EntrySource)
    $report.Message=$report.Summary+"`r`n`r`n程序观察："+$program.Actual+"`r`n覆盖范围："+$program.Coverage+"`r`n固定站点代测属于流向请求，不证明该程序采用相同入口；固定 OpenAI 域名旁证不推广为此程序的连接。"
    if($system){$report.Message+="`r`n`r`n独立系统详情（不并入程序结论）：`r`n"+$system.Message}
    $report
}
function Repair-NetworkDiagnosis([string]$Revision,[string]$ExpectedAction='') {
    if(-not $Revision){throw '请先排查网络，再修复。'}
    $result=Use-ChangeLock {
        $plan=Get-NetworkDiagnosis
        if($plan.Revision -cne $Revision){throw '网络配置已变化，未执行旧修复方案。请重新排查。'}
        if($ExpectedAction -and $plan.RepairAction -cne $ExpectedAction){throw '入口或守护状态已变化，修复动作与已确认计划不同；请重新排查。'}
        switch($plan.RepairAction){
            'repair-dead-entry'{Repair-DeadSystemEntry $Revision}
            'clear-dead-environment'{Repair-DeadProxyEnvironment $Revision}
            'recover-session'{
                Restore-IndependentSession -ExpectedSession $plan.ExpectedSession -AbandonedOnly
                if(Test-Path -LiteralPath (Get-IndependentSessionPath)){throw '旧会话恢复尚未完成，请重新排查。'}
                [pscustomobject]@{Message='旧会话已恢复并归档。';Backup=''}
            }
            'recover-stopped-service'{
                $session=Get-Content -LiteralPath (Get-IndependentSessionPath) -Raw -Encoding UTF8|ConvertFrom-Json
                if((Get-IndependentStoppedServiceState $session) -ne 'stopped'){throw '服务进程已恢复或身份未知，保留会话，请重新排查。'}
                Restore-IndependentSession -ExpectedSession $plan.ExpectedSession -GracefulOnly
                if(Test-Path -LiteralPath (Get-IndependentSessionPath)){throw '停止服务的会话恢复尚未完成，保留记录，请重新排查。'}
                [pscustomobject]@{Message='已恢复仍归属此会话的设置并归档停止服务的记录；其他软件当前入口保持原样。';Backup=''}
            }
            'align-environment'{
                Assert-NetworkRepairCurrent $Revision
                $before=Get-SystemSnapshot;$beforeEnv=Get-UserProxyEnv
                if(-not (Test-ProxyRoute $plan.SystemKey -Fast).Usable){throw '当前系统代理实际请求未通过，未修改用户变量。请先检查上游。'}
                if($Revision -cne (Get-NetworkRepairRevision (Get-SystemSnapshot) (Get-UserProxyEnv))){throw '检测期间配置已变化，未修改用户变量。'}
                $selection=Get-Selection
                $repairRevision=$Revision
                $verify={Assert-NetworkRepairCurrent $repairRevision;if(Test-Path -LiteralPath (Get-IndependentSessionPath)){throw '托管会话已变化，未修改变量。'}}.GetNewClosure()
                $backup=Invoke-ProxyTransaction $before (New-EnvTarget $beforeEnv $plan.SystemKey) $selection $before $beforeEnv -VerifyAction $verify -EnvironmentOnly
                [pscustomobject]@{Message='用户代理变量已对齐并通过实读校验，原设置已备份。';Backup=$backup}
            }
            default{throw '当前没有可自动处理的项目，请按诊断建议操作。'}
        }
    }
    # A follow-up observation failure must not misreport a completed repair.
    try{$after=Get-NetworkDiagnosis;$result.Message+="`r`n`r`n"+$after.Message;$result|Add-Member NoteProperty Diagnosis $after}
    catch{$result.Message+=' 修复后的诊断刷新失败，请重新点击排查网络；未把操作结果冒充完整联网验收。'}
    $result
}

# Shared passive, tri-state observation for all restoration paths.
function Get-RecoveryEndpointState([string]$Endpoint) {
    # Parsing first prevents TCP collection for remote, complex or credential-bearing values.
    if(-not (Get-LocalEndpointObservation $Endpoint ([pscustomobject]@{Available=$false;Rows=@()}))){return 'not-local'}
    try{
        $observed=Get-LocalEndpointObservation $Endpoint (Get-TcpObservationSnapshot)
        if($observed.Ready -eq $true){return 'live'}
        if($observed.Ready -eq $false){return 'dead'}
    }catch{}
    return 'unknown'
}

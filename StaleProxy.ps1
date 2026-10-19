# Explicit, bounded inspection only. Never included in passive application inventory.
. (Join-Path $PSScriptRoot 'ProcessProxyEnvironment.ps1')
. (Join-Path $PSScriptRoot 'ProgramFamilyTracking.ps1')
. (Join-Path $PSScriptRoot 'ProgramCleanStart.ps1')

function Test-StaleProxyExcludedPath([string]$Path,$IdentityContext=$null) {
    if(-not $Path){return $true}
    if(-not $IdentityContext){$IdentityContext=New-ProgramIdentityContext}
    $identity=Get-ProgramIdentityDescriptor $Path $IdentityContext
    foreach($candidate in @($Path,$identity.CanonicalPath)|Where-Object {$_}){
        if($candidate -match '(?i)\\steamapps\\|\\(EasyAntiCheat|BattlEye)\\' -or $candidate.StartsWith(($env:SystemRoot.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){return $true}
    }
    foreach($p in $script:Profiles.Profiles){
        if(($p.AppPath -and (Test-ProgramPathEquivalent $Path $p.AppPath $IdentityContext)) -or ($p.CorePath -and (Test-ProgramPathEquivalent $Path $p.CorePath $IdentityContext))){return $true}
    }
    return $false
}
function Test-StaleProxySupportedPath([string]$Path) {
    if(Test-StaleProxyExcludedPath $Path){return $false}
    return (Get-ProgramProxyAdapter $Path) -in @('chromium','environment')
}
function Test-StaleProxyExistingRoute([string]$Path,$Rules,$IdentityContext=$null) {
    if(-not $IdentityContext){$IdentityContext=New-ProgramIdentityContext}
    foreach($entry in @($Rules.entries)+@($Rules.programIngresses)+@($Rules.launchEntries)){
        if($entry.path -and (Test-ProgramPathEquivalent $Path $entry.path $IdentityContext)){return $true}
    }
    return $false
}
function Get-StaleProxyCurrentContext {
    $system=Get-SystemSnapshot
    $key=Get-SystemKey $system
    $endpoint=$null
    if(($system.Flags -band 2) -and $system.Server -match '^(127\.0\.0\.1|localhost|\[::1\]):([0-9]{1,5})$'){
        $endpoint=[pscustomobject]@{Host=$Matches[1].Trim('[',']');Port=[int]$Matches[2]}
    }
    [pscustomobject]@{Key=$key;Endpoint=$endpoint;Fingerprint=(Get-DailyProxyHash @($system,(Get-UserProxyEnv),(Read-ProfileSettings)))}
}
function ConvertTo-StaleProxyMember($Process,$Observation,$Tcp,$Current) {
    $entries=@();$state='Unknown';$label='无法读取';$detail='本轮没有足够证据；不会按失效代理处理。'
    foreach($v in @($Observation.Variables)){
        if($v.EndpointKind -ne 'Loopback' -or -not $v.Port -or -not $v.LoopbackHost){continue}
        $hostText=[string]$v.LoopbackHost;if($hostText -eq '::1'){$hostText='[::1]'}
        $address=$hostText+':'+[int]$v.Port
        $seen=Get-LocalEndpointObservation $address $Tcp
        $same=($Current.Endpoint -and $Current.Endpoint.Port -eq $v.Port -and $Current.Endpoint.Host -ieq $v.LoopbackHost)
        $addresses=if($v.LoopbackHost -ieq 'localhost'){@('127.0.0.1','::1')}else{@([string]$v.LoopbackHost)}
        $attempted=@($Tcp.Rows|Where-Object {$_.OwningProcess -eq $Process.Id -and $_.State -in @('Established','SynSent') -and $_.RemotePort -eq $v.Port -and $_.RemoteAddress -in $addresses}).Count -gt 0
        $entries+=[pscustomobject]@{Variable=$v.Name;Endpoint=$address;Listening=$(if($seen){$seen.Listening}else{$null});SameAsSystem=[bool]$same;ConnectionObserved=([bool]$Tcp.Available -and $attempted);HasCredentials=[bool]$v.HasCredentials}
    }
    if($Observation.State -eq 'Absent'){$state='Absent';$label='未设置代理变量';$detail='没有读到 HTTP / HTTPS / ALL_PROXY；程序仍可能使用系统代理或自身配置。'}
    elseif($Observation.State -eq 'Observed'){
        if(@($entries|Where-Object {$_.Listening -eq $false}).Count){$state='StaleLocal';$label='环境指向已停止入口';$detail='代理变量仍指向无监听的本机端口，可能影响后台请求。先保存工作并正常退出整组程序，再预览按当前系统代理启动。'}
        elseif(@($Observation.Variables|Where-Object {$_.State -eq 'Unknown'}).Count){$state='Unknown';$label='部分变量无法判断';$detail='复杂或不支持的代理值已隐藏；不要据此清理或替换程序设置。'}
        elseif(@($entries|Where-Object {$null -eq $_.Listening}).Count){$state='Unknown';$label='入口状态待确认';$detail='监听查询或地址族不明确；保留原程序和网络，稍后重新检查。'}
        elseif(@($Observation.Variables|Where-Object {$_.EndpointKind -eq 'External'}).Count){$state='Different';$label='存在外部代理配置';$detail='外部地址已隐藏；可能是程序专用配置，不能视为失效或自动覆盖。'}
        elseif(@($entries|Where-Object {-not $_.SameAsSystem}).Count){$state='Different';$label='与当前系统入口不同';$detail='该本机入口仍在监听，可能是有意保留的专线。先核对程序设置，不应直接清除。'}
        elseif($entries.Count){$state='Aligned';$label='环境与当前入口一致';$detail='代理环境地址一致；这不证明程序实际采用这些变量，也不替代登录、模型或真实请求验证。'}
        else{$state='Absent';$label='未设置代理变量';$detail='没有有效代理变量；系统代理和程序自身设置仍可能影响联网。'}
    }
    if($Observation.NoProxyBroadBypass -eq $true){$detail+=' NO_PROXY 含广泛绕过项；本功能不会自动删除。';if($state -eq 'Aligned'){$state='Bypass';$label='存在广泛绕过设置'}}
    [pscustomobject]@{PID=[int]$Process.Id;Name=[IO.Path]::GetFileName($Process.Path);State=$state;Label=$label;Detail=$detail;ReasonCode=[string]$Observation.ReasonCode;Entries=$entries;NoProxyBroadBypass=$Observation.NoProxyBroadBypass}
}
function Get-StaleProxyReport([string]$Path='',$Cancellation=$null) {
    $started=[DateTime]::UtcNow;$deadline=$started.AddSeconds(20)
    $current=Get-StaleProxyCurrentContext;$tcp=Get-TcpObservationSnapshot;$rules=Get-RoutingSnapshot
    $processes=@(Get-ProcessInventory);$context=New-ProgramIdentityContext -Processes $processes
    $roots=@{}
    if($Path){$roots[[IO.Path]::GetFullPath($Path)]=$true}
    else{
        foreach($p in $processes){if($p.Path -and $p.MainWindowHandle -ne [IntPtr]::Zero){$roots[$p.Path]=$true}}
        foreach($entry in @(Get-ProgramLaunchEntries)){if($entry.path){$roots[[string]$entry.path]=$true}}
    }
    $rows=@();$observations=@{};$inspected=0;$limited=$false;$rootCount=0
    foreach($root in @($roots.Keys|Sort-Object)){
        if($Cancellation -and $Cancellation.IsCancellationRequested){$limited=$true;break}
        if([DateTime]::UtcNow -gt $deadline -or $rootCount -ge 60){$limited=$true;break};$rootCount++
        $row=[pscustomobject]@{Name=[IO.Path]::GetFileNameWithoutExtension($root);Path=$root;State='Unknown';Label='未检查';Members=@();Detail='';CoverageLimited=$false;CanPrepareLaunch=$false;HasSavedRoute=(Test-StaleProxyExistingRoute $root $rules $context)}
        if(-not (Test-StaleProxySupportedPath $root)){
            $row.State='Unsupported';$row.Label='不在受限检查范围';$row.Detail='仅检查受支持的 Chromium/Electron 与显式环境适配程序；已识别游戏/反作弊目录、系统目录及已登记代理客户端不读取进程环境。可使用普通程序网络排查。';$rows+=$row;continue
        }
        $family=ConvertTo-ProgramObservationFamily (Get-ProgramFamilyTrackingSnapshot $root $processes $context)
        $row.CoverageLimited=(-not $family.Available -or @($family.UnknownIds).Count -gt 0 -or [bool]$family.ObservationTruncated)
        if(-not @($family.Members).Count){$row.State=$(if($row.CoverageLimited){'Unknown'}else{'Stopped'});$row.Label=$(if($row.CoverageLimited){'运行状态未知'}else{'当前未运行'});$row.Detail='只为已核验进程读取代理变量；未知不等于已退出。';$row.CanPrepareLaunch=(-not $row.CoverageLimited -and -not $row.HasSavedRoute);$rows+=$row;continue}
        foreach($member in @($family.Members)){
            if($inspected -ge 192 -or [DateTime]::UtcNow -gt $deadline -or ($Cancellation -and $Cancellation.IsCancellationRequested)){$row.CoverageLimited=$true;$limited=$true;break}
            if(-not $member.Path -or $member.StartTime -le [DateTime]::MinValue -or (Test-StaleProxyExcludedPath $member.Path $context)){$row.CoverageLimited=$true;continue}
            $observation=Get-ProcessProxyEnvironmentObservation -ProcessId $member.Id -ExpectedPath $member.Path -ExpectedCreationTicks ([DateTime]$member.StartTime).ToUniversalTime().Ticks
            $observations[[int]$member.Id]=[pscustomobject]@{Process=$member;Observation=$observation}
            $row.Members+=ConvertTo-StaleProxyMember $member $observation $tcp $current;$inspected++
        }
        foreach($priority in @('StaleLocal','Unknown','Different','Bypass','Aligned','Absent')){
            $hit=@($row.Members|Where-Object State -eq $priority|Select-Object -First 1)
            if($hit.Count){$row.State=$priority;$row.Label=$hit[0].Label;$row.Detail=$hit[0].Detail;break}
        }
        if($row.CoverageLimited){$row.Detail+=' 检查只覆盖已核验成员，其他后台状态未知。'}
        $row.CanPrepareLaunch=(-not $row.HasSavedRoute);$rows+=$row
    }
    # A long multi-program scan must not publish its opening TCP snapshot as current.
    $freshProcesses=@(Get-ProcessInventory);$freshTcp=Get-TcpObservationSnapshot
    foreach($row in $rows){
        $verified=@()
        foreach($previous in @($row.Members)){
            $held=$observations[[int]$previous.PID]
            $match=@($freshProcesses|Where-Object {$_.Id -eq $previous.PID -and $_.Path -ieq $held.Process.Path -and $_.StartTime -eq $held.Process.StartTime})
            if($match.Count -ne 1){$previous.State='Unknown';$previous.Label='进程状态已变化';$previous.ReasonCode='IdentityChanged';$previous.Entries=@();$previous.Detail='检测期间进程退出、重启或身份不明确，请重新检查。';$verified+=$previous;continue}
            $now=ConvertTo-StaleProxyMember $match[0] $held.Observation $freshTcp $current
            if((Get-DailyProxyHash @($previous.Entries|Select-Object Variable,Endpoint,Listening)) -cne (Get-DailyProxyHash @($now.Entries|Select-Object Variable,Endpoint,Listening))){$now.State='Unknown';$now.Label='入口状态已变化';$now.ReasonCode='EndpointChanged';$now.Detail='检查期间监听状态发生变化，请重新检查；本轮不判为失效。'}
            $verified+=$now
        }
        if($verified.Count){
            $row.Members=$verified
            foreach($priority in @('StaleLocal','Unknown','Different','Bypass','Aligned','Absent')){
                $hit=@($verified|Where-Object State -eq $priority|Select-Object -First 1);if($hit.Count){$row.State=$priority;$row.Label=$hit[0].Label;$row.Detail=$hit[0].Detail;break}
            }
            if($row.CoverageLimited){$row.Detail+=' 检查只覆盖已核验成员，其他后台状态未知。'}
        }
    }
    $changed=$current.Fingerprint -cne (Get-StaleProxyCurrentContext).Fingerprint
    if($changed){foreach($row in $rows){$row.State='Unknown';$row.Label='检查期间设置变化';$row.Detail='请重新检查，上一轮比较已失效。';$row.CanPrepareLaunch=$false}}
    [pscustomobject]@{CheckedAt=[DateTimeOffset]::Now.ToString('o');TargetPath=$Path;SystemKey=$current.Key;SystemEndpoint=$(if($current.Endpoint){$current.Endpoint.Host+':'+$current.Endpoint.Port}else{'非简单本机入口'});Rows=$rows;InspectedProcesses=$inspected;CoverageLimited=$limited;SettingsChanged=$changed;StaleCount=@($rows|Where-Object State -eq 'StaleLocal').Count;Scope='显式只读检查；仅提取代理白名单摘要，不输出或保存完整环境、账号及命令行。未读到变量不等于没有代理，环境与实际请求分别判断。'}
}
function Get-StaleProxyLaunchContext([string]$Path) {
    $path=Resolve-ProgramTarget $Path
    if(-not (Test-StaleProxySupportedPath $path)){throw '该程序不支持此启动修复；请使用原入口和普通网络排查。'}
    $identity=Get-ProgramIdentityDescriptor $path (New-ProgramIdentityContext)
    if(-not $identity.Exists -or -not $identity.FileId -or $identity.PathStatus -ne 'Available'){throw '程序文件身份无法核验，未准备启动。'}
    $ctx=Get-DailyProxyContext
    if(($ctx.System.Flags -band 12) -or $ctx.WindowsViews.WinHttpIE.AutoDetect -or $ctx.WindowsViews.WinHttpIE.HasPac -or $ctx.WindowsViews.Summary.Different){throw 'Windows 代理视图或自动代理尚未明确，请先在首页排查；本功能不修改系统设置。'}
    $key=Get-SystemKey $ctx.System
    if(-not (Test-DailyProxyWindowsTarget $ctx.System $ctx.WindowsViews $key)){throw '系统代理视图尚未一致，请先完成网络检查。'}
    $uri='';$endpointIdentity='Direct'
    if($key -ne 'Direct'){
        $profile=Get-Profile $key
        if($profile.Protocol -ne 'http' -or $profile.Host -notin @('127.0.0.1','localhost','::1')){throw '当前入口不是受支持的本机 HTTP 代理，未准备启动。'}
        $entry=Get-DailyProxyEndpoint $key
        if($entry.State -ne 'Ready'){throw '当前系统入口未就绪或归属不明确，请先恢复原代理客户端。'}
        $endpointIdentity=$entry.Identity;$uri='http://'+$(if($profile.Host -eq '::1'){'[::1]'}else{$profile.Host})+':'+$profile.Port
    }
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){
        $envKey=Get-EndpointKey $ctx.Environment.$name
        if($envKey -ne 'Unset' -and $envKey -ne $key){throw '当前用户代理变量与系统入口不一致，请先在首页查看修复方案。'}
    }
    if(Test-BroadProxyBypass ([string]$ctx.Environment.NO_PROXY)){throw '当前 NO_PROXY 含广泛绕过项，请先核对；本功能不会擅自删除。'}
    if(Test-StaleProxyExistingRoute $path $ctx.Rules){throw '该程序已有专用线路或启动适配，请在程序线路页核对，保存工作并完整退出后按原线路打开；此操作不会覆盖已有专线。'}
    $file=Get-Item -LiteralPath $path
    $binding=[pscustomobject]@{FileId=$identity.FileId;Path=$identity.CanonicalPath;Length=$file.Length;Modified=$file.LastWriteTimeUtc.Ticks;Context=$ctx;EndpointIdentity=$endpointIdentity}
    [pscustomobject]@{Path=$path;Key=$key;ProxyUri=$uri;NoProxy=[string]$ctx.Environment.NO_PROXY;Revision=(Get-DailyProxyHash $binding)}
}
function Get-StaleProxyLaunchPlan([string]$Path) {
    $context=Get-StaleProxyLaunchContext $Path
    $stopped=$true;$reason=''
    try{Assert-CleanProgramStopped $context.Path}catch{$stopped=$false;$reason='程序或相关后台仍在运行，或身份不能确认。请保存工作、正常完整退出后重新预览；流向不会结束任何现有进程。'}
    [pscustomobject]@{Version=1;Path=$context.Path;Revision=$context.Revision;CreatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();CanLaunch=$stopped;Reason=$reason;Target=$context.Key;Message='仅为这次新启动设置当前系统代理的 HTTP / HTTPS / ALL_PROXY，并采用当前用户的 NO_PROXY。保留程序账号和数据，不改系统、持久环境、快捷方式或专线。启动后仍需用真实请求确认。'}
}
function New-StaleProxyStartInfo($Context) {
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$Context.Path;$start.WorkingDirectory=[IO.Path]::GetDirectoryName($Context.Path);$start.UseShellExecute=$false
    foreach($name in @($start.EnvironmentVariables.Keys)){if([string]$name -match '^(?i:HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)$'){$start.EnvironmentVariables.Remove([string]$name)}}
    if($Context.ProxyUri){foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){$start.EnvironmentVariables[$name]=$Context.ProxyUri}}
    $bypass=@(([string]$Context.NoProxy -split ','|Where-Object {$_})+@('localhost','127.0.0.1','::1','[::1]')|Select-Object -Unique)
    $start.EnvironmentVariables['NO_PROXY']=$bypass -join ','
    if([string]$start.EnvironmentVariables['QTWEBENGINE_CHROMIUM_FLAGS'] -match '(?i)--proxy|--host-resolver'){throw '启动环境包含额外的专用网络参数，请先在原设置中核对。'}
    return $start
}
function Start-StaleProxyProgram($Plan,[switch]$Confirmed) {
    if(-not $Confirmed -or $Plan.Version -ne 1 -or $Plan.CanLaunch -ne $true){throw '请先在程序完整退出后预览并确认启动。'}
    $age=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-[long]$Plan.CreatedAt
    if($age -lt 0 -or $age -gt 120){throw '启动预览已过期，请重新预览。'}
    Use-ChangeLock {
        $current=Get-StaleProxyLaunchContext $Plan.Path
        if($current.Revision -cne $Plan.Revision){throw '程序、系统入口或设置已经变化，请重新预览。'}
        Assert-CleanProgramStopped $current.Path
        $start=New-StaleProxyStartInfo $current
        # Last stopped check immediately before launch; no stop/reconnect/global write exists here.
        Assert-CleanProgramStopped $current.Path
        $process=[Diagnostics.Process]::Start($start)
        if(-not $process){throw '系统未返回启动结果，请检查程序后再操作。'}
        try{$id=$process.Id}finally{$process.Dispose()}
        [pscustomobject]@{PID=$id;Message='已提交按当前系统代理启动。请检查程序头像、登录和实际请求，再重新检测；本功能没有修改其他程序或系统代理。'}
    }
}

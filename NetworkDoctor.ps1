# Whole-machine self-help. Passive reads only; the sole mutation is an explicitly confirmed GUI start.
function Get-NetworkDoctorFileIdentity([string]$Path) {
    $file=[LocalProxySwitch.ProgramFileIdentity]::Read($Path)
    $length=$null;$written=$null
    if($file.Status -eq 'Available' -and $file.FileId -and $file.CanonicalPath){
        $item=Get-Item -LiteralPath $file.CanonicalPath -ErrorAction Stop
        $length=$item.Length;$written=$item.LastWriteTimeUtc.Ticks.ToString()
    }
    [pscustomobject]@{Status=$file.Status;FileId=$file.FileId;CanonicalPath=$file.CanonicalPath;Length=$length;Written=$written}
}
function Get-NetworkDoctorRoamingDirectory {
    # Stable 2.5.8 uses dirs::data_dir(), i.e. Windows Roaming Known Folder.
    # Do not trust an inherited APPDATA override or guess development/custom roots.
    [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
}
function Get-NetworkDoctorClashConfigurationPath {
    $root=Get-NetworkDoctorRoamingDirectory
    if(-not $root -or -not [IO.Path]::IsPathRooted($root) -or $root.StartsWith('\\')){throw 'unavailable'}
    [IO.Path]::GetFullPath((Join-Path $root 'io.github.clash-verge-rev.clash-verge-rev\verge.yaml'))
}
function Read-NetworkDoctorClashStartupBytes([string]$Path) {
    if(-not $Path -or $Path.StartsWith('\\') -or (Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 1MB){throw 'unavailable'}
    $bytes=[IO.File]::ReadAllBytes($Path)
    if($bytes.Length -gt 1MB){throw 'unavailable'}
    return ,$bytes
}
function Get-NetworkDoctorClashStartupSnapshot {
    # Only the bound Known Folder path, safe scalars and full file hash may leave this function.
    # Conservative parsing refuses nonstandard/ambiguous YAML rather than guessing defaults.
    $result=[pscustomobject]@{Status='Unknown';Path='';Hash='';Tun=$null;Guard=$null;SystemProxy=$null;StartupScriptNull=$null}
    try{
        $result.Path=Get-NetworkDoctorClashConfigurationPath
        $bytes=Read-NetworkDoctorClashStartupBytes -Path $result.Path
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$result.Hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
        $text=(New-Object Text.UTF8Encoding($false,$true)).GetString($bytes).TrimStart([char]0xFEFF)
        if($text.IndexOf([char]0) -ge 0 -or $text -match '(?m)^(?:---|\.\.\.|<<\s*:|[\x22\x27?%&*!\[{]|\t)'){return $result}
        $lines=@($text -split '\r?\n');$values=@{}
        foreach($key in @('enable_tun_mode','enable_proxy_guard','enable_system_proxy','startup_script')){
            $indices=@(for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -cmatch ('^'+$key+'\s*:')){$i}})
            if($indices.Count -ne 1){return $result}
            $index=$indices[0]
            if($lines[$index] -cnotmatch ('^'+$key+'\s*:(?:[ \t]|$)')){return $result}
            $scalar=($lines[$index] -replace ('^'+$key+'\s*:\s*'),'')
            $nullScalar=($scalar -match '^(?:(?:null|~)(?:\s+#.*|\s*)|\s*(?:#.*)?)$')
            if($key -ne 'startup_script' -or $nullScalar){
                for($next=$index+1;$next -lt $lines.Count;$next++){
                    if($lines[$next] -match '^\s*(?:#.*)?$'){continue}
                    if($lines[$next] -match '^\s'){return $result};break
                }
            }
            if($key -eq 'startup_script'){
                # Empty scalar, null and ~ are YAML null; a non-null scalar/block is a custom script.
                $values[$key]=[bool]$nullScalar
            }else{
                if($scalar -cnotmatch '^(true|false)(?:\s+#.*|\s*)$'){return $result}
                $values[$key]=($Matches[1] -ceq 'true')
            }
        }
        $result.Tun=$values.enable_tun_mode;$result.Guard=$values.enable_proxy_guard;$result.SystemProxy=$values.enable_system_proxy;$result.StartupScriptNull=$values.startup_script;$result.Status='Available'
    }catch{} # Never expose raw configuration, startup scripts or exception details.
    $result
}
function Get-NetworkDoctorClientVersionMetadata([string]$Path) {
    $result=[pscustomobject]@{Status='Unknown';ProductName='';CompanyName='';FileVersion='';ProductVersion=''}
    try{
        $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $result.ProductName=[string]$version.ProductName;$result.CompanyName=[string]$version.CompanyName
        $result.FileVersion=[string]$version.FileVersion;$result.ProductVersion=[string]$version.ProductVersion;$result.Status='Available'
    }catch{}
    $result
}
function Get-NetworkDoctorClientBuild([string]$Path) {
    $result=[pscustomobject]@{Status='Unknown';ProductName='';CompanyName='';FileVersion='';ProductVersion='';SHA256=''}
    $stream=$null;$sha=$null
    try{
        $before=Get-NetworkDoctorFileIdentity $Path
        if($before.Status -ne 'Available' -or -not $before.FileId -or -not $before.CanonicalPath){return $result}
        $metadata=Get-NetworkDoctorClientVersionMetadata $before.CanonicalPath
        if($metadata.Status -ne 'Available'){return $result}
        # A read-only handle refuses concurrent writes/deletes while hashing; cap all input.
        $stream=[IO.File]::Open($before.CanonicalPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $length=$stream.Length
        if($length -gt 64MB){return $result}
        $sha=[Security.Cryptography.SHA256]::Create()
        $digest=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')
        $afterMetadata=Get-NetworkDoctorClientVersionMetadata $before.CanonicalPath
        $after=Get-NetworkDoctorFileIdentity $Path
        if($stream.Length -ne $length -or (Get-DailyProxyHash $before) -cne (Get-DailyProxyHash $after) -or (Get-DailyProxyHash $metadata) -cne (Get-DailyProxyHash $afterMetadata)){return $result}
        $result.ProductName=$metadata.ProductName;$result.CompanyName=$metadata.CompanyName
        $result.FileVersion=$metadata.FileVersion;$result.ProductVersion=$metadata.ProductVersion;$result.SHA256=$digest;$result.Status='Available'
    }catch{}finally{if($sha){$sha.Dispose()};if($stream){$stream.Dispose()}}
    $result
}
function Resolve-NetworkDoctorEndpoint([string]$Value,$Settings) {
    if(-not $Value){return 'Unset'}
    try{
        $text=$Value;if($text -notmatch '^[a-z]+://'){$text='http://'+$text}
        $uri=[uri]$text
        if($uri.Scheme -ne 'http' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -notin @('','/')){return 'Unknown'}
        $hostName=$uri.Host.Trim('[',']')
        # IPv6 and IPv4 are not interchangeable evidence. localhost may alias either family.
        $hits=@($Settings.Profiles|Where-Object {$_.Protocol -eq 'http' -and [int]$_.Port -eq $uri.Port -and ($_.Host -ieq $hostName -or ($hostName -in @('127.0.0.1','::1','localhost') -and $_.Host -eq 'localhost') -or ($hostName -eq 'localhost' -and $_.Host -in @('127.0.0.1','::1')))})
        if($hits.Count -eq 1){return [string]$hits[0].Id}
    }catch{}
    'Unknown'
}
function Get-NetworkDoctorRuntime($Settings,[string]$Key) {
    $candidates=@()
    foreach($profile in @($Settings.Profiles)){
        if(-not $profile.CorePath -or [IO.Path]::GetFileName($profile.CorePath) -ine 'verge-mihomo.exe'){continue}
        $core=Get-NetworkDoctorFileIdentity $profile.CorePath
        $gui=Get-NetworkDoctorFileIdentity (Join-Path ([IO.Path]::GetDirectoryName($profile.CorePath)) 'clash-verge.exe')
        if($core.Status -ne 'Available' -or $gui.Status -ne 'Available' -or -not $core.FileId -or -not $gui.FileId -or -not $core.CanonicalPath -or -not $gui.CanonicalPath){continue}
        if([IO.Path]::GetFileName($core.CanonicalPath) -ine 'verge-mihomo.exe' -or [IO.Path]::GetFileName($gui.CanonicalPath) -ine 'clash-verge.exe' -or [IO.Path]::GetDirectoryName($core.CanonicalPath) -ine [IO.Path]::GetDirectoryName($gui.CanonicalPath)){continue}
        $candidates+=@([pscustomobject]@{Key=[string]$profile.Id;Core=$core;Gui=$gui})
    }
    $installations=@($candidates|Group-Object {$_.Gui.FileId+'|'+$_.Core.FileId})
    $chosen=@($candidates|Where-Object {$_.Key -ceq $Key})
    $candidate=if($installations.Count -eq 1 -and $chosen.Count -eq 1){$chosen[0]}else{$null}
    $build=if($candidate){Get-NetworkDoctorClientBuild $candidate.Gui.CanonicalPath}else{$null}
    # This exact installed build was independently checked to use the stable APP_ID.
    # The digest is a supported-build identity, not an Authenticode or reproducibility claim.
    $buildSupported=($build -and $build.Status -eq 'Available' -and $build.ProductName -ceq 'Clash Verge' -and $build.CompanyName -ceq 'Clash Verge Rev' -and $build.FileVersion -ceq '2.5.8' -and $build.ProductVersion -ceq '2.5.8' -and $build.SHA256 -ceq 'DC1D520954A2B44F8AD9C0801413A3A7303209681013084D6EC46893ABF3216A')
    $rows=@(Get-ProcessInventory|Where-Object {$_.ProcessName -in @('clash-verge','verge-mihomo','verge-mihomo-alpha','clash-verge-service','clash_verge_service')}|Sort-Object Id)
    $guiRows=@($rows|Where-Object {$_.ProcessName -eq 'clash-verge'})
    $coreRows=@($rows|Where-Object {$_.ProcessName -in @('verge-mihomo','verge-mihomo-alpha')})
    $unknown=$false
    foreach($row in @($guiRows)+@($coreRows)){
        if(-not $candidate -or -not $row.Path -or $row.StartTime -le [DateTime]::MinValue){$unknown=$true;continue}
        $identity=Get-NetworkDoctorFileIdentity $row.Path
        $expected=if($row.ProcessName -eq 'clash-verge'){$candidate.Gui}else{$candidate.Core}
        if($identity.Status -ne 'Available' -or $identity.FileId -cne $expected.FileId -or $identity.CanonicalPath -ine $expected.CanonicalPath){$unknown=$true}
    }
    [pscustomobject]@{Candidate=$candidate;Build=$build;BuildSupported=[bool]$buildSupported;GuiRunning=($guiRows.Count -gt 0);CoreRunning=($coreRows.Count -gt 0);ServiceRunning=(@($rows|Where-Object {$_.ProcessName -in @('clash-verge-service','clash_verge_service')}).Count -gt 0);Unknown=$unknown;Processes=@($rows|ForEach-Object {[pscustomobject]@{Id=$_.Id;Name=$_.ProcessName;Path=$_.Path;Start=[string]$_.StartTime.ToUniversalTime().Ticks}})}
}
function Get-NetworkDoctorSnapshot {
    $context=Get-DailyProxyContext
    $settings=$context.Settings
    $systemKey=if($context.System.Flags -band 12){'Unknown'}elseif($context.System.Flags -band 2){Resolve-NetworkDoctorEndpoint $context.System.Server $settings}else{'Direct'}
    $environment=@(foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){Resolve-NetworkDoctorEndpoint $context.Environment.$name $settings})
    $target=''
    if($systemKey -notin @('Unknown','Direct','Unset','')){$target=$systemKey}
    elseif($systemKey -eq 'Direct' -and @($environment|Select-Object -Unique).Count -eq 1 -and $environment[0] -notin @('Unknown','Unset','')){
        $candidate=@($settings.Profiles|Where-Object {$_.Id -ceq $environment[0] -and $_.CorePath -and [IO.Path]::GetFileName($_.CorePath) -ieq 'verge-mihomo.exe'})
        if($candidate.Count -eq 1){$target=$environment[0]}
    }
    $endpoint=if($target){Get-DailyProxyEndpoint $target}else{$null}
    $runtime=Get-NetworkDoctorRuntime $settings $target
    $startup=if($runtime.BuildSupported){Get-NetworkDoctorClashStartupSnapshot}else{[pscustomobject]@{Status='Unknown';Path='';Hash='';Tun=$null;Guard=$null;SystemProxy=$null;StartupScriptNull=$null}}
    [pscustomobject]@{Context=$context;SystemKey=$systemKey;EnvironmentKeys=$environment;TargetKey=$target;Endpoint=$endpoint;Runtime=$runtime;ClashStartup=$startup}
}
function Get-NetworkDoctorBlock($Snapshot) {
    $c=$Snapshot.Context
    if($c.Settings.Routing.Adapter -ne 'none' -or $script:Profiles.Routing.Adapter -ne 'none' -or $c.Files.'gateway-session.json' -ne '<missing>'){return [pscustomobject]@{State='Advanced';Message='当前使用高级分流或存在入口会话，请在高级功能核对；自助排查不会改变程序专线或接管方式。'}}
    if($c.Client.Tun -or $c.Client.Guard -or ($c.System.Flags -band 12) -or $c.WindowsViews.WinHttpIE.AutoDetect -or $c.WindowsViews.WinHttpIE.HasPac){return [pscustomobject]@{State='Advanced';Message='存在 TUN、代理守卫或自动代理，请先在原客户端或 Windows 设置核对；流向不会代改。'}}
    if(-not $c.WindowsViews.Registry.Available -or -not $c.WindowsViews.WinHttpIE.Available -or (Get-DailyProxyHash $c.Settings) -cne (Get-DailyProxyHash $script:Profiles)){
        return [pscustomobject]@{State='Unavailable';Message='设置、网络拓扑或配置读取不完整，请刷新或到原客户端核对；未知状态不会自动修复。'}
    }
    $null
}
function Get-NetworkDoctorReport([switch]$Probe) {
    $report=[pscustomobject]@{Kind='NetworkDoctor';CheckedAt=[DateTimeOffset]::UtcNow.ToString('o');State='Unavailable';Headline='暂时无法完成网络排查';Message='只读信息收集未完成，请刷新后重试或打开原客户端检查。';Steps=@('保留现有程序，打开代理客户端检查连接状态。');Checks=@();TargetKey='';CanStartClient=$false;CanApplyProxy=$false;CanProbe=$false;ClientPath='';Probe=$null}
    try{
        $s=Get-NetworkDoctorSnapshot;$block=Get-NetworkDoctorBlock $s
        $targetDisagreement=($s.TargetKey -and $s.SystemKey -eq $s.TargetKey -and @($s.EnvironmentKeys|Where-Object {$_ -notin @('Unset','Unknown',$s.TargetKey)}).Count -gt 0)
        $report.TargetKey=$s.TargetKey
        if($s.Runtime.Candidate){$report.ClientPath=$s.Runtime.Candidate.Gui.CanonicalPath}
        $report.Checks=@([pscustomobject]@{Name='WindowsProxy';State=$s.SystemKey;Detail='读取 Windows 当前入口，不代表已有程序采用它。'},[pscustomobject]@{Name='ProxyEndpoint';State=$(if($s.Endpoint){$s.Endpoint.State}else{'Unknown'});Detail='监听与归属证据，不等同实际转发或账号登录。'},[pscustomobject]@{Name='ClashClient';State=$(if($s.Runtime.GuiRunning){'Running'}else{'Stopped'});Detail='仅检查客户端进程。'},[pscustomobject]@{Name='ClashCore';State=$(if($s.Endpoint.State -eq 'Ready' -and $s.Runtime.Candidate){'VerifiedEndpoint'}elseif($s.Runtime.Unknown){'Unknown'}elseif($s.Runtime.CoreRunning){'Running'}else{'Stopped'});Detail='服务存在不能代替代理核心和监听。'})
        if($targetDisagreement){$report.State='SettingsMismatch';$report.Message='Windows 系统代理与用户代理变量指向不同的已登记目标，无法把整机异常归因于某个客户端。请回首页明确选择本次要使用的代理并预览确认；流向不会自动切换，也不会据此判定 Clash 故障。'}
        elseif(-not $s.TargetKey -or 'Unknown' -in $s.EnvironmentKeys){$report.State='PortUnknown';$report.Message='当前入口未登记、存在歧义或无法确认目标。请先在代理入口核对原客户端；Windows 显示直连不代表应用没有残留代理。'}
        elseif($s.Endpoint.State -eq 'Unknown' -or $s.Endpoint.State -eq 'Unsupported'){$report.State='PortUnknown';$report.Message='入口监听归属或地址族无法核验，保留当前设置，请在原客户端核对。'}
        elseif($s.Endpoint.State -eq 'Stopped'){
            if($s.Runtime.Unknown){$report.State='PortUnknown';$report.Message='客户端或核心进程身份未知，不能按已停止处理。'}
            elseif($s.Runtime.Candidate -and -not $s.Runtime.CoreRunning){
                if($s.Runtime.GuiRunning){$report.State='CoreStopped';$report.Message='Clash 界面仍在运行，但代理核心和所登记入口未运行。请打开已有客户端检查核心、订阅或连接状态；仅有服务进程不足以联网。'}
                else{$report.State='ClientStopped';$report.Message='当前设置仍指向已登记的 Clash 入口，但客户端及代理核心未运行。启动前需要核验客户端配置；服务进程存在也不能替代核心。'}
            }else{$report.State='EndpointStopped';$report.Message='所登记入口未监听。请在原客户端连接或核对端口，流向不会自动更换入口。'}
        }
        elseif($block){$report.State=$block.State;$report.Message=$block.Message}
        elseif($s.Endpoint.State -eq 'Ready'){
            $effective=Test-DailyProxyEffectiveTarget $s.Context $s.TargetKey
            if($effective){$report.State='Healthy';$report.Message='当前代理入口监听及身份可核验，设置一致，无需重复应用。尚未发送 HTTP 请求，不能据此确认实际转发、网站或登录正常。'}
            else{
                $report.State='SettingsMismatch';$report.Message='入口已就绪，但 Windows 代理视图或用户代理变量不一致。可预览现有日常切换；已有程序需要自行保存工作后正常重开。'
                $plan=Get-DailyProxyPlan $s.TargetKey;$report.CanApplyProxy=($plan.CanApply -and -not $plan.NoChange)
            }
        }else{$report.State='PortUnknown';$report.Message='入口状态未知，保留当前设置。'}
        $topologyState=if($s.Context.Client.Topology.Available -and $s.Context.Client.Topology.State -in @('Evidence','NoEvidence')){$s.Context.Client.Topology.State}else{'Unknown'}
        foreach($family in @('IPv4','IPv6')){
            $familyState=if($s.Context.Client.Topology.$family -in @('Evidence','NoEvidence')){$s.Context.Client.Topology.$family}else{'Unknown'}
            $report.Checks+=@([pscustomobject]@{Name=('Topology'+$family);State=$familyState;Detail='当前地址族的路由证据独立核验；不证明所有请求或真实出口。'})
        }
        $report.Checks+=@([pscustomobject]@{Name='NetworkTopology';State=$topologyState;Detail='双栈路由为独立证据；未知不会被固定 HTTP 请求成功替代，未见证据不等于隧道已关闭。'},[pscustomobject]@{Name='WindowsViews';State=$(if($s.Context.WindowsViews.Registry.Available -and $s.Context.WindowsViews.WinHttpIE.Available){'Available'}else{'Unknown'});Detail='分层读取 Windows 当前用户代理视图。'},[pscustomobject]@{Name='Configuration';State=$(if((Get-DailyProxyHash $s.Context.Settings) -ceq (Get-DailyProxyHash $script:Profiles)){'Current'}else{'Changed'});Detail='配置身份须与当前加载的已登记目标一致。'},[pscustomobject]@{Name='EnvironmentProxy';State=$(if('Unknown' -in $s.EnvironmentKeys){'Unknown'}elseif($targetDisagreement){'Different'}else{'NoConflictingTarget'});Detail='用户变量与系统目标分层核对；已有程序可能仍保留启动时环境。'})
        # A bounded read-only probe of the unique current endpoint does not require
        # permission to start a client or write settings. Keep all topology/setting unknowns.
        $report.CanProbe=([bool]($s.TargetKey -and $s.Endpoint.State -eq 'Ready' -and (Get-DailyProxyHash $s.Context.Settings) -ceq (Get-DailyProxyHash $script:Profiles)))
        if($s.Runtime.Candidate){$report.Checks+=@([pscustomobject]@{Name='ClashStartupConfiguration';State=$s.ClashStartup.Status;Detail='核对客户端启动时的接管开关和启动脚本；启动前会再次检查。'})}
        if($report.State -eq 'ClientStopped'){
            $plan=Get-NetworkDoctorStartPlan $s.TargetKey;$report.CanStartClient=[bool]$plan.CanApply
            if(-not $plan.CanApply){$report.Message+=' 暂不提供启动：'+$plan.Message}
        }
        if($Probe -and $report.CanProbe){
            # Bind the entire read-only context and endpoint before and after the fixed probe.
            $before=Get-NetworkDoctorSnapshot
            if((Get-DailyProxyHash $s) -cne (Get-DailyProxyHash $before)){throw 'changed'}
            $result=Test-ProxyRoute $s.TargetKey -Fast
            $after=Get-NetworkDoctorSnapshot
            if((Get-DailyProxyHash $before) -cne (Get-DailyProxyHash $after)){throw 'changed'}
            $report.Probe=[pscustomobject]@{Attempted=$true;Usable=[bool]$result.Usable;Message='仅固定检测站点的本轮请求结果，不代表所有网站或账号可用。'}
            if(-not $result.Usable){$report.State='ProbeFailed';$report.CanApplyProxy=$false;$report.Message='代理入口存在，但固定请求检测未通过。请到原客户端检查节点与连接；本结果不能唯一归因于 VPN 或网络。'}
            else{$report.Message=$report.Message.Replace('尚未发送 HTTP 请求，不能据此确认实际转发、网站或登录正常。','')+' 本轮固定请求检测有成功结果，仍需核对实际网站和登录。'}
        }
        $headlines=@{Healthy='当前代理入口已就绪';ClientStopped='代理客户端未运行';CoreStopped='代理核心未运行';EndpointStopped='代理入口未监听';SettingsMismatch='代理设置需要核对';PortUnknown='代理目标或归属未知';Unavailable='信息读取不完整';Advanced='请在原客户端核对接管设置';ProbeFailed='请求检测未通过'}
        $report.Headline=$headlines[$report.State]
        $report.Steps=if($report.State -eq 'Healthy'){@('无需重新应用代理。','若实际网站异常，运行请求检测并到原客户端检查节点。')}elseif($report.State -eq 'ClientStopped' -and $report.CanStartClient){@('预览并确认启动 Clash 客户端；它可能自行接管系统代理。','启动后重新检查；客户端就绪后才考虑预览恢复系统代理。')}else{@($report.Message,'保留程序专线；需要备用代理时，先在原客户端连接并核对其入口。')}
        if($topologyState -eq 'Unknown' -or @($s.Context.Client.Topology.IPv4,$s.Context.Client.Topology.IPv6|Where-Object {$_ -notin @('Evidence','NoEvidence')}).Count){$report.Steps+=@('双栈路由证据仍有未知项；没有确认其他 VPN 或隧道关闭，固定请求成功也不能替代这项核验。')}
    }catch{
        if($Probe){$report.State='ProbeFailed';$report.Headline='检测期间信息变化或请求未完成';$report.Message='未确认本轮检测结果，请刷新后重新检测；保留当前设置。'}
        $report.CanApplyProxy=$false;$report.CanStartClient=$false;$report.CanProbe=$false
    }
    $report
}
function Get-NetworkDoctorStartPlan([string]$Key) {
    $plan=[pscustomobject]@{Kind='NetworkDoctorStart';CreatedAt=[DateTimeOffset]::UtcNow.ToString('o');Revision='';CanApply=$false;Message='无法核验客户端启动条件，请刷新或在原客户端检查。';ClientPath='';Key=$Key;Context=$null}
    try{
        $s=Get-NetworkDoctorSnapshot;$plan.Context=$s;$block=Get-NetworkDoctorBlock $s
        if($block){$plan.Message=$block.Message}
        elseif(-not $Key -or $s.TargetKey -cne $Key -or -not $s.Runtime.Candidate){$plan.Message='当前目标不是唯一可核验的已登记 Clash 安装；请按当前检测结果在原客户端核对。'}
        elseif(-not $s.Runtime.BuildSupported){$plan.Message='当前 Clash 构建或配置位置规则尚未核验，仅支持已确认文件摘要的稳定版 2.5.8 启动。开发版、自定义或其他文件摘要的构建可继续诊断，但流向不会猜测其配置位置或启动它。'}
        elseif($s.SystemKey -notin @('Direct',$Key) -or @($s.EnvironmentKeys|Where-Object {$_ -notin @('Unset',$Key)}).Count){$plan.Message='当前系统或用户代理指向其他目标，不能通过启动 Clash 争抢设置。'}
        elseif($s.ClashStartup.Status -ne 'Available'){$plan.Message='Clash 启动配置读取或格式未知，无法核验 TUN、代理守卫及启动脚本；请先在原客户端核对，暂不启动。'}
        elseif($s.ClashStartup.Tun -or $s.ClashStartup.Guard){$plan.Message='Clash 保存的启动配置启用了 TUN 或代理守卫；即使界面未运行，启动也可能接管网络。请在原客户端核对并处理后重新预览，流向不会代改。'}
        elseif(-not $s.ClashStartup.StartupScriptNull){$plan.Message='Clash 配置存在自定义 startup_script，无法界定启动副作用；请在原客户端核对，流向不会执行或修改它。'}
        elseif($s.Runtime.GuiRunning){$plan.Message='Clash 界面已经运行，请打开已有客户端检查；不会重复启动或重启。'}
        elseif($s.Runtime.Unknown -or $s.Runtime.CoreRunning -or $s.Endpoint.State -ne 'Stopped'){$plan.Message='核心仍在运行、入口已就绪或进程归属未知，不能自动启动；请打开原客户端检查。'}
        else{
            $plan.CanApply=$true;$plan.ClientPath=$s.Runtime.Candidate.Gui.CanonicalPath
            $plan.Message='已核验 Clash 保存的 TUN、代理守卫关闭且无自定义启动脚本。仅启动一次客户端；Clash 启动后可能自行接管系统代理，流向不会回写争抢，不改程序专线、不启动核心服务命令、不重启现有程序。其他 VPN 或双栈路由状态仍可能未知，启动成功后需重新检测。'
        }
        $plan.Revision=Get-DailyProxyHash ([pscustomobject]@{Kind=$plan.Kind;Key=$Key;Snapshot=$s;ClientPath=$plan.ClientPath})
    }catch{}
    $plan
}
function Start-NetworkDoctorClient($Plan,[switch]$Confirmed) {
    if(-not $Confirmed){throw '请先预览并明确确认启动客户端。'}
    $created=[DateTimeOffset]::MinValue
    if(-not $Plan -or $Plan.Kind -cne 'NetworkDoctorStart' -or -not [DateTimeOffset]::TryParse([string]$Plan.CreatedAt,[ref]$created)){throw '客户端启动预览无效，请重新预览。'}
    $age=([DateTimeOffset]::UtcNow-$created).TotalSeconds
    if($age -lt -5 -or $age -gt 120){throw '客户端启动预览已过期，请重新预览。'}
    try{Use-ChangeLock {
        $lockedAge=([DateTimeOffset]::UtcNow-$created).TotalSeconds
        if($lockedAge -lt -5 -or $lockedAge -gt 120){throw '客户端启动预览已过期，请重新预览。'}
        $fresh=Get-NetworkDoctorStartPlan $Plan.Key
        if(-not $Plan.CanApply -or -not $fresh.CanApply){throw '当前条件不允许启动客户端，请刷新并打开原客户端核对。'}
        if(-not $Plan.Revision -or $fresh.Revision -cne $Plan.Revision -or $fresh.ClientPath -ine $Plan.ClientPath){throw '预览后系统、用户变量、配置、文件或进程状态已变化，请重新预览。'}
        # Consume before launching: even a launch exception must not permit blindly retrying this plan.
        # UI actions run in separate runspaces. Keep launch claims in this app domain,
        # under the existing change lock, so a serialized plan cannot start twice.
        $claimName='LocalProxySwitch.NetworkDoctor.LaunchClaims.v1'
        $claims=[AppDomain]::CurrentDomain.GetData($claimName)
        if($null -eq $claims){$claims=New-Object 'Collections.Generic.HashSet[string]';[AppDomain]::CurrentDomain.SetData($claimName,$claims)}
        $token=([string]$Plan.CreatedAt)+'|'+$Plan.Revision
        if(-not $claims.Add($token)){throw '本次启动计划已使用，请重新检查客户端状态。'}
        try{$process=Start-Process -FilePath $fresh.ClientPath -WorkingDirectory ([IO.Path]::GetDirectoryName($fresh.ClientPath)) -WindowStyle Hidden -PassThru -ErrorAction Stop}
        catch{throw '客户端启动请求未能完成；请先检查客户端是否已打开，再重新排查。'}
        if($process){try{$process.Dispose()}catch{}}
        [pscustomobject]@{Started=$true;Key=$fresh.Key;Message='已提交一次客户端启动请求。尚未确认界面、核心或网络恢复，请等待客户端连接后重新检测。'}
    }}catch{
        $safe=@('客户端启动预览已过期，请重新预览。','当前条件不允许启动客户端，请刷新并打开原客户端核对。','预览后系统、用户变量、配置、文件或进程状态已变化，请重新预览。','本次启动计划已使用，请重新检查客户端状态。','客户端启动请求未能完成；请先检查客户端是否已打开，再重新排查。','另一个切换器正在修改代理，请稍后重试。')
        if($_.Exception.Message -cin $safe){throw $_.Exception.Message}
        throw '客户端启动核验未完成，请刷新后重新预览；未确认网络恢复。'
    }
}

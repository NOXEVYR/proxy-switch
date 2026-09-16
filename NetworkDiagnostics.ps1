# Read-only diagnosis; all repairs require an explicit action and a fresh revision.
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
function Get-NetworkRepairRevision($System,$Environment) {
    $parts=@(($System|ConvertTo-Json -Compress),($Environment|ConvertTo-Json -Compress))
    foreach($path in @((Get-IndependentSessionPath),$script:ConfigPath,(Join-Path $script:DataRoot 'app-rules.json'),(Join-Path $script:DataRoot 'program-proxies.json'),(Join-Path $script:DataRoot 'selection.json'))){
        $parts+= $(if(Test-Path -LiteralPath $path){[IO.File]::ReadAllText($path)}else{'<missing>'})
    }
    $hash=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts|ConvertTo-Json -Compress))))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Test-NetworkTargets($Profile) {
    $probes=@();$results=@()
    try{
        foreach($target in @(@('GitHub','https://github.com/'),@('OpenAI API','https://api.openai.com/'))){
            try{$probes+=[pscustomobject]@{Name=$target[0];Probe=(Start-HttpEndpointProbe $Profile $target[1] $true)}}
            catch{$results+=[pscustomobject]@{Name=$target[0];Stage='probe-unavailable';HttpCode=0;AuthenticationVerified=$false}}
        }
        foreach($item in $probes){
            $code=0;$connect=0;$stage='proxy-or-target-unreachable';$probe=$item.Probe
            if($probe.Process.WaitForExit(8000)){
                $parts=$probe.Output.Result.Trim() -split '\s+'
                if($parts.Count -ge 3){[void][int]::TryParse($parts[0],[ref]$code);[void][int]::TryParse($parts[2],[ref]$connect)}
                $handshake=($Profile.Protocol -eq 'http' -and $connect -eq 200) -or ($Profile.Protocol -eq 'socks5' -and $code -gt 0)
                if($handshake -and $probe.Process.ExitCode -eq 0 -and $code -ge 100){$stage='https-response'}
                elseif($connect -eq 200){$stage='target-tls-or-timeout'}
            }
            $results+=[pscustomobject]@{Name=$item.Name;Stage=$stage;HttpCode=$code;AuthenticationVerified=$false}
        }
    }finally{foreach($item in $probes){Close-HttpEndpointProbe $item.Probe}}
    @($results)
}
# Only simple loopback endpoints are eligible; PAC, remote and per-protocol lists stay unknown.
function Get-LocalEndpointObservation([string]$Value,$Tcp) {
    if($Value -notmatch '^(?:(?:http|https|socks5|socks5h)://)?(127\.0\.0\.1|localhost|\[::1\]):([0-9]{1,5})/?$'){return $null}
    $port=[int]$Matches[2];if($port -lt 1 -or $port -gt 65535){return $null}
    $profile=[pscustomobject]@{Host=$Matches[1].Trim('[',']');Port=$port;CorePath=''}
    $ready=$null;if($Tcp.Available){$ready=$null -ne (Get-Listener $profile -TcpRows $Tcp.Rows)}
    [pscustomobject]@{Port=$port;Ready=$ready}
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
        if($usable){return Enable-IndependentGateway -OwnerPID $PID -InitialRoute $key -RepairEntry -RepairRevision $Revision}
    }
    Assert-NetworkRepairCurrent $Revision
    $fresh=Get-TcpObservationSnapshot;$current=Get-LocalEndpointObservation $before.Server $fresh
    if(-not $fresh.Available -or -not $current -or $current.Ready -ne $false){throw '入口已恢复或监听状态未知，未清除设置。请重新排查。'}
    $targetEnv=[ordered]@{}
    foreach($name in $script:ProxyNames){
        $targetEnv[$name]=$beforeEnv.$name
        if($name -ne 'NO_PROXY'){$observed=Get-LocalEndpointObservation ([string]$beforeEnv.$name) $fresh;if($observed -and $observed.Ready -eq $false){$targetEnv[$name]=$null}}
    }
    # Preserve PAC/autodetect flags and bypass; disable only the proven dead manual proxy.
    $target=[pscustomobject]@{Flags=(($before.Flags -band (-bnot 2)) -bor 1);Server='';Bypass=$before.Bypass}
    $verify={Assert-NetworkRepairCurrent $Revision;$seen=Get-LocalEndpointObservation $before.Server (Get-TcpObservationSnapshot);if(-not $seen -or $seen.Ready -ne $false){throw '入口状态已变化，未执行清理。'}}.GetNewClosure()
    $backup=Invoke-ProxyTransaction $target ([pscustomobject]$targetEnv) (Get-Selection) $before $beforeEnv -VerifyAction $verify -PreserveSelection
    [pscustomobject]@{Message='未检测到可用备用代理。已备份并撤销失效的手动系统代理，清除确认失效的本地代理变量；保留其他变量、自动配置及程序规则。直连或现有自动配置是否能访问目标网站仍需验证，需要代理的网站仍需可用上游。';Backup=$backup}
}
function Get-NetworkDiagnosis([switch]$Probe) {
    $script:Profiles=Read-ProfileSettings
    $system=Get-SystemSnapshot;$environment=Get-UserProxyEnv
    $revision=Get-NetworkRepairRevision $system $environment
    $tcp=Get-TcpObservationSnapshot
    $issues=@();$endpoints=@();$action='';$repairText='';$sessionId='';$owner='none'
    foreach($profile in $script:Profiles.Profiles){
        $ready=$null
        if($tcp.Available -and $profile.Host -in @('127.0.0.1','localhost','::1')){$ready=$null -ne (Get-Listener $profile -TcpRows $tcp.Rows)}
        $endpoints+=[pscustomobject]@{Key=$profile.Id;Port=$profile.Port;Ready=$ready}
    }
    $systemKey=Get-SystemKey $system
    $systemReady=$null;$entry=$endpoints|Where-Object Key -eq $systemKey|Select-Object -First 1
    if($entry){$systemReady=$entry.Ready}
    $manual=$null;if($system.Flags -band 2){$manual=Get-LocalEndpointObservation $system.Server $tcp;if($manual){$systemReady=$manual.Ready}}
    $client=Get-ClientInterference
    if($client.Guard -or $client.Tun){$issues+=[pscustomobject]@{Code='external-proxy-control';Message='其他客户端的代理守护或 TUN 正在接管网络，会阻止流向独立接管。请先关闭冲突开关，保留上游代理服务；流向不会循环抢回入口。'}}
    if(-not $tcp.Available){$issues+=[pscustomobject]@{Code='observation-unknown';Message='无法读取连接列表，监听状态未知。稍后重新排查；不会据此清空代理。'}}
    if($systemReady -eq $false){$issues+=[pscustomobject]@{Code='system-entry-down';Message='系统代理指向未监听的入口。请在代理管理启动对应代理，或检测并选择其他可用线路。'}}
    if($systemKey -eq 'Direct'){$issues+=[pscustomobject]@{Code='system-direct';Message='系统当前直连。若目标网站需要代理，请选择并检测可用线路。'}}
    if($systemKey -eq 'Other'){$issues+=[pscustomobject]@{Code='system-unmanaged';Message='系统代理不在已配置列表中，无法验证其归属。请在代理管理核对并添加入口。'}}
    $mismatched=@();$dead=@()
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){
        $key=Get-EndpointKey $environment.$name
        if(($systemKey -ne 'Direct' -and $key -ne $systemKey) -or ($systemKey -eq 'Direct' -and $key -ne 'Unset')){$mismatched+=$name}
        $row=$endpoints|Where-Object Key -eq $key|Select-Object -First 1
        if($row -and $row.Ready -eq $false){$dead+=$name}
    }
    if($dead.Count){$issues+=[pscustomobject]@{Code='environment-entry-down';Message=(($dead -join '、')+' 指向未监听的入口，终端工具可能连接失败。')}}
    if($mismatched.Count){$issues+=[pscustomobject]@{Code='environment-mismatch';Message='系统代理与用户代理变量不一致，不同软件可能走不同入口。'}}
    $sessionPath=Get-IndependentSessionPath
    if(Test-Path -LiteralPath $sessionPath){
        try{
            $session=Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8|ConvertFrom-Json
            $owner=Get-RecoveryOwnerState $session;$sessionId=[string]$session.Started
            if($owner -eq 'alive' -and $session.TargetSystem -and -not (Test-SameSnapshot $system $session.TargetSystem)){$issues+=[pscustomobject]@{Code='system-entry-overridden';Message='系统入口已偏离流向托管入口；使用系统代理的新请求可能绕过流向。无法仅凭端口确认修改者。请处理外部守护，再明确重新应用线路。'}}
            if($owner -eq 'stopped' -and $sessionId){
                $issues+=[pscustomobject]@{Code='abandoned-session';Message='发现上次运行遗留的会话，原宿主已退出。旧保护记录不代表当前网关可用。'}
                $action='recover-session';$repairText='恢复仍属于旧会话的系统代理与用户变量，核验后停止旧会话内核并归档。保留其他工具或你后来改过的设置。'
            }elseif($owner -eq 'unknown'){$issues+=[pscustomobject]@{Code='session-unknown';Message='会话身份无法核实。保留记录，暂不停止进程或自动恢复。'}}
            elseif($owner -eq 'alive'){
                $gateway=$endpoints|Where-Object Key -eq (Get-GatewayKey)|Select-Object -First 1
                if($gateway -and $gateway.Ready -eq $false){$issues+=[pscustomobject]@{Code='gateway-down';Message='流向宿主仍在运行，但固定入口未监听。等待恢复；若持续失败，请停止服务后重新启用独立分流。'}}
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
    if(-not $action -and $owner -eq 'none' -and $mismatched.Count -and $systemReady -eq $true -and $systemKey -notin @('Direct','Other','Unset',(Get-GatewayKey)) -and (Get-Profile $systemKey).Protocol -eq 'http'){
        $action='align-environment';$repairText='先检测当前系统代理的实际请求；通过后备份并将用户代理变量对齐到这个入口。保留系统代理和程序分流规则。'
    }
    if(-not $action -and $owner -eq 'none' -and $manual -and $manual.Ready -eq $false -and -not ($client.Guard -or $client.Tun)){
        $action='repair-dead-entry';$repairText='检测已配置的备用代理，按备用顺序选择通过实际请求检测的线路，接入流向固定入口并保留程序与网站规则；若没有可用备用，则备份后撤销失效的手动系统代理，只清理确认失效的本地代理变量，保留有效变量、自动配置和规则。已有专用程序规则不会被改成统一线路；需要代理的网站不保证能直连。'
    }
    $targets=@()
    if($Probe -and $systemReady -eq $true -and $systemKey -in (Get-ProfileKeys)){$targets=@(Test-NetworkTargets (Get-Profile $systemKey))}
    if($revision -cne (Get-NetworkRepairRevision (Get-SystemSnapshot) (Get-UserProxyEnv))){throw '诊断期间配置发生变化，请重新排查。'}
    $report=[pscustomobject]@{Version=$script:ProductVersion;CheckedAt=[DateTimeOffset]::UtcNow.ToString('o');Issues=@($issues);Endpoints=@($endpoints);Targets=$targets;RepairAction=$action;RepairText=$repairText;Revision=$revision;ExpectedSession=$sessionId;SystemKey=$systemKey;OwnerState=$owner;Message=''}
    $lines=@('网络排查结果：')+@($issues|ForEach-Object {'• '+$_.Message})
    if(-not $issues.Count){$lines+='本地入口与设置未发现明显异常。请继续检测所选代理或目标站点，尚未验证登录和持续对话。'}
    foreach($target in $targets){
        if($target.Stage -eq 'https-response'){$lines+=($target.Name+'：已收到 HTTPS 响应 HTTP '+$target.HttpCode+'；不代表登录或持续对话成功。'+$(if($target.HttpCode -ge 400){' 目标返回错误响应，请检查访问限制或出口。'}))}
        else{$lines+=($target.Name+'：'+$(if($target.Stage -eq 'target-tls-or-timeout'){'代理隧道已建立，目标 TLS 或请求未完成。'}elseif($target.Stage -eq 'probe-unavailable'){'检测工具未能运行，结果未知。'}else{'代理握手或目标连接未完成，请检测当前代理或更换可用线路。'}))}
    }
    if($action){$lines+=('可处理：'+$repairText)}else{$lines+='当前没有可自动处理的项目，请按上面的建议操作。'}
    $lines+='已经运行的应用可能保留旧代理；修复后若仍断线，请保存工作并完整重开宿主应用。流向不会自动结束它们。'
    $report.Message=$lines -join "`r`n"
    $report
}
function Repair-NetworkDiagnosis([string]$Revision) {
    if(-not $Revision){throw '请先排查网络，再修复。'}
    $result=Use-ChangeLock {
        $plan=Get-NetworkDiagnosis
        if($plan.Revision -cne $Revision){throw '网络配置已变化，未执行旧修复方案。请重新排查。'}
        switch($plan.RepairAction){
            'repair-dead-entry'{Repair-DeadSystemEntry $Revision}
            'recover-session'{
                Restore-IndependentSession -ExpectedSession $plan.ExpectedSession -AbandonedOnly
                if(Test-Path -LiteralPath (Get-IndependentSessionPath)){throw '旧会话恢复尚未完成，请重新排查。'}
                [pscustomobject]@{Message='旧会话已恢复并归档。';Backup=''}
            }
            'align-environment'{
                $before=Get-SystemSnapshot;$beforeEnv=Get-UserProxyEnv
                if(-not (Test-ProxyRoute $plan.SystemKey -Fast).Usable){throw '当前系统代理实际请求未通过，未修改用户变量。请先检查上游。'}
                if($Revision -cne (Get-NetworkRepairRevision (Get-SystemSnapshot) (Get-UserProxyEnv))){throw '检测期间配置已变化，未修改用户变量。'}
                $selection=Get-Selection
                $backup=Invoke-ProxyTransaction $before (New-EnvTarget $beforeEnv $plan.SystemKey) $selection $before $beforeEnv -EnvironmentOnly
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

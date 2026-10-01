# Stable application entrances and domain policy. Writers are explicit user actions.
function Get-ManagedProgramIngress([string]$Executable) {
    (Get-RoutingSnapshot).programIngresses|Where-Object {$_.path -ieq $Executable}|Select-Object -First 1
}
function Get-ManagedIngressEndpoint($Entry) {'http://127.0.0.1:'+([int]$Entry.port)}
function Copy-RoutingSnapshot($Snapshot) {$Snapshot|ConvertTo-Json -Depth 16|ConvertFrom-Json}
function Assert-ManagedRoute([string]$Route,[switch]$AllowFollow) {
    $keys=@('Direct')+(Get-ProfileKeys);if($AllowFollow){$keys+=@('Follow')}
    if($Route -notin $keys -or ($Route -eq (Get-GatewayKey) -and $script:Profiles.Routing.Adapter -eq 'standalone')){throw '请选择有效上游、直连或跟随统一线路，不能把流向入口作为自己的出口。'}
}
function Ensure-ManagedGateway([string]$InitialRoute='',[switch]$PreserveWindowsSettings) {
    if($InitialRoute -eq 'Follow'){$InitialRoute=''}
    if($script:Profiles.Routing.Adapter -eq 'standalone' -and (Test-Path -LiteralPath (Get-IndependentSessionPath))){
        $session=Get-Content -LiteralPath (Get-IndependentSessionPath) -Raw -Encoding UTF8|ConvertFrom-Json
        $life=Get-GatewayLifecycle
        $owner=Get-RecoveryOwnerState $session
        $supervisor=Get-RecoveryOwnerState ([pscustomobject]@{OwnerPID=$session.SupervisorPID;OwnerStart=$session.SupervisorStart})
        if($owner -eq 'unknown' -or $supervisor -eq 'unknown'){throw '原代理会话身份未知，未恢复或替换正在使用的入口。请先在诊断中检查服务。'}
        if($owner -eq 'stopped' -or $supervisor -eq 'stopped' -or ($life.phase -in @('failed','stopped'))){
            # Only an explicit user action retries a fully stopped/exhausted service.
            # Restore owned settings and stop the verified old child before reusing ports.
            Restore-IndependentSession -ExpectedSession $session.Started
        }
    }
    if($script:Profiles.Routing.Adapter -ne 'standalone' -or -not (Test-Path -LiteralPath (Get-IndependentSessionPath))){
        if($InitialRoute){Assert-ManagedRoute $InitialRoute}
        Enable-IndependentGateway -OwnerPID $PID -InitialRoute $InitialRoute -PreserveWindowsSettings:$PreserveWindowsSettings | Out-Null
    }
    $deadline=[DateTime]::UtcNow.AddSeconds(12)
    do {
        $remaining=[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds
        if($remaining -le 0){break}
        # Controller reads can fail while the supervisor is still restoring its child.
        # Retry only observation, never duplicate a start or routing transaction.
        try{
            $live=Invoke-AppRouter @{action='status'} -TimeoutMilliseconds ([Math]::Min(2500,$remaining))
            if($live.available -and $live.rulesAvailable -and $live.defaultLoaded){return $live}
        }catch{}
        Start-Sleep -Milliseconds 200
    }while([DateTime]::UtcNow -lt $deadline)
    throw '流向入口尚未就绪，未启动目标程序。请打开流向查看服务状态，或停止服务后重新启动。'
}
function Test-ManagedLaunchCancelled($Cancellation) {
    $null -ne $Cancellation -and $Cancellation.IsCancellationRequested
}
function Test-ManagedWebsiteMatch([string]$HostName,$Rule) {
    $HostName -ceq $Rule.domain -or ($Rule.type -ceq 'suffix' -and $HostName.EndsWith('.'+$Rule.domain,[StringComparison]::Ordinal))
}
function Test-ManagedDirectWebsiteSpace($Live,[string]$IngressId) {
    if($Live.siteRulesLoaded -ne $true){return $false}
    # Mirror RoutePolicy.orderedSiteRules / connectionPolicy: program scope first,
    # domain depth descending, exact before suffix at equal depth, then input order.
    $rules=@();$index=0
    foreach($rule in @($Live.siteRules)){
        if($rule.scope -cne 'global' -and $rule.scope -cne $IngressId){continue}
        if($rule.loaded -ne $true){continue}
        if($rule.type -cnotin @('domain','suffix') -or -not $rule.domain){return $false}
        try{$domain=ConvertTo-WebsiteDomain $rule.domain}catch{return $false}
        $rules+=@([pscustomobject]@{scope=$rule.scope;type=$rule.type;domain=$domain;route=$rule.route;
            Rank=$(if($rule.scope -ceq $IngressId){0}else{1});Depth=($domain.Split('.').Length);
            Exact=$(if($rule.type -ceq 'domain'){0}else{1});Index=$index});$index++
    }
    $ordered=@($rules|Sort-Object Rank,@{Expression='Depth';Descending=$true},Exact,Index)
    for($i=0;$i -lt $ordered.Count;$i++){
        $direct=$ordered[$i];if($direct.route -cne 'Direct'){continue}
        $covered=$false
        for($j=0;$j -lt $i;$j++){
            if(Test-ManagedWebsiteMatch $direct.domain $ordered[$j]){
                if($direct.type -ceq 'domain' -or $ordered[$j].type -ceq 'suffix'){$covered=$true;break}
            }
        }
        if($covered){continue}
        # An exact rule covering only the suffix's main domain leaves child domains.
        # A child with no preceding equal-domain rule cannot match any preceding
        # deeper rule; preceding ancestor suffix rules were excluded above.
        $baseCovered=$false
        for($j=0;$j -lt $i;$j++){if(Test-ManagedWebsiteMatch $direct.domain $ordered[$j]){$baseCovered=$true;break}}
        if(-not $baseCovered){return $true}
        if($direct.type -ceq 'domain'){continue}
        $labelLimit=[Math]::Min(63,252-$direct.domain.Length);if($labelLimit -lt 1){continue}
        $excluded=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $tail='.'+$direct.domain
        for($j=0;$j -lt $i;$j++){
            $other=$ordered[$j].domain
            if($other.EndsWith($tail,[StringComparison]::Ordinal)){
                $label=$other.Substring(0,$other.Length-$tail.Length)
                if($label.IndexOf('.') -lt 0){[void]$excluded.Add($label)}
            }
        }
        # At most N rules exclude N one-label children. N+1 distinct short labels
        # suffice; when only one character fits, exhaust all 36 valid characters.
        $alphabet='0123456789abcdefghijklmnopqrstuvwxyz'
        for($n=0;$n -le $excluded.Count;$n++){
            $value=$n;$label=''
            do{$label=([string]$alphabet[($value%36)])+$label;$value=[int][Math]::Floor($value/36)}while($value -gt 0)
            if($label.Length -gt $labelLimit){break}
            if(-not $excluded.Contains($label)){return $true}
        }
    }
    return $false
}
function Invoke-ManagedIngressTransportProbe($Ingress,$Urls,[DateTime]$Deadline,$Cancellation=$null) {
    # Use the application's entrance, not the global entrance or a direct upstream.
    # The established endpoint probes never send account data or preserve response bodies.
    $profile=[pscustomobject]@{Protocol='http';Host='127.0.0.1';Port=[int]$Ingress.port}
    $probes=@();$finished=@{}
    try {
        foreach($url in $Urls){
            if((Test-ManagedLaunchCancelled $Cancellation) -or [DateTime]::UtcNow -ge $Deadline){return $false}
            $probes+=@(Start-HttpEndpointProbe $profile $url $true)
        }
        do {
            if(Test-ManagedLaunchCancelled $Cancellation){return $false}
            foreach($probe in $probes){
                if(-not $finished.ContainsKey($probe.Url) -and $probe.Process.HasExited){
                    $finished[$probe.Url]=$true
                    if((Read-HttpEndpointProbe $probe).Accepted -eq $true){return $true}
                }
            }
            if($finished.Count -eq $probes.Count){return $false}
            Start-Sleep -Milliseconds 30
        }while([DateTime]::UtcNow -lt $Deadline)
        return $false
    }finally{foreach($probe in $probes){Close-HttpEndpointProbe $probe}}
}
function Wait-ManagedProgramIngressReady($Ingress,[int]$TimeoutMilliseconds=20000,$Cancellation=$null) {
    $started=[DateTime]::UtcNow;$deadline=$started.AddMilliseconds($TimeoutMilliseconds)
    $urls=@('https://www.google.com/generate_204','https://api.openai.com/v1/models','https://chatgpt.com/')
    $unavailable=$false;$unknown=$false
    do {
        if(Test-ManagedLaunchCancelled $Cancellation){throw '启动检查已取消，未启动程序；保存线路和固定入口保持不变。'}
        $remaining=[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds;if($remaining -le 0){break}
        try{$live=Invoke-AppRouter @{action='status'} -TimeoutMilliseconds ([Math]::Min(2500,$remaining))}catch{$live=$null;$unknown=$true}
        $ready=$null;if($live){$ready=$live.programIngresses|Where-Object {$_.id -ceq $Ingress.id}|Select-Object -First 1}
        if($live.available -eq $true -and $live.rulesAvailable -eq $true -and $ready.loaded -eq $true -and $ready.ready -eq $true -and $ready.effectiveRoute -notin @('Unknown',$null,'')){
            $route=[string]$ready.effectiveRoute;$limited=$false;$candidates=$urls;$healthy=$route -eq 'Direct'
            if($route -eq 'Blocked'){
                if(Test-ManagedDirectWebsiteSpace $live $Ingress.id){
                    $limited=$true;$healthy=$true
                }else{$unavailable=$true;break}
            }elseif(-not $healthy){
                # A cold selector initially names its preferred proxy before any health round.
                # Wait for a round completed after this launch check, allowing the existing
                # supervisor to choose its verified fallback without resetting preferences.
                $checked=[DateTime]::MinValue
                if([DateTime]::TryParse([string]$live.failover.updated,[ref]$checked)){
                    $checked=$checked.ToUniversalTime()
                    $healthy=$checked -ge $started -and $checked -le [DateTime]::UtcNow -and $live.failover.health.$route -eq $true
                    if($checked -ge $started -and $live.failover.health.$route -eq $false){$unavailable=$true}
                }
            }
            if($healthy){
                $probeDeadline=[DateTime]::UtcNow.AddSeconds(6);if($probeDeadline -gt $deadline){$probeDeadline=$deadline}
                # Direct is an explicit policy, including local/domestic-only use. A
                # foreign health site cannot veto that policy. The controller verifies
                # loaded rules and exact owned ingress; no general Internet claim follows.
                $passed=$route -eq 'Direct' -or $limited
                if(-not $passed){try{$passed=Invoke-ManagedIngressTransportProbe $Ingress $candidates $probeDeadline $Cancellation}catch{$unknown=$true}}
                if(Test-ManagedLaunchCancelled $Cancellation){throw '启动检查已取消，未启动程序；保存线路和固定入口保持不变。'}
                if($passed -and [DateTime]::UtcNow -lt $deadline){
                    $remaining=[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds
                    try{$after=Invoke-AppRouter @{action='status'} -TimeoutMilliseconds ([Math]::Min(2500,$remaining))}catch{$after=$null;$unknown=$true}
                    $verified=$null;if($after){$verified=$after.programIngresses|Where-Object {$_.id -ceq $Ingress.id}|Select-Object -First 1}
                    $healthStillVerified=$route -in @('Direct','Blocked') -or $after.failover.health.$route -eq $true
                    if([DateTime]::UtcNow -lt $deadline -and $after.available -eq $true -and $after.rulesAvailable -eq $true -and $verified.loaded -eq $true -and $verified.ready -eq $true -and $verified.effectiveRoute -ceq $route -and $healthStillVerified){
                        if(-not $limited -or ($after.siteRulesLoaded -eq $true -and (@($after.siteRules)|ConvertTo-Json -Depth 12 -Compress) -ceq (@($live.siteRules)|ConvertTo-Json -Depth 12 -Compress))){return [pscustomobject]@{EffectiveRoute=$route;LimitedDirect=$limited}}
                    }
                }else{$unavailable=$true}
            }
        }else{$unknown=$true}
        $remaining=[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds;if($remaining -gt 0){Start-Sleep -Milliseconds ([Math]::Min(150,$remaining))}
    }while([DateTime]::UtcNow -lt $deadline)
    if($unavailable){throw '程序固定入口的实际转发检测未通过，或默认代理不可用且没有适用于此程序的已加载直连网站例外；未启动程序。请在“代理入口”检查上游，或为此程序切换可用线路后重试。保存线路、后台服务和固定端口保持不变。'}
    throw '程序固定入口或出口尚未就绪，健康或转发状态未知；未启动程序。请在“检查与维护”检查服务及线路后重试。保存线路、后台服务和固定端口保持不变。'
}
function Set-UniversalProxy([string]$Key) {
    Use-ChangeLock {
        Assert-ManagedRoute $Key
        if($script:Profiles.Routing.Adapter -ne 'standalone'){return Enable-IndependentGateway -OwnerPID $PID -InitialRoute $Key -UnifiedSwitch -AllowMigration}
        if(Test-Path -LiteralPath (Get-IndependentSessionPath)){Ensure-ManagedGateway $Key|Out-Null}
        Set-SelectedProxy $Key
    }
}
function New-ManagedIngressPort($Snapshot) {
    $used=@($script:Profiles.Profiles|ForEach-Object Port)+@($Snapshot.programIngresses|ForEach-Object port)
    for($port=19080;$port -lt 20080;$port++){
        if($port -in $used){continue}
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$port)
        try{$listener.Server.ExclusiveAddressUse=$true;$listener.Start();return $port}catch{}finally{$listener.Stop()}
    }
    throw '没有可用的程序固定入口端口；未复用其他软件的监听端口。'
}
function Invoke-ManagedRoutingChange($Before,$Next,[scriptblock]$Verify) {
    $backup=Save-Backup ([pscustomobject]@{Version=3;Time=(Get-Date).ToString('o');System=(Get-SystemSnapshot);Environment=(Get-UserProxyEnv);Selection=(Get-Selection);Routing=$Before})
    $written=$false
    try{
        Set-RoutingSnapshot $Next $Before;$written=$true
        if($Verify){& $Verify|Out-Null}
    }catch{
        $failure=$_.Exception.Message
        if($written){
            try{if(Test-SameRouting (Get-RoutingSnapshot) $Next){Set-RoutingSnapshot $Before $Next}else{throw '记录已被其他操作更改'}}
            catch{throw ($failure+'；未完成规则回滚，保留当前记录与备份：'+$backup)}
        }
        throw ($failure+'；原规则已保留或恢复。')
    }
    return $backup
}
function Set-ManagedApplicationRoute([string]$Path,[string]$Route) {
    Use-ChangeLock {
        $executable=Resolve-ProgramTarget $Path;Assert-ManagedRoute $Route -AllowFollow
        foreach($profile in $script:Profiles.Profiles){if($executable -ieq $profile.CorePath -or $executable -ieq $profile.AppPath){throw '不能给代理程序自身分流，以免形成回路。'}}
        $adapter=Get-ProgramProxyAdapter $executable
        if($adapter -notin @('chromium','qtwebengine') -and (Get-ManagedProgramIngress $executable)){throw '此程序当前版本已无法核验原启动适配，原固定入口和规则保持不变。请检查程序路径及安装是否完整，再修复程序记录。'}
        if($adapter -eq 'qtwebengine' -and -not (Get-ManagedProgramIngress $executable)){throw 'Qt 网页组件首次接入需要明确预览确认；请从程序线路中启用网页组件独立入口。'}
        if($Route -notin @('Direct','Follow') -and -not (Test-ProxyRoute $Route -Fast).Usable){throw '所选上游检测未通过，未保存切换成功状态。请先检查这个代理入口。'}
        # A program action never replaces the saved global default during cold start.
        if($adapter -eq 'qtwebengine'){Ensure-ManagedGateway -PreserveWindowsSettings|Out-Null}else{Ensure-ManagedGateway|Out-Null}
        if($adapter -notin @('chromium','qtwebengine')){
            $result=Set-ApplicationRoute $executable $Route
            $result.Message+=' 此程序没有可核验的原生代理启动适配；仍指向已退出旧代理的进程，需要在程序内改为流向入口或自行重开。'
            return $result
        }
        $before=Get-RoutingSnapshot;$next=Copy-RoutingSnapshot $before
        $entry=$before.programIngresses|Where-Object {$_.path -ieq $executable}|Select-Object -First 1
        $created=-not $entry
        if($created){
            if(@($before.programIngresses).Count -ge 64){throw '程序固定入口最多 64 个，请先移除不再使用的记录。'}
            $entry=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');path=$executable;port=(New-ManagedIngressPort $before);route=$Route;identity=(Get-ProgramIdentityDescriptor $executable (New-ProgramIdentityContext))}
        }else{$entry=Copy-RoutingSnapshot $entry;$entry.route=$Route}
        $next.programIngresses=@($before.programIngresses|Where-Object {$_.path -ine $executable})+@($entry)
        $next.entries=@($before.entries|Where-Object {$_.path -ine $executable})
        # Keep already owned shortcuts while upgrading legacy direct-upstream launch records.
        $next.launchEntries=@($before.launchEntries|ForEach-Object {if($_.path -ieq $executable){$copy=Copy-RoutingSnapshot $_;$copy.route='Follow';$copy}else{$_}})
        $next|Add-Member NoteProperty resetIngressSelections @($entry.id) -Force
        $verify={
            $live=Invoke-AppRouter @{action='status'}
            $loaded=$live.programIngresses|Where-Object {$_.id -ceq $entry.id}|Select-Object -First 1
            if(-not $live.available -or -not $loaded.loaded -or -not $loaded.ready){throw '程序固定入口或线路规则未通过实读校验，不能确认切换。'}
            $wanted=$Route;if($wanted -eq 'Follow'){$wanted=$live.effectiveDefaultRoute}
            if(-not $wanted -or $loaded.effectiveRoute -ne $wanted -or $wanted -in @('Blocked','Unknown')){throw '实际出口尚未到达所选线路，不能确认切换成功。'}
        }
        $backup=Invoke-ManagedRoutingChange $before $next $verify
        $shortcuts=@();$shortcutNotice=''
        $shortcutObservationUnknown=$false
        try{$shortcuts=@(Get-VerifiedProgramShortcuts $executable)}catch{$shortcutObservationUnknown=$true}
        $shortcutNotice=' 保存线路不会绑定桌面入口；可在“启动方式”中设置或解除绑定。'
        if($shortcutObservationUnknown){$shortcutNotice=' 线路已提交，但桌面入口状态读取失败，请在“启动方式”中检查；未改写任何桌面入口。'}
        $family=@();$managed=$false;$observationUnknown=$false
        try{
            $family=@(Get-ProgramFamily $executable @(Get-ProcessInventory))
            $managed=Test-ManagedProgramSession $executable $family $Route
            if($family.Count -and -not $managed){
                $observation=Get-ApplicationRoutes
                $row=$observation.Rows|Where-Object {$_.Path -ieq $executable -and $_.Mode -eq 'managed'}|Select-Object -First 1
                if($row -and $row.Loaded -and -not $row.NeedsRelaunch){$managed=$true}
                if(-not $observation.ProcessesAvailable -or -not $observation.TcpAvailable){$observationUnknown=$true}
            }
        }catch{$observationUnknown=$true}
        $message='程序固定入口已就绪，新连接的默认出口已核验为「'+(Get-RouteName $Route)+'」。网站例外规则继续生效。'
        if($observationUnknown){$message+=' 线路已提交，但当前程序连接读取失败，生效范围待确认；请刷新查看实际连接。'}
        elseif($family.Count -and -not $managed){$message+=' 当前进程未确认接入固定入口：请保存任务并完整退出，再从流向打开或使用已接入的桌面入口；旧进程记住的代理地址不能通过保存规则修改。'}
        elseif($family.Count){$message+=' 已接入程序及继承入口的后台进程无需重开；已有长连接保持原状，可预览后单独重连。'}
        else{$message+=' 请从流向或已接入的桌面入口打开程序。'}
        [pscustomobject]@{Backup=$backup;Message=($message+$shortcutNotice);Shortcuts=$shortcuts;Managed=$true;IngressId=$entry.id;ShortcutObservationUnknown=$shortcutObservationUnknown;ObservationUnknown=$observationUnknown;NeedsRelaunch=($family.Count -gt 0 -and -not $managed -and -not $observationUnknown)}
    }
}
function Get-WebsiteRules {
    $snapshot=Get-RuleMaintenanceSnapshot ''; $entries=@()
    foreach($rule in @($snapshot.Engine.siteRules|Where-Object {$_})){
        $executable='';if($rule.scope -ne 'global'){$ingress=$snapshot.Engine.programIngresses|Where-Object {$_.id -ceq $rule.scope}|Select-Object -First 1;if(-not $ingress){throw '网站规则引用的程序入口不存在，请从本机备份恢复。'};$executable=$ingress.path}
        $entries+=@([pscustomobject]@{Id=$rule.id;Domain=$rule.domain;Match=$(if($rule.type -eq 'domain'){'exact'}else{'suffix'});Route=$rule.route;Executable=$executable})
    }
    $available=$false;$loaded=$false
    try{$live=Invoke-AppRouter @{action='status'} -TimeoutMilliseconds 9000;$available=[bool]$live.available;$loaded=$live.siteRulesLoaded -eq $true}catch{}
    [pscustomobject]@{Entries=$entries;Revision=$snapshot.Files['app-rules.json'].TextHash;Available=$available;Loaded=$loaded;Message='按目标域名分流：程序网站例外优先于全局例外，然后使用程序线路。只作用于进入流向的新连接。'}
}
function ConvertTo-WebsiteDomain([string]$Domain) {
    $text=$Domain.Trim().TrimEnd('.').ToLowerInvariant()
    if(-not $text -or $text -match '[/\\:@?#*\s\x00]'){throw '请只输入域名，例如 example.com，不要输入网址、端口、通配符或登录链接。'}
    try{$text=(New-Object Globalization.IdnMapping).GetAscii($text)}catch{throw '域名格式无效。'}
    if($text.Length -gt 253 -or $text -notmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$'){throw '请输入有效的完整域名。'}
    $address=$null;if([Net.IPAddress]::TryParse($text,[ref]$address)){throw '网站规则使用域名，暂不支持 IP 地址规则。'}
    return $text
}
function Set-WebsiteRules($Entries,[string]$ExpectedRevision) {
    Use-ChangeLock {
        $snapshot=Get-RuleMaintenanceSnapshot ''
        if(-not $ExpectedRevision -or $snapshot.Files['app-rules.json'].TextHash -cne $ExpectedRevision){throw '网站或程序规则已改变，请重新打开网站规则后再保存。'}
        if(@($Entries).Count -gt 128){throw '网站规则最多 128 条。'}
        $rules=@();$keys=@{};$ids=@{}
        foreach($entry in @($Entries)){
            Assert-ManagedRoute $entry.Route
            $domain=ConvertTo-WebsiteDomain $entry.Domain
            if($entry.Match -notin @('exact','suffix')){throw '请选择精确域名或包含子域名。'}
            $scope='global'
            if($entry.Executable){$ingress=$snapshot.Engine.programIngresses|Where-Object {$_.path -ieq $entry.Executable}|Select-Object -First 1;if(-not $ingress){throw '请先为这个程序设置线路，建立固定入口，再添加程序网站例外。'};$scope=$ingress.id}
            $key=$scope+'|'+$entry.Match+'|'+$domain;if($keys.ContainsKey($key)){throw '同一范围存在重复的网站规则，请合并后保存。'};$keys[$key]=$true
            $id=[string]$entry.Id;if(-not $id){$id=[Guid]::NewGuid().ToString('N')}
            if($id -cnotmatch '^[a-f0-9]{32}$' -or $ids.ContainsKey($id)){throw '网站规则标识无效或重复，请重新添加该行。'};$ids[$id]=$true
            $rules+=@([pscustomobject]@{id=$id;scope=$scope;type=$(if($entry.Match -eq 'exact'){'domain'}else{'suffix'});domain=$domain;route=$entry.Route})
        }
        Ensure-ManagedGateway|Out-Null
        $before=Get-RoutingSnapshot
        $originalSites=ConvertTo-RoutingComparableValue @($snapshot.Engine.siteRules|Where-Object {$_})|ConvertTo-Json -Depth 16 -Compress
        $currentSites=ConvertTo-RoutingComparableValue @($before.siteRules|Where-Object {$_})|ConvertTo-Json -Depth 16 -Compress
        if($originalSites -cne $currentSites){throw '入口启动期间网站规则已改变，请重新打开规则后保存。'}
        $originalIngresses=ConvertTo-RoutingComparableValue @($snapshot.Engine.programIngresses|Where-Object {$_})|ConvertTo-Json -Depth 16 -Compress
        $currentIngresses=ConvertTo-RoutingComparableValue @($before.programIngresses|Where-Object {$_})|ConvertTo-Json -Depth 16 -Compress
        if($originalIngresses -cne $currentIngresses){throw '入口启动期间程序入口已改变，请重新打开规则后保存。'}
        $next=Copy-RoutingSnapshot $before;$next.siteRules=$rules
        $verify={$live=Invoke-AppRouter @{action='status'};if(-not $live.available -or -not $live.siteRulesLoaded){throw '网站规则未通过引擎实读校验。'}}
        $backup=Invoke-ManagedRoutingChange $before $next $verify
        [pscustomobject]@{Backup=$backup;Message='网站规则已载入并核对。进入流向的新连接按域名选择出口；请刷新页面，已有连接不会被自动断开。'}
    }
}

# Migration writes share the same exclusive file CAS used by explicit rule maintenance.
function Set-MigrationJson([string]$Path,$Value,[string]$ExpectedHash) {
    $before=Read-RuleMaintenanceFile $Path
    if($before.TextHash -cne $ExpectedHash){throw '代理配置在迁移期间已改变，保留最新内容。'}
    $bytes=ConvertTo-RuleMaintenanceBytes $Value
    Set-RuleMaintenanceFile $before $bytes $false
    Get-RuleMaintenanceHash $bytes
}
function Restore-MigrationFile($Original,[string]$OwnedHash) {
    $current=Read-RuleMaintenanceFile $Original.Path
    if($current.TextHash -cne $OwnedHash){throw '迁移文件已被外部更改，未覆盖最新内容。'}
    Set-RuleMaintenanceFile $current $Original.Bytes (-not $Original.Exists)
}

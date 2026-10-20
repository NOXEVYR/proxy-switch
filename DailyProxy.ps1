# Explicit external-client switching. No engine, application rule or client setting writes.
function Get-DailyProxyReceiptPath {Join-Path $script:DataRoot 'daily-proxy-receipt.json'}
function Get-DailyProxyHash($Value) {
    $text=[string](ConvertTo-RoutingComparableValue $Value|ConvertTo-Json -Depth 32 -Compress)
    if(-not $text){$text='null'}
    $hash=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$hash.Dispose()}
}
function Get-DailyProxyEndpoint([string]$Key) {
    if($Key -eq 'Direct'){return [pscustomobject]@{State='Ready';Key=$Key;Identity='Direct'}}
    $p=Get-Profile $Key
    if($p.CorePath -and ([IO.Path]::GetFileName($p.CorePath) -ieq 'FlowSwitch.Core.exe' -or $p.CorePath.StartsWith(($script:DataRoot.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase))){return [pscustomobject]@{State='Unsupported';Key=$Key}}
    if($p.Protocol -ne 'http' -or $p.Host -notin @('127.0.0.1','localhost','::1')){return [pscustomobject]@{State='Unsupported';Key=$Key}}
    $tcp=Get-TcpObservationSnapshot
    if(-not $tcp.Available){return [pscustomobject]@{State='Unknown';Key=$Key}}
    $addresses=if($p.Host -eq '127.0.0.1'){@('127.0.0.1','0.0.0.0')}elseif($p.Host -eq '::1'){@('::1','::')}else{@('127.0.0.1','0.0.0.0','::1','::')}
    $rows=@($tcp.Rows|Where-Object {$_.State -eq 'Listen' -and $_.LocalPort -eq $p.Port -and $_.LocalAddress -in $addresses})
    if(-not $rows.Count){
        $ambiguous=@($tcp.Rows|Where-Object {$_.State -eq 'Listen' -and $_.LocalPort -eq $p.Port -and $_.LocalAddress -eq '::'}).Count
        return [pscustomobject]@{State=$(if($ambiguous){'Unknown'}else{'Stopped'});Key=$Key}
    }
    $owners=@($rows|ForEach-Object OwningProcess|Select-Object -Unique)
    if($owners.Count -ne 1){return [pscustomobject]@{State='Unknown';Key=$Key}}
    $owner=@(Get-ProcessInventory -Id $owners[0])
    if($owner.Count -ne 1){return [pscustomobject]@{State='Unknown';Key=$Key}}
    $ownerPath=$owner[0].Path
    $started=$owner[0].StartTime
    $serviceIdentity=$null
    if(-not $ownerPath){
        $serviceIdentity=Get-GatewayServiceIdentity $p $owner[0]
        if(-not $serviceIdentity){return [pscustomobject]@{State='Unknown';Key=$Key}}
        $ownerPath=$p.CorePath
        if($started -le [DateTime]::MinValue){
            try{
                # Exact PID, OS creation time only; no modules, command line or elevation.
                $service=@(Get-CimInstance Win32_Process -Filter ('ProcessId = '+[int]$owner[0].Id) -Property ProcessId,CreationDate -ErrorAction Stop)
                if($service.Count -ne 1 -or $service[0].ProcessId -ne $owner[0].Id){throw 'identity-unknown'}
                $started=[DateTime]$service[0].CreationDate
            }catch{return [pscustomobject]@{State='Unknown';Key=$Key}}
        }
    }elseif($p.CorePath -and $ownerPath -ine $p.CorePath){return [pscustomobject]@{State='Unknown';Key=$Key}}
    if($started -le [DateTime]::MinValue){return [pscustomobject]@{State='Unknown';Key=$Key}}
    $file=[LocalProxySwitch.ProgramFileIdentity]::Read($ownerPath)
    if($file.Status -ne 'Available' -or -not $file.FileId -or -not $file.CanonicalPath){return [pscustomobject]@{State='Unknown';Key=$Key}}
    if([IO.Path]::GetFileName($file.CanonicalPath) -ieq 'FlowSwitch.Core.exe'){return [pscustomobject]@{State='Unsupported';Key=$Key}}
    $identity=[pscustomobject]@{PID=$owner[0].Id;Start=$started.ToUniversalTime().Ticks.ToString();File=$file.FileId;Path=$file.CanonicalPath;Service=$serviceIdentity;Listeners=@($rows|ForEach-Object {[string]$_.LocalAddress+':'+$_.LocalPort}|Sort-Object)}
    [pscustomobject]@{State='Ready';Key=$Key;Identity=(Get-DailyProxyHash $identity)}
}
function Get-DailyProxyContext {
    $settings=Read-ProfileSettings
    $files=[ordered]@{}
    foreach($name in @('config.json','app-rules.json','program-proxies.json','selection.json','gateway-session.json','daily-proxy-receipt.json')){
        $files[$name]=(Read-RuleMaintenanceFile (Join-Path $script:DataRoot $name)).Hash
    }
    $client=Get-ClientInterference
    $stableClient=[pscustomobject]@{Running=[bool]$client.Running;Tun=[bool]$client.Tun;Guard=[bool]$client.Guard;SystemProxy=[bool]$client.SystemProxy;Topology=[pscustomobject]@{State=$client.Topology.State;IPv4=$client.Topology.IPv4;IPv6=$client.Topology.IPv6;Available=$client.Topology.Available}}
    $system=Get-SystemSnapshot
    [pscustomobject]@{Settings=$settings;System=$system;WindowsViews=(Get-DailyProxyWindowsViews $system);Environment=(Get-UserProxyEnv);Selection=(Get-Selection);Rules=(Get-RoutingSnapshot);Files=[pscustomobject]$files;Client=$stableClient}
}
function Get-DailyProxyWindowsViews($System) {
    $views=Get-WindowsApplicationProxyViews
    # Bind exact values using hashes; plans and UI never expose proxy credentials.
    [pscustomobject]@{Registry=[pscustomobject]@{Available=[bool]$views.Registry.Available;Enabled=[bool]$views.Registry.Enabled;Key=(Get-EndpointKey $views.Registry.Server);ServerHash=(Get-DailyProxyHash ([string]$views.Registry.Server))};WinHttpIE=[pscustomobject]@{Available=[bool]$views.WinHttpIE.Available;Key=(Get-EndpointKey $views.WinHttpIE.Server);ServerHash=(Get-DailyProxyHash ([string]$views.WinHttpIE.Server));AutoDetect=[bool]$views.WinHttpIE.AutoDetect;HasPac=[bool]$views.WinHttpIE.HasPac};Summary=(ConvertTo-ApplicationProxyViewSummary $System $views)}
}
function Test-DailyProxyWindowsTarget($System,$Views,[string]$Key) {
    if((Get-SystemKey $System) -ne $Key -or -not $Views.Registry.Available -or -not $Views.WinHttpIE.Available -or $Views.WinHttpIE.AutoDetect -or $Views.WinHttpIE.HasPac){return $false}
    if($Key -eq 'Direct'){return (-not $Views.Registry.Enabled -and $Views.WinHttpIE.Key -eq 'Unset')}
    return ($Views.Registry.Enabled -and $Views.Registry.Key -eq $Key -and $Views.WinHttpIE.Key -eq $Key)
}
function Get-DailyProxyBlockReason($Context) {
    if($Context.Settings.Routing.Adapter -ne 'none' -or $script:Profiles.Routing.Adapter -ne 'none'){return '当前为高级分流模式，请使用该模式的明确操作。'}
    if($Context.Files.'gateway-session.json' -ne '<missing>'){return '存在独立入口会话或待恢复记录，请先在高级功能中核验并正常停止；日常切换不会恢复或启动它。'}
    if((Get-DailyProxyHash $Context.Settings) -cne (Get-DailyProxyHash $script:Profiles)){return '代理配置已变化，请刷新后重新预览。'}
    if($Context.Client.Tun -or $Context.Client.Guard){return '外部 TUN 或代理守卫正在接管网络，请先在原客户端核对并关闭冲突项；流向不会代改。'}
    if(($Context.System.Flags -band 12) -or $Context.WindowsViews.WinHttpIE.AutoDetect -or $Context.WindowsViews.WinHttpIE.HasPac){return '当前启用了自动代理或自动检测，日常切换（包括直连）已停用。请在原客户端或 Windows 设置中处理自动模式后重新预览；流向不会关闭它。'}
    if(-not $Context.WindowsViews.Registry.Available -or -not $Context.WindowsViews.WinHttpIE.Available){return 'Windows 代理视图读取不完整，无法核验切换；请先运行只读诊断。'}
    return ''
}
function Test-DailyProxyEffectiveTarget($Context,[string]$Key) {
    if(-not (Test-DailyProxyWindowsTarget $Context.System $Context.WindowsViews $Key)){return $false}
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){
        $route=Get-EndpointKey $Context.Environment.$name
        # Missing variables do not override the effective Windows proxy.
        if($route -ne 'Unset' -and $route -ne $Key){return $false}
    }
    return $true
}
function Get-DailyProxyEnvironmentOwnership($Values) {
    $owners=[ordered]@{};$ready=$true
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){
        $key=Get-EndpointKey $Values.$name
        if($key -eq 'Unset'){$owners[$name]=$null;continue}
        if($key -notin (Get-ProfileKeys)){$ready=$false;$owners[$name]=[pscustomobject]@{State='Unknown'};continue}
        $endpoint=Get-DailyProxyEndpoint $key;$owners[$name]=$endpoint
        if($endpoint.State -ne 'Ready'){$ready=$false}
    }
    [pscustomobject]@{Ready=$ready;Owners=[pscustomobject]$owners}
}
function Get-DailyProxyPlan([string]$Key) {
    $context=Get-DailyProxyContext;$reason=Get-DailyProxyBlockReason $context;$endpoint=$null
    if($Key -ne 'Direct' -and $Key -notin (Get-ProfileKeys)){$reason='请选择已登记的本地 HTTP 代理或直连。'}
    else{$endpoint=Get-DailyProxyEndpoint $Key}
    if(-not $reason -and $endpoint.State -ne 'Ready'){
        $reason=switch($endpoint.State){'Stopped'{'所选代理未连接，请在原客户端连接后刷新。'};'Unsupported'{'日常切换仅支持已登记的本机 HTTP 入口。'};default{'所选入口的监听归属未知，保留当前设置，请先运行只读诊断。'}}
    }
    $noChange=(-not $reason -and (Test-DailyProxyEffectiveTarget $context $Key))
    $message=if($reason){$reason}elseif($noChange){'当前已使用「'+(Get-RouteName $Key)+'」，无需重新应用。切节点请到原客户端；连接异常可运行只读诊断。'}else{'将新连接切到「'+(Get-RouteName $Key)+'」，同步用户 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY，保留 NO_PROXY、绕过项和程序规则；已有进程环境不会刷新。原客户端后续可能改写系统代理，流向不会后台抢回。'}
    if(-not $reason -and -not $noChange -and $context.WindowsViews.Summary.Different){$message='Windows 代理视图不一致。本次会写入所选入口并重新核对三个视图；不一致时不报告成功。'+$message}
    [pscustomobject]@{Kind='Switch';Key=$Key;TargetName=(Get-RouteName $Key);CreatedAt=[DateTimeOffset]::UtcNow.ToString('o');Revision=(Get-DailyProxyHash ([pscustomobject]@{Kind='Switch';Key=$Key;Context=$context;Endpoint=$endpoint}));CanApply=(-not $reason);NoChange=[bool]$noChange;Message=$message;Context=$context;Endpoint=$endpoint}
}
function Assert-DailyProxyFreshPlan($Plan,[string]$Kind) {
    $created=[DateTimeOffset]::MinValue
    if(-not $Plan -or $Plan.Kind -cne $Kind -or -not [DateTimeOffset]::TryParse([string]$Plan.CreatedAt,[ref]$created)){throw '日常切换预览无效，请重新预览。'}
    $age=([DateTimeOffset]::UtcNow-$created).TotalSeconds
    if($age -lt -5 -or $age -gt 120){throw '日常切换预览已过期，请重新预览。'}
}
function Assert-DailyProxyCurrent($Plan) {
    Assert-DailyProxyFreshPlan $Plan $Plan.Kind
    $current=if($Plan.Kind -eq 'Undo'){Get-DailyProxyUndoPlan}else{Get-DailyProxyPlan $Plan.Key}
    if(-not $current.CanApply){throw $current.Message}
    if($current.Revision -cne $Plan.Revision){throw '预览后配置、系统入口、环境、规则、选择或监听归属已变化，未覆盖新设置；请重新预览。'}
    $current
}
function Set-DailyProxy($Plan,[switch]$Confirmed,[scriptblock]$PreApplyValidation=$null) {
    if(-not $Confirmed){throw '日常切换需要先预览并明确确认。'}
    Assert-DailyProxyFreshPlan $Plan 'Switch'
    Use-ChangeLock {
        if($PreApplyValidation){& $PreApplyValidation|Out-Null}
        $current=Assert-DailyProxyCurrent $Plan
        if($current.NoChange){return [pscustomobject]@{Key=$current.Key;NoChange=$true;Backup=$null;Message=$current.Message}}
        $before=$current.Context;$key=$current.Key
        if($key -ne 'Direct'){
            $test=Test-ProxyRoute $key -Fast
            if(-not $test.Usable){throw '所选线路实际检测未通过，保留全部当前设置；请在原客户端检查连接。'}
        }
        $current=Assert-DailyProxyCurrent $Plan
        if($PreApplyValidation){& $PreApplyValidation|Out-Null}
        $target=[pscustomobject]@{Flags=$(if($key -eq 'Direct'){($before.System.Flags -band -3) -bor 1}else{3});Server=$(if($key -eq 'Direct'){$before.System.Server}else{Get-EndpointAddress (Get-Profile $key)});Bypass=$before.System.Bypass}
        $targetEnv=New-EnvTarget $before.Environment $key;$targetEnv.NO_PROXY=$before.Environment.NO_PROXY
        $selection=[pscustomobject]@{Key=$key;NetworkKey=$key;Unified=$false;Daily=$true;ChangedAt=[DateTimeOffset]::UtcNow.ToString('o')}
        $priorReceipt=Read-RuleMaintenanceFile (Get-DailyProxyReceiptPath)
        $beforeKey=Get-SystemKey $before.System
        $oldEndpoint=if($beforeKey -eq 'Direct' -or $beforeKey -in (Get-ProfileKeys)){Get-DailyProxyEndpoint $beforeKey}else{[pscustomobject]@{State='Unsupported';Key=$beforeKey}}
        $receipt=[pscustomobject]@{Version=1;Id=[Guid]::NewGuid().ToString('N');Phase='Applied';CreatedAt=[DateTimeOffset]::UtcNow.ToString('o');BeforeSystem=$before.System;BeforeWindowsViews=$before.WindowsViews;BeforeEnvironment=$before.Environment;BeforeSelection=$before.Selection;BeforeEndpoint=$oldEndpoint;BeforeEnvironmentOwnership=(Get-DailyProxyEnvironmentOwnership $before.Environment);AfterSystem=$target;AfterEnvironment=$targetEnv;AfterSelection=$selection;AfterEndpoint=$current.Endpoint;SettingsHash=(Get-DailyProxyHash $before.Settings);RulesHash=(Get-DailyProxyHash $before.Rules);RuleFiles=$before.Files}
        Invoke-DailyProxyCommit $current $target $targetEnv $selection $receipt $priorReceipt $PreApplyValidation
    }
}
function Invoke-DailyProxyCommit($Plan,$Target,$TargetEnv,$Selection,$Receipt,$PriorReceipt,[scriptblock]$PreApplyValidation=$null) {
    $before=$Plan.Context
    $written=[pscustomobject]@{Value=$false}
    $verify={if($PreApplyValidation){& $PreApplyValidation|Out-Null};Assert-DailyProxyCurrent $Plan|Out-Null}
    $post={
        # Revalidate non-Windows inputs after the native write, before recording ownership.
        $after=Get-DailyProxyContext
        if(-not (Test-DailyProxyWindowsTarget $after.System $after.WindowsViews $Plan.Key)){throw '写入后三个 Windows 代理视图未一致指向目标，未确认切换；保留无法确认归属的外部设置。'}
        foreach($name in @('Settings','Selection','Rules','Files','Client')){
            if((Get-DailyProxyHash $after.$name) -cne (Get-DailyProxyHash $before.$name)){throw '提交期间配置或归属发生变化，不能确认日常切换。'}
        }
        if((Get-DailyProxyHash (Get-DailyProxyEndpoint $Plan.Key)) -cne (Get-DailyProxyHash $Plan.Endpoint)){throw '提交期间目标监听归属发生变化。'}
        $Receipt|Add-Member NoteProperty AfterWindowsViews $after.WindowsViews -Force
        $receiptBytes=ConvertTo-RuleMaintenanceBytes $Receipt;$written.Value=$true
        $written|Add-Member NoteProperty Hash (Get-RuleMaintenanceHash $receiptBytes) -Force
        Set-RuleMaintenanceFile $PriorReceipt $receiptBytes $false
    }
    try{
        $rollbackOwner={
            # One Native write cannot reconstruct a previously divergent set of
            # Windows views. Never replace a verified repaired target with a new
            # all-Direct state while claiming to have restored the old divergence.
            if(-not (Test-DailyProxyWindowsTarget $before.System $before.WindowsViews (Get-SystemKey $before.System))){return $false}
            $now=Get-SystemSnapshot
            Test-DailyProxyWindowsTarget $now (Get-DailyProxyWindowsViews $now) $Plan.Key
        }
        $final={
            $system=Get-SystemSnapshot
            if(-not (Test-DailyProxyWindowsTarget $system (Get-DailyProxyWindowsViews $system) $Plan.Key)){throw '完成前 Windows 代理视图再次变化，未确认成功；保留无法确认归属的外部设置。'}
        }
        $backup=Invoke-ProxyTransaction $Target $TargetEnv $Selection $before.System $before.Environment -VerifyAction $verify -PreWindowsAction $verify -PostCommitAction $post -CheckSelection -ExpectedSelection $before.Selection -SystemRollbackOwnership $rollbackOwner -FinalVerifyAction $final
    }catch{
        $failure=$_.Exception.Message
        if($written.Value){
            $actual=Read-RuleMaintenanceFile $PriorReceipt.Path
            if($actual.Hash -ceq $written.Hash){Set-RuleMaintenanceFile $actual $PriorReceipt.Bytes (-not $PriorReceipt.Exists)}
        }
        if(-not (Test-DailyProxyWindowsTarget $before.System $before.WindowsViews (Get-SystemKey $before.System))){throw ($failure+' 原来的代理视图分歧无法安全还原，未按单一快照回写系统入口；请重新检查当前入口和操作记录。')}
        throw
    }
    [pscustomobject]@{Key=$Plan.Key;NoChange=$false;Backup=$backup;Message=$(if($Plan.Kind -eq 'Undo'){'已撤销最近一次日常切换，恢复仍核验有效的原系统入口与用户变量；现有进程环境不会刷新。'}else{'已将新连接切到「'+$Plan.TargetName+'」，保留程序规则与 NO_PROXY；已有进程环境不会刷新。'})}
}
function Get-DailyProxyUndoPlan {
    $context=Get-DailyProxyContext;$reason=Get-DailyProxyBlockReason $context
    $image=Read-RuleMaintenanceFile (Get-DailyProxyReceiptPath);$receipt=Read-RuleMaintenanceJson $image $null;$endpoint=$null;$key='Unknown'
    if(-not $reason){
        if(-not $receipt -or $receipt.Version -ne 1 -or $receipt.Phase -ne 'Applied'){$reason='没有可撤销的最近日常切换。'}
        elseif(-not (Test-SameSnapshot $context.System $receipt.AfterSystem) -or -not (Test-SameEnv $context.Environment $receipt.AfterEnvironment) -or (Get-DailyProxyHash $context.Selection) -cne (Get-DailyProxyHash $receipt.AfterSelection)){$reason='系统入口、环境或选择已被外部修改，不能撤销覆盖当前设置。'}
        elseif(-not $receipt.AfterWindowsViews -or (Get-DailyProxyHash $context.WindowsViews) -cne (Get-DailyProxyHash $receipt.AfterWindowsViews)){$reason='Windows 代理视图已变化或缺少归属记录，不能撤销覆盖当前设置。'}
        elseif(-not $receipt.BeforeWindowsViews -or -not (Test-DailyProxyWindowsTarget $receipt.BeforeSystem $receipt.BeforeWindowsViews $receipt.BeforeEndpoint.Key)){$reason='原 Windows 代理视图不一致，不能恢复到分歧或未知的旧状态。'}
        elseif((Get-DailyProxyHash $context.Settings) -cne $receipt.SettingsHash -or (Get-DailyProxyHash $context.Rules) -cne $receipt.RulesHash){$reason='代理配置或程序规则已变化，不能撤销旧切换。'}
        else{
            $key=Get-SystemKey $receipt.BeforeSystem
            if($key -ne 'Direct' -and $key -notin (Get-ProfileKeys)){$reason='原入口是未知或自动代理，不能按日常收据恢复。'}
            else{
                $endpoint=Get-DailyProxyEndpoint $key
                $afterEndpoint=Get-DailyProxyEndpoint $receipt.AfterEndpoint.Key
                if($endpoint.State -ne 'Ready' -or (Get-DailyProxyHash $endpoint) -cne (Get-DailyProxyHash $receipt.BeforeEndpoint)){$reason='原入口已停止或监听归属变化，不能恢复旧入口。'}
                elseif($afterEndpoint.State -ne 'Ready' -or (Get-DailyProxyHash $afterEndpoint) -cne (Get-DailyProxyHash $receipt.AfterEndpoint)){$reason='当前入口已停止或监听归属变化，不能确认撤销归属。'}
            }
        }
    }
    if(-not $reason){
        $environmentOwners=Get-DailyProxyEnvironmentOwnership $receipt.BeforeEnvironment
        if(-not $environmentOwners.Ready -or -not $receipt.BeforeEnvironmentOwnership.Ready -or (Get-DailyProxyHash $environmentOwners) -cne (Get-DailyProxyHash $receipt.BeforeEnvironmentOwnership)){$reason='原用户变量包含失效、未知或归属变化的入口，未恢复。'}
    }
    $message=if($reason){$reason}else{'仅撤销最近一次日常切换，恢复「'+(Get-RouteName $key)+'」及原用户代理变量；不会恢复独立网关。'}
    [pscustomobject]@{Kind='Undo';Key=$key;TargetName=(Get-RouteName $key);CreatedAt=[DateTimeOffset]::UtcNow.ToString('o');Revision=(Get-DailyProxyHash ([pscustomobject]@{Kind='Undo';Context=$context;Receipt=$receipt;Endpoint=$endpoint}));CanApply=(-not $reason);NoChange=$false;Message=$message;Context=$context;Receipt=$receipt;Endpoint=$endpoint}
}
function Restore-DailyProxy($Plan,[switch]$Confirmed) {
    if(-not $Confirmed){throw '撤销日常切换需要先预览并明确确认。'}
    Assert-DailyProxyFreshPlan $Plan 'Undo'
    Use-ChangeLock {
        $current=Assert-DailyProxyCurrent $Plan;$receipt=$current.Receipt
        if($current.Key -ne 'Direct' -and -not (Test-ProxyRoute $current.Key -Fast).Usable){throw '原线路实际检测未通过，保留当前设置。'}
        $current=Assert-DailyProxyCurrent $Plan
        $next=$receipt|ConvertTo-Json -Depth 32|ConvertFrom-Json;$next.Phase='Undone'
        Invoke-DailyProxyCommit $current $receipt.BeforeSystem $receipt.BeforeEnvironment $receipt.BeforeSelection $next (Read-RuleMaintenanceFile (Get-DailyProxyReceiptPath))
    }
}
function Get-DailyProxyState($Status) {
    $mode=if($script:Profiles.Routing.Adapter -eq 'none'){'Daily'}else{'Advanced'}
    $owner=Get-RouteName $Status.Key
    $headline=if($Status.Key -eq 'Direct'){'当前系统代理为直连'}elseif($Status.Key -in (Get-ProfileKeys)){'当前系统代理由 '+$owner+' 管理'}else{'当前系统代理为其他或自动模式'}
    $detail='以实时系统入口为准；原客户端负责节点与连接，程序专用线路保持原设置。'
    $next='切节点请到原客户端；需要更换已登记的客户端入口时再预览切换。'
    if($Status.Key -in (Get-ProfileKeys) -and $Status.EndpointReady -ne $true){
        $headline=if($Status.EndpointReady -eq $false){$owner+' 未连接'}else{'当前系统入口归属待确认'}
        $detail='系统仍指向该入口，但尚未核验可用连接；不会自动启动任何引擎。';$next='点击首页“开始断网排查”，确认客户端和内核状态，再按提示恢复。'
    }
    if($Status.Key -eq 'Direct' -and $Status.EnvConflict){$headline='系统代理关闭，程序仍有代理设置';$detail='Windows 显示直连不代表后台程序没有代理。';$next='点击首页“开始断网排查”，先确认原客户端是否停止，不要先清理线路。'}
    if($Status.ApplicationProxyViews -and $Status.ApplicationProxyViews.Different){$headline='Windows 代理视图不一致';$detail=$Status.ApplicationProxyViews.Message;$next='在网络切换选择当前使用的代理并预览核对；也可在原客户端核对系统代理开关，再回目标应用检查。'}
    # UI summary is cheap and passive: CanUndo means the preview can be requested.
    # Fresh TCP, client topology and ownership checks belong to the worker's plan.
    $canUndo=$false;$undoReason='没有可预览撤销的最近日常切换。'
    if($mode -eq 'Daily'){
        try{
            $receipt=Read-RuleMaintenanceJson (Read-RuleMaintenanceFile (Get-DailyProxyReceiptPath)) $null
            if($receipt -and $receipt.Version -eq 1 -and $receipt.Phase -eq 'Applied'){$canUndo=$true;$undoReason='点击后先只读核验最近切换的系统、环境和入口归属；通过预览并确认后才撤销。'}
        }catch{$undoReason='日常切换记录读取失败，请先运行只读诊断。'}
    }else{$undoReason='当前为高级分流模式，日常撤销不可用。'}
    [pscustomobject]@{Mode=$mode;OwnerName=$owner;Headline=$headline;Detail=$detail;NextStep=$next;CanUndo=$canUndo;UndoReason=$undoReason}
}

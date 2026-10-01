# Explicit per-program Qt ingress. Never claims control of independent native services.
function Get-QtProgramAccessPlan([string]$Path,[string]$Route) {
    $plan=[pscustomobject]@{Version=1;Kind='qtwebengine';Path=$Path;Route=$Route;CreatedAt=[DateTime]::UtcNow.ToString('o');Revision='';Identity='';CanApply=$false;BlockedReason='';Message='';Impact=''}
    try{
        $script:Profiles=Read-ProfileSettings
        $path=Resolve-ProgramTarget $Path;$plan.Path=$path
        Assert-ManagedRoute $Route -AllowFollow
        if($script:Profiles.Routing.Adapter -ne 'standalone'){throw '请先明确配置流向独立内核；本次不会迁移其他分流引擎。'}
        if((Get-ProgramProxyAdapter $path) -ne 'qtwebengine'){throw 'Qt 网页组件文件布局或版本无法核验，未准备独立启动适配。'}
        $context=New-ProgramIdentityContext
        $identity=Get-ProgramIdentityDescriptor $path $context
        if(-not $identity.FileId -or $identity.PathStatus -ne 'Available'){throw '程序文件身份无法核验。'}
        foreach($profile in $script:Profiles.Profiles){if((Test-ProgramPathEquivalent $path $profile.AppPath $context) -or (Test-ProgramPathEquivalent $path $profile.CorePath $context)){throw '不能给代理程序自身启用独立入口。'}}
        $snapshot=Get-RoutingSnapshot
        if(@(@($snapshot.entries)+@($snapshot.programIngresses)|Where-Object {$_.path -ine $path -and (Test-ProgramPathEquivalent $_.path $path $context)}).Count){throw '同一程序存在不同路径记录，请先修复冲突。'}
        if(@($snapshot.entries|Where-Object {$_.path -ieq $path}).Count -gt 1 -or @($snapshot.programIngresses|Where-Object {$_.path -ieq $path}).Count -gt 1){throw '程序记录重复，请先处理冲突。'}
        $start=New-Object Diagnostics.ProcessStartInfo
        if([string]$start.EnvironmentVariables['QTWEBENGINEPROCESS_PATH']){throw '存在额外 Qt 组件路径设置，归属未知；未覆盖该设置。'}
        Merge-QtWebEngineLaunchFlags ([string]$start.EnvironmentVariables['QTWEBENGINE_CHROMIUM_FLAGS']) @('--no-proxy-server')|Out-Null
        $plan.Revision=Get-NetworkRepairRevision (Get-SystemSnapshot) (Get-UserProxyEnv)
        $plan.Identity=Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes @($identity.FileId,$identity.CanonicalPath,[string]$start.EnvironmentVariables['QTWEBENGINE_CHROMIUM_FLAGS'],[string]$start.EnvironmentVariables['QTWEBENGINEPROCESS_PATH']))
        $plan.CanApply=$true
        $plan.Impact='仅将所选程序改为 Qt 网页组件独立启动入口，保留系统代理、用户变量、默认与备用线路、其他程序和网站规则。原 EXE 引擎规则将替换为此程序固定入口；已有子程序的显式规则保持原样。首次会启动自有后台服务，但不会接管系统入口。'
        $plan.Message=$plan.Impact+' 保存后请完整退出整组程序，再点击“按此线路打开”。仅支持遵循 Qt 参数的网页组件；主程序、独立后台服务、游戏 UDP 和第三方 VPN 隧道仍需分别核验。不会结束程序或修改桌面快捷方式，也不代表登录恢复。'
    }catch{$plan.BlockedReason=$_.Exception.Message;$plan.Message=$plan.BlockedReason}
    $plan
}
function Set-QtProgramAccess($Plan,[switch]$Confirmed) {
    if(-not $Confirmed){throw '请先预览并明确确认网页组件独立启动适配。'}
    Use-ChangeLock {
        $age=([DateTime]::UtcNow-[DateTime]::Parse([string]$Plan.CreatedAt).ToUniversalTime()).TotalSeconds
        if($Plan.Version -ne 1 -or $Plan.Kind -cne 'qtwebengine' -or $age -lt 0 -or $age -gt 120){throw '网页组件接入预览无效或已过期，请重新预览。'}
        $fresh=Get-QtProgramAccessPlan $Plan.Path $Plan.Route
        if(-not $fresh.CanApply){throw $fresh.BlockedReason}
        if($fresh.Revision -cne $Plan.Revision -or $fresh.Identity -cne $Plan.Identity){throw '入口、文件身份、环境或规则已变化，未采用旧预览。'}
        $windows=Get-SystemSnapshot;$environment=Get-UserProxyEnv
        $before=Get-RoutingSnapshot
        Ensure-ManagedGateway -PreserveWindowsSettings|Out-Null
        # Service startup may set installed/default metadata, never replay an old routing image.
        $current=Get-RoutingSnapshot
        if(-not (Test-SameSnapshot $windows (Get-SystemSnapshot)) -or -not (Test-SameEnv $environment (Get-UserProxyEnv))){throw '全局入口已变化，未写入网页组件适配。请重新预览。'}
        if((Get-ProgramProxyAdapter $fresh.Path) -ne 'qtwebengine'){throw '启动期间 Qt 文件布局已变化，未写入适配。'}
        $id=Get-ProgramIdentityDescriptor $fresh.Path (New-ProgramIdentityContext)
        $start=New-Object Diagnostics.ProcessStartInfo
        $identityHash=Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes @($id.FileId,$id.CanonicalPath,[string]$start.EnvironmentVariables['QTWEBENGINE_CHROMIUM_FLAGS'],[string]$start.EnvironmentVariables['QTWEBENGINEPROCESS_PATH']))
        if($identityHash -cne $fresh.Identity){throw '程序或启动环境已变化，未写入适配。'}
        # Only installed/default fields may be normalized during a first core startup.
        $compareBefore=Copy-RoutingSnapshot $before;$compareBefore.installed=$current.installed
        if(-not $before.installed -and -not $before.defaultRoute){$compareBefore.defaultRoute=$current.defaultRoute}
        if(-not (Test-SameRouting $compareBefore $current)){throw '启动期间专线或网站规则已变化，未覆盖新记录。'}
        $next=Copy-RoutingSnapshot $current
        $entry=$current.programIngresses|Where-Object {$_.path -ieq $fresh.Path}|Select-Object -First 1
        if($entry){$entry=Copy-RoutingSnapshot $entry;$entry.route=$fresh.Route}
        else{
            if(@($current.programIngresses).Count -ge 64){throw '程序入口已达上限，未复用其他端口。'}
            $entry=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');path=$fresh.Path;port=(New-ManagedIngressPort $current);route=$fresh.Route;identity=$id}
        }
        $next.entries=@($current.entries|Where-Object {$_.path -ine $fresh.Path})
        $next.programIngresses=@($current.programIngresses|Where-Object {$_.path -ine $fresh.Path})+@($entry)
        $next|Add-Member NoteProperty resetIngressSelections @($entry.id) -Force
        $verify={
            $live=Invoke-AppRouter @{action='status'}
            $loaded=$live.programIngresses|Where-Object {$_.id -ceq $entry.id -and $_.path -ieq $entry.path -and [int]$_.port -eq [int]$entry.port}|Select-Object -First 1
            $wanted=$fresh.Route;if($wanted -eq 'Follow'){$wanted=$live.effectiveDefaultRoute}
            if(-not $live.available -or -not $loaded.ready -or -not $loaded.loaded -or $loaded.effectiveRoute -cne $wanted -or $wanted -in @('Blocked','Unknown','')){throw 'Qt 固定入口或实际选路未就绪，不能确认完成。'}
            if(-not (Test-SameSnapshot $windows (Get-SystemSnapshot)) -or -not (Test-SameEnv $environment (Get-UserProxyEnv))){throw '外部全局入口已变化，不能确认接入完成。'}
        }.GetNewClosure()
        $backup=Invoke-ManagedRoutingChange $current $next $verify
        [pscustomobject]@{Backup=$backup;Managed=$true;IngressId=$entry.id;Message='Qt 网页组件固定入口已保存并载入。系统代理与用户变量保持原样。请完整退出整组程序，再从流向“按此线路打开”；其他独立联网组件和真实登录仍待验证。未绑定桌面入口。'}
    }
}

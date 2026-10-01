# Explicit preview -> confirmed access repair. Previews are memory-only and expire.
function Get-ProgramRouteAccessSession {
    $image=Read-RuleMaintenanceFile (Get-IndependentSessionPath)
    if(-not $image.Exists){throw '流向服务会话不存在；请在“代理入口 → 备用与服务 → 使用流向独立入口”启动服务（保留专线），再检查并应用程序线路。'}
    $session=Read-RuleMaintenanceJson $image $null
    foreach($field in @('Version','Started','OwnerPID','OwnerStart','SupervisorPID','SupervisorStart','BeforeSystem','BeforeEnv','TargetSystem','TargetEnv')){
        if($null -eq $session.PSObject.Properties[$field]){throw '服务恢复记录不完整，未接回系统入口；请先检查服务。'}
    }
    if($session.Version -ne 1 -or -not $session.Started -or (Get-RecoveryOwnerState $session) -ne 'alive' -or (Get-RecoveryOwnerState ([pscustomobject]@{OwnerPID=$session.SupervisorPID;OwnerStart=$session.SupervisorStart})) -ne 'alive'){throw '服务会话身份无法确认，未接回系统入口。'}
    foreach($system in @($session.BeforeSystem,$session.TargetSystem)){
        foreach($field in @('Flags','Server','Bypass')){if($null -eq $system.PSObject.Properties[$field]){throw '系统恢复记录不完整，未接回入口。'}}
    }
    foreach($environment in @($session.BeforeEnv,$session.TargetEnv)){
        foreach($field in $script:ProxyNames){if($null -eq $environment.PSObject.Properties[$field]){throw '用户环境恢复记录不完整，未接回入口。'}}
    }
    [pscustomobject]@{Image=$image;Session=$session}
}
function Get-ProgramRouteAccessReadiness([string]$GatewayKey,[switch]$AllowBlockedDefault) {
    $profile=Get-Profile $GatewayKey
    $tcp=Get-TcpObservationSnapshot
    $observation=Get-LocalEndpointObservation (Get-EndpointAddress $profile) $tcp $profile
    if(-not $observation -or $observation.Ready -ne $true){throw '流向监听或端口归属尚未确认，未接回入口。请在“代理入口 → 备用与服务 → 使用流向独立入口”检查并启动已配置服务（保留专线），再重新检查程序线路。'}
    $session=Get-ProgramRouteAccessSession
    $owned=Read-RuleMaintenanceJson (Read-RuleMaintenanceFile (Join-Path $script:DataRoot 'gateway\process.json')) $null
    $listener=Get-Listener $profile -TcpRows $tcp.Rows
    if(-not $owned -or -not $owned.coreStartTicks -or $owned.supervisor -ne $session.Session.SupervisorPID -or [string]$owned.supervisorStartTicks -cne [string]$session.Session.SupervisorStart -or -not $listener -or $listener.PID -ne $owned.core -or -not (Test-SessionProcess $owned.core $owned.coreStartTicks)){throw '入口不是当前会话的已核验内核，未接回入口。'}
    $ownedEndpoint=$session.Session.TargetSystem.Server
    if($session.Session.PreserveWindowsSettings -eq $true){$ownedEndpoint=$session.Session.OwnGatewayEndpoint}
    if(-not (Test-SameRecoveryEndpoint $ownedEndpoint (Get-EndpointAddress $profile))){throw '当前恢复记录与流向入口不一致，未接回入口。'}
    if(-not (Test-GatewayRecoveryGrace $session.Session 0)){throw '流向服务心跳过期或未就绪，未接回入口。'}
    $life=Get-GatewayLifecycle
    if($life.phase -notin @('ready','degraded')){throw '流向服务正在恢复或停止，未接回入口。'}
    $live=Invoke-AppRouter @{action='status'} -TimeoutMilliseconds 9000
    if($live.tunEnabled -eq $true){throw '流向内核存在 TUN 接管；本次不会启用或修改 TUN，请先检查服务配置。'}
    if($live.available -ne $true -or $live.rulesAvailable -ne $true -or $live.mode -ne 'rule' -or $live.defaultLoaded -ne $true -or $live.effectiveDefaultRoute -in @('Unknown',$null,'') -or ($live.effectiveDefaultRoute -eq 'Blocked' -and -not $AllowBlockedDefault)){throw '默认出口或引擎规则状态未知、不可用；未改变系统入口。'}
    if($live.effectiveDefaultRoute -notin (@('Direct','Blocked')+(Get-ProfileKeys))){throw '默认实际出口不在当前配置中，未改变系统入口。'}
    [pscustomobject]@{Live=$live;Session=$session}
}
function New-ProgramRouteAccessTargets($System,$Environment,[string]$GatewayKey) {
    $profile=Get-Profile $GatewayKey;$endpoint=Get-EndpointAddress $profile
    $target=[pscustomobject]@{Flags=3;Server=$endpoint;Bypass=$System.Bypass};$targetEnv=New-EnvTarget $Environment $GatewayKey
    $tcp=Get-TcpObservationSnapshot
    # Retain proven own aliases instead of rewriting them. A prepared recovery
    # journal then recognizes an own reference even if the process exits before
    # the corresponding Windows write. Unproven address-family aliases are unknown.
    if(($System.Flags -band 2) -and (Test-SameRecoveryEndpoint $System.Server $endpoint)){
        $seen=Get-LocalEndpointObservation $System.Server $tcp $profile
        if(-not $seen -or $seen.Ready -ne $true){throw '当前自有系统入口别名的监听无法核验，请先检查入口；未使用猜测的恢复归属。'}
        $target.Server=$System.Server
    }
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){
        if(Test-SameRecoveryEndpoint ([string]$Environment.$name) $endpoint){
            $seen=Get-LocalEndpointObservation ([string]$Environment.$name) $tcp $profile
            if(-not $seen -or $seen.Ready -ne $true){throw '当前自有用户变量入口别名的监听无法核验，请先检查入口；未使用猜测的恢复归属。'}
            $targetEnv.$name=$Environment.$name
        }
    }
    [pscustomobject]@{System=$target;Environment=$targetEnv}
}
function Get-ProgramRouteAccessPlan([string]$Path,[string]$Route) {
    $plan=[pscustomobject]@{Version=1;DataDirectory=[IO.Path]::GetFullPath($script:DataRoot);Path=$Path;Route=$Route;CreatedAt=[DateTime]::UtcNow.ToString('o');Revision='';SnapshotFingerprint='';IdentityFingerprint='';FamilyPlan=$null;GatewayKey='';SystemNeedsAccess=$false;EnvironmentNeedsAccess=$false;DefaultRoute='';EffectiveDefaultRoute='';CanApply=$false;BlockedReason='';Message='';Impact=''}
    try{
        $path=Resolve-ProgramTarget $Path;Assert-ManagedRoute $Route -AllowFollow
        $snapshot=Get-RuleMaintenanceSnapshot '';$bound=Get-RuleMaintenanceProfiles $snapshot
        if((ConvertTo-RoutingComparableValue $bound|ConvertTo-Json -Depth 16 -Compress) -cne (ConvertTo-RoutingComparableValue $script:Profiles|ConvertTo-Json -Depth 16 -Compress)){throw '代理配置已改变，请刷新后重新预览。'}
        if($bound.Routing.Adapter -ne 'standalone'){throw '该检查仅用于已运行的流向独立服务。请在“代理入口 → 备用与服务 → 使用流向独立入口”明确配置；此次不会启动或迁移第三方引擎。'}
        $gateway=Get-GatewayKey;if(-not $gateway){throw '尚未配置流向固定入口。'}
        $context=New-ProgramIdentityContext;$identity=Get-ProgramIdentityDescriptor $path $context
        if(-not $identity.Exists -or -not $identity.FileId -or -not $identity.CanonicalPath){throw '程序文件身份无法确认，请重新添加程序。'}
        $path=[string]$identity.CanonicalPath
        foreach($profile in $bound.Profiles){if((Test-ProgramPathEquivalent $profile.AppPath $path $context) -or (Test-ProgramPathEquivalent $profile.CorePath $path $context)){throw '不能接管代理程序自身，以免形成回路。'}}
        $rootEntries=@($snapshot.Engine.entries|Where-Object {$_.path -ieq $path -or (Test-ProgramPathEquivalent $_.path $path $context)})
        if($rootEntries.Count -gt 1 -or @($rootEntries|Where-Object {$_.path -ine $path -or ($_.identity.FileId -and $_.identity.FileId -cne $identity.FileId)}).Count){throw '程序存在别名、重复或身份变更记录，请先修复程序记录。'}
        if(@(@($snapshot.Engine.programIngresses)+@($snapshot.Launch.entries)|Where-Object {$_.path -ieq $path -or (Test-ProgramPathEquivalent $_.path $path $context)}).Count){throw '此程序使用固定程序入口或启动适配；请按已保存线路打开，不转换成引擎路径规则。'}
        $system=Get-SystemSnapshot;$environment=Get-UserProxyEnv
        if(-not $system -or -not $environment){throw '系统入口或用户环境无法读取，未使用猜测的快照。'}
        if(($system.Flags -band 2) -and $system.Flags -ne 3 -and (Test-SameRecoveryEndpoint $system.Server (Get-EndpointAddress (Get-Profile $gateway)))){throw '当前自有入口混用 PAC/自动或其他代理模式，无法安全确认恢复归属；请先在检查与维护核对系统代理模式，本次未改入口。'}
        $revision=Get-NetworkRepairRevision $system $environment
        $client=Get-ClientInterference;if($client.Tun -or $client.Guard){throw '其他客户端的 TUN 或持续代理守卫仍开启，请先关闭相应接管开关。'}
        $ready=Get-ProgramRouteAccessReadiness $gateway -AllowBlockedDefault:($Route -ne 'Follow')
        if($ready.Live.defaultRoute -cne $snapshot.Engine.defaultRoute){throw '默认规则尚未与保存配置一致，请先检查引擎。'}
        $familyRoute=$Route;if($Route -eq 'Follow'){$familyRoute='Direct'}
        $family=Get-ProgramFamilyRoutePlan $path $familyRoute
        foreach($member in @($family.Members)){
            if($member.Path -ieq $path){$action='所选程序将修改';$reason=$(if($Route -eq 'Follow'){'撤回此程序专线并跟随默认；不改子程序专线。'}else{'将所选程序明确设为当前目标线路。'})}
            elseif($Route -eq 'Follow'){$action='保留现状';$reason='跟随只撤回所选程序专线，不补齐或改写此子程序。'}
            elseif($member.State -eq 'Missing'){$action='补齐子程序';$reason=$member.Reason}
            elseif($member.State -eq 'Conflict'){$action='保留子程序冲突';$reason=$member.Reason}
            else{$action='保留已有子程序线路';$reason=$member.Reason}
            $member|Add-Member NoteProperty DisplayAction $action -Force;$member|Add-Member NoteProperty DisplayReason $reason -Force
        }
        $family.ConflictCount=@($family.Members|Where-Object {$_.Path -ine $path -and $_.State -eq 'Conflict'}).Count
        $family.MissingCount=$(if($Route -eq 'Follow'){0}else{@($family.Members|Where-Object {$_.Path -ine $path -and $_.State -eq 'Missing'}).Count})
        if($family.SnapshotFingerprint -cne $snapshot.Fingerprint){throw '预览期间程序配置已改变，请重新预览。'}
        if($revision -cne (Get-NetworkRepairRevision (Get-SystemSnapshot) (Get-UserProxyEnv))){throw '预览期间入口或用户环境已改变，请重新预览。'}
        $accessTargets=New-ProgramRouteAccessTargets $system $environment $gateway;$target=$accessTargets.System;$targetEnv=$accessTargets.Environment
        $plan.Path=$path;$plan.Revision=$revision;$plan.SnapshotFingerprint=$snapshot.Fingerprint;$plan.IdentityFingerprint=(Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes ([ordered]@{Path=$path;FileId=$identity.FileId})))
        $plan.FamilyPlan=$family;$plan.GatewayKey=$gateway;$plan.SystemNeedsAccess=-not (Test-SameSnapshot $system $target);$plan.EnvironmentNeedsAccess=-not (Test-SameEnv $environment $targetEnv)
        $plan.DefaultRoute=$snapshot.Engine.defaultRoute;$plan.EffectiveDefaultRoute=$ready.Live.effectiveDefaultRoute;$plan.CanApply=$true
        $count=$(if($Route -eq 'Follow'){0}else{@($family.Members|Where-Object {$_.State -eq 'Missing' -and $_.Path -ine $path}).Count})
        $plan.Message=('将此程序设为“'+(Get-RouteName $Route)+'”，补齐 '+$count+' 个已验证子程序；保留冲突成员和未知成员。')
        $plan.Impact=('系统入口'+$(if($plan.SystemNeedsAccess){'将接回流向'}else{'已接入流向'})+'；用户代理变量'+$(if($plan.EnvironmentNeedsAccess){'将同步到流向'}else{'已一致'})+'。其他程序继续使用当前默认实际出口“'+(Get-RouteName $plan.EffectiveDefaultRoute)+'”；保留备用选择、专线、网站规则和启动方式。接回是全局入口改动，不是只改游戏。只影响进入流向的新请求，旧连接、缓存、UDP、第三方 VPN 隧道及登录结果尚未核验；不会退出任何程序或修改第三方开关。')
        if(Test-BroadProxyBypass $environment.NO_PROXY){$plan.Impact+=' '+(Get-BroadProxyBypassWarning)}
        if($plan.EffectiveDefaultRoute -eq 'Blocked'){$plan.Impact+=' 当前默认代理出口已暂停；只应用此程序的明确线路，其他跟随默认的程序尚未恢复。'}
        if($system.Flags -band 12){$plan.Impact+=' 本次接回会关闭当前系统 PAC/自动检测并使用流向手动入口；撤回可恢复原模式。'}
    }catch{$plan.CanApply=$false;$plan.BlockedReason=$_.Exception.Message;$plan.Message=$plan.BlockedReason}
    $plan
}
function Assert-ProgramRouteAccessPlan($Plan,$Fresh) {
    if(-not $Fresh.CanApply){throw $Fresh.BlockedReason}
    foreach($field in @('Path','Route','Revision','SnapshotFingerprint','IdentityFingerprint','GatewayKey','DefaultRoute','EffectiveDefaultRoute')){
        if([string]$Fresh.$field -cne [string]$Plan.$field){throw '入口、配置、实际出口或程序身份已改变，请重新检查并确认。'}
    }
    if($Fresh.FamilyPlan.EvidenceFingerprint -cne $Plan.FamilyPlan.EvidenceFingerprint){throw '进程成员或文件身份已改变，请重新检查并确认。'}
}
function Get-ProgramRouteAccessFamilyIdentityHash($Family) {
    # Rule state necessarily changes during our commit. Process/file evidence must not.
    $value=[ordered]@{UnknownIds=@($Family.UnknownIds);Members=@($Family.Members|ForEach-Object {[ordered]@{Path=$_.Path;FileId=$_.FileId;Processes=$_.Processes}})}
    Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes $value)
}
function New-ProgramRouteAccessSession($Session,$BeforeSystem,$BeforeEnv,$TargetSystem,$TargetEnv) {
    $next=Copy-RoutingSnapshot $Session
    if(Test-SameSnapshot $BeforeSystem $Session.TargetSystem){$next.BeforeSystem=Copy-RoutingSnapshot $Session.BeforeSystem}
    elseif(($BeforeSystem.Flags -band 2) -and (Test-SameRecoveryEndpoint $BeforeSystem.Server $Session.TargetSystem.Server)){
        $next.BeforeSystem=Copy-RoutingSnapshot $Session.BeforeSystem;$next.BeforeSystem.Flags=(($BeforeSystem.Flags -band (-bnot 2)) -bor ($Session.BeforeSystem.Flags -band 2));$next.BeforeSystem.Bypass=$BeforeSystem.Bypass
    }else{$next.BeforeSystem=Copy-RoutingSnapshot $BeforeSystem}
    $values=[ordered]@{}
    foreach($name in $script:ProxyNames){
        $owned=[string]$BeforeEnv.$name -ceq [string]$Session.TargetEnv.$name
        if($name -ne 'NO_PROXY' -and (Test-SameRecoveryEndpoint ([string]$BeforeEnv.$name) $Session.TargetSystem.Server)){$owned=$true}
        $values[$name]=$(if($owned){$Session.BeforeEnv.$name}else{$BeforeEnv.$name})
    }
    $next.BeforeEnv=[pscustomobject]$values;$next.TargetSystem=Copy-RoutingSnapshot $TargetSystem;$next.TargetEnv=Copy-RoutingSnapshot $TargetEnv
    if($Session.PreserveWindowsSettings -eq $true){$next.PreserveWindowsSettings=$false;$next.BeforeSystem=Copy-RoutingSnapshot $BeforeSystem;$next.BeforeEnv=Copy-RoutingSnapshot $BeforeEnv}
    $next
}
function Set-ProgramRouteAccess($Plan,[switch]$Confirmed) {
    if(-not $Confirmed){throw '请先查看接入影响和成员预览，再确认应用。'}
    if(-not $Plan -or $Plan.Version -ne 1 -or $Plan.DataDirectory -ine [IO.Path]::GetFullPath($script:DataRoot)){throw '程序接入预览无效，请重新检查。'}
    $created=[DateTime]::MinValue
    if(-not [DateTime]::TryParse([string]$Plan.CreatedAt,[ref]$created) -or ([DateTime]::UtcNow-$created.ToUniversalTime()).TotalSeconds -gt 120 -or $created.ToUniversalTime() -gt [DateTime]::UtcNow.AddSeconds(5)){throw '程序接入预览已过期，请重新检查。'}
    Use-ChangeLock {
        $fresh=Get-ProgramRouteAccessPlan $Plan.Path $Plan.Route;Assert-ProgramRouteAccessPlan $Plan $fresh
        Assert-ClientCompatibility $fresh.GatewayKey $true
        if($fresh.Route -notin @('Direct','Follow') -and (Test-ProxyRoute $fresh.Route -Fast).Usable -ne $true){throw '目标代理检测未通过，未接回入口或修改规则。'}
        $rechecked=Get-ProgramRouteAccessPlan $fresh.Path $fresh.Route;Assert-ProgramRouteAccessPlan $fresh $rechecked
        $before=Get-RoutingSnapshot;$system=Get-SystemSnapshot;$environment=Get-UserProxyEnv
        if((Get-NetworkRepairRevision $system $environment) -cne $fresh.Revision){throw '提交前入口或配置已改变，请重新预览。'}
        $original=Get-ProgramRouteAccessSession;$next=Copy-RoutingSnapshot $before
        $next.entries=@($next.entries|Where-Object {$_.path -ine $fresh.Path})
        $added=@();$targets=@()
        if($fresh.Route -ne 'Follow'){
            $identity=Get-ProgramIdentityDescriptor $fresh.Path (New-ProgramIdentityContext)
            $identityHash=Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes ([ordered]@{Path=$identity.CanonicalPath;FileId=$identity.FileId}))
            if($identityHash -cne $fresh.IdentityFingerprint){throw '提交前程序身份已改变，请重新检查。'}
            $targets+=@([pscustomobject]@{path=$fresh.Path;route=$fresh.Route;identity=$identity})
            $added=@($fresh.FamilyPlan.Members|Where-Object {$_.State -eq 'Missing' -and $_.Path -ine $fresh.Path})
            foreach($member in $added){$targets+=@([pscustomobject]@{path=$member.Path;route=$fresh.Route;identity=$member.Identity})}
            $next.entries+=@($targets)
        }
        $accessTargets=New-ProgramRouteAccessTargets $system $environment $fresh.GatewayKey;$targetSystem=$accessTargets.System;$targetEnv=$accessTargets.Environment
        $claim=New-ProgramRouteAccessSession $original.Session $system $environment $targetSystem $targetEnv
        $state=[pscustomobject]@{ClaimHash='';ExpectedSessionHash=$original.Image.Hash;Original=$original.Image;Backup=$null}
        $verify={
            $client=Get-ClientInterference;if($client.Tun -or $client.Guard){throw '检查期间其他客户端开启 TUN 或持续代理守卫，未确认接入。'}
            $ready=Get-ProgramRouteAccessReadiness $fresh.GatewayKey -AllowBlockedDefault:($fresh.Route -ne 'Follow');$live=$ready.Live
            if(-not (Test-SameRouting $next (Get-RoutingSnapshot))){throw '载入期间程序规则或启动设置已改变，保留最新记录。'}
            $familyNow=Get-ProgramFamilyRoutePlan $fresh.Path $(if($fresh.Route -eq 'Follow'){'Direct'}else{$fresh.Route})
            if((Get-ProgramRouteAccessFamilyIdentityHash $familyNow) -cne (Get-ProgramRouteAccessFamilyIdentityHash $fresh.FamilyPlan)){throw '载入期间进程成员或文件身份已改变，未接回入口。'}
            $rootNow=Get-ProgramIdentityDescriptor $fresh.Path (New-ProgramIdentityContext)
            if((Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes ([ordered]@{Path=$rootNow.CanonicalPath;FileId=$rootNow.FileId}))) -cne $fresh.IdentityFingerprint){throw '载入期间主程序身份已改变，未接回入口。'}
            if($live.defaultRoute -cne $fresh.DefaultRoute -or $live.effectiveDefaultRoute -cne $fresh.EffectiveDefaultRoute){throw '当前有效默认出口改变，不能确认接入。'}
            foreach($entry in $targets){
                $loaded=@($live.entries|Where-Object {$_.path -ieq $entry.path -and $_.route -ceq $entry.route -and $_.loaded -eq $true})
                if($loaded.Count -ne 1){throw '程序或子程序规则未载入，不能确认接入。'}
                if($loaded[0].effectiveRoute -in @('Blocked','Unknown',$null,'') -or $loaded[0].effectiveRoute -notin (@('Direct')+(Get-ProfileKeys)) -or ($entry.route -eq 'Direct' -and $loaded[0].effectiveRoute -ne 'Direct')){throw '程序实际出口尚未就绪，不能确认接入。'}
            }
            if($fresh.Route -eq 'Follow' -and @($live.entries|Where-Object {$_.path -ieq $fresh.Path}).Count){throw '程序专线未撤回，不能确认跟随。'}
            if(@($next.siteRules|Where-Object {$_}).Count -and $live.siteRulesLoaded -ne $true){throw '网站规则无法确认载入，未接回入口。'}
            if((Read-RuleMaintenanceFile $original.Image.Path).Hash -cne $state.ExpectedSessionHash){throw '服务恢复记录已改变，保留最新会话。'}
        }
        $preWindows={
            & $verify
            $bytes=ConvertTo-RuleMaintenanceBytes $claim
            $state.ClaimHash=Get-RuleMaintenanceHash $bytes
            Set-RuleMaintenanceFile $original.Image $bytes $false
            $state.ExpectedSessionHash=$state.ClaimHash
            if((Read-RuleMaintenanceFile $original.Image.Path).Hash -cne $state.ClaimHash){throw '恢复归属记录写后核验失败，不能确认完成。'}
        }
        $postCommit={
            & $verify
            if(-not (Test-SameSnapshot $targetSystem (Get-SystemSnapshot)) -or -not (Test-SameEnv $targetEnv (Get-UserProxyEnv))){throw '接入完成前外部再次修改入口，不能确认完成。'}
        }
        try{$state.Backup=Invoke-ProxyTransaction $targetSystem $targetEnv $null $system $environment $next $before $verify -PreserveSelection -PreWindowsAction $preWindows -PostCommitAction $postCommit}
        catch{
            $failure=$_.Exception.Message
            if($state.ClaimHash){
                # If the native rollback is incomplete, retain the fresh recovery claim.
                # Never replace an outside session, or erase ownership of a still-live entry.
                $current=Read-RuleMaintenanceFile $original.Image.Path
                if($current.Hash -ceq $state.ClaimHash -and (Test-SameSnapshot $system (Get-SystemSnapshot)) -and (Test-SameEnv $environment (Get-UserProxyEnv))){
                    try{Set-RuleMaintenanceFile $current $original.Image.Bytes $false}catch{$failure+='；恢复会话归属未能回退，保留记录，请检查服务。'}
                }else{$failure+='；保留当前服务恢复记录，未覆盖外部变化或未完成的恢复。'}
            }
            throw $failure
        }
        [pscustomobject]@{Backup=$state.Backup;AddedCount=$added.Count;ConflictCount=$fresh.FamilyPlan.ConflictCount;UnknownIds=$fresh.FamilyPlan.UnknownIds;GatewayKey=$fresh.GatewayKey;EffectiveDefaultRoute=$fresh.EffectiveDefaultRoute;Message=('程序线路和流向接入已实读核验；补齐 '+$added.Count+' 个已验证子程序，保留其他专线、有效备用及网站规则。'+$(if($fresh.EffectiveDefaultRoute -eq 'Blocked'){' 默认代理出口仍暂停，其他跟随程序尚未恢复。'}else{''})+'请在程序内重试并观察新连接；若仍使用旧地址，请保存后完整重开。未结束程序、未重建旧连接，也未验证登录或第三方 VPN 隧道已绕过。')}
    }
}
function Invoke-ProgramRouteAccess($Plan,[switch]$Confirmed){Set-ProgramRouteAccess -Plan $Plan -Confirmed:$Confirmed}

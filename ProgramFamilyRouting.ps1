# Explicit, additive family routing. Previews contain local process evidence only and are never persisted.
# Get-ProgramFamilyRoutePlan -Path <root exe> -Route <Direct/profile id> returns Members, counts and a revision.
# Set-ProgramFamilyRoute -Plan <unchanged preview> -Confirmed re-observes the family and adds Missing rows once.
function Get-ProgramFamilyRoutePlan([string]$Path,[string]$Route) {
    $executable=Resolve-ProgramTarget $Path
    Assert-ManagedRoute $Route
    $snapshot=Get-RuleMaintenanceSnapshot ''
    $profiles=Get-RuleMaintenanceProfiles $snapshot
    if($Route -ne 'Direct' -and $Route -notin @($profiles.Profiles.Id)){throw '所选线路已改变，请刷新后重新预览。'}
    $started=[DateTime]::UtcNow
    try{$processes=@(Get-ProcessInventory)}catch{throw '进程身份读取失败，无法预览整组程序；未修改规则。'}
    $context=New-ProgramIdentityContext -Processes $processes
    $context.Created=$started
    . (Join-Path $PSScriptRoot 'ProgramFamilyTracking.ps1')
    $family=Get-ProgramFamilyTrackingSnapshot $executable $processes $context
    $root=Get-ProgramIdentityDescriptor $executable $context
    if(-not $root.Exists -or -not $root.FileId -or -not $root.CanonicalPath){throw '主程序文件身份不可核验，无法预览整组规则。'}
    $directory=[IO.Path]::GetDirectoryName($root.CanonicalPath)+'\'
    $members=@();$unknown=@($family.UnknownIds);$groups=@{}
    foreach($process in @($family.Members)){
        $identity=Get-ProgramIdentityDescriptor $process.Path $context
        $ticks=0L
        if($process.StartTime -and [DateTime]$process.StartTime -ne [DateTime]::MinValue){$ticks=([DateTime]$process.StartTime).ToUniversalTime().Ticks}
        if($process.PathStatus -ne 'Available' -or $ticks -le 0 -or -not $identity.Exists -or -not $identity.FileId -or -not $identity.CanonicalPath -or -not $identity.CanonicalPath.StartsWith($directory,[StringComparison]::OrdinalIgnoreCase)){
            $unknown+=@([int]$process.Id);continue
        }
        $canonical=[string]$identity.CanonicalPath
        if(-not $groups.ContainsKey($canonical)){$groups[$canonical]=[pscustomobject]@{Identity=$identity;Processes=@()}}
        $groups[$canonical].Processes+=@([pscustomobject]@{Id=[int]$process.Id;ParentId=[int]$process.ParentId;StartTicks=$ticks;Path=(ConvertTo-ProgramIdentityPath $process.Path);FileId=[string]$identity.FileId})
    }
    foreach($canonical in @($groups.Keys|Sort-Object)){
        $group=$groups[$canonical];$records=@()
        foreach($source in @('entries','programIngresses','launchEntries')){
            $saved=$(if($source -eq 'launchEntries'){@($snapshot.Launch.entries)}else{@($snapshot.Engine.$source)})
            foreach($entry in @($saved|Where-Object {$_ -and $_.path})){
                if($entry.path -ieq $canonical -or (Test-ProgramPathEquivalent $entry.path $canonical $context)){
                    $records+=@([pscustomobject]@{Source=$source;Path=[string]$entry.path;Route=[string]$entry.route;Identity=$entry.identity})
                }
            }
        }
        $state='Missing';$reason='已验证父子身份；缺少专用引擎规则，可补齐。'
        $active=@($records|Where-Object {$_.Route -ne 'Follow'})
        $engines=@($records|Where-Object {$_.Source -ne 'launchEntries'})
        $conflicting=@($records|Where-Object {$_.Path -ine $canonical -or ($_.Identity.FileId -and $_.Identity.FileId -cne $group.Identity.FileId)})
        if(@($profiles.Profiles|Where-Object {(Test-ProgramPathEquivalent $_.CorePath $canonical $context) -or (Test-ProgramPathEquivalent $_.AppPath $canonical $context)}).Count){$state='Conflict';$reason='这是代理程序自身，保留原规则，不能加入整组分流。'}
        elseif($conflicting.Count -or $engines.Count -gt 1 -or @($records|Where-Object Source -eq 'launchEntries').Count -gt 1){$state='Conflict';$reason='存在别名、重复记录或文件身份变更，保留原记录，请单独处理。'}
        elseif(@($active|Where-Object Route -ne $Route).Count -or @($engines|Where-Object Route -eq 'Follow').Count){$state='Conflict';$reason='已单独选择其他线路或跟随，保留专用选择。'}
        elseif($engines.Count){$state='Covered';$reason='已有相同目标的规则，保持现有入口与选择。'}
        elseif(@($active|Where-Object Source -eq 'launchEntries').Count){$state='Conflict';$reason='已有独立启动代理记录，保留启动方式，请单独调整。'}
        $members+=@([pscustomobject]@{Path=$canonical;Name=[IO.Path]::GetFileName($canonical);FileId=[string]$group.Identity.FileId;Identity=$group.Identity;Processes=@($group.Processes|Sort-Object Id,StartTicks);State=$state;ExistingRoutes=@($records|ForEach-Object {$_.Route}|Select-Object -Unique);Records=$records;Reason=$reason;TargetRoute=$Route})
    }
    if((Get-RuleMaintenanceSnapshot '').Fingerprint -cne $snapshot.Fingerprint){throw '预览期间程序或代理配置已改变，请重新预览。'}
    $evidence=[ordered]@{Path=$executable;Route=$Route;RootFileId=$root.FileId;RootCanonicalPath=$root.CanonicalPath;UnknownIds=@($unknown|Sort-Object -Unique);Members=@($members|ForEach-Object {[ordered]@{Path=$_.Path;FileId=$_.FileId;Processes=$_.Processes;State=$_.State}})}
    [pscustomobject]@{Version=1;DataDirectory=[IO.Path]::GetFullPath($script:DataRoot);Path=$executable;Route=$Route;CreatedAt=[DateTime]::UtcNow.ToString('o');SnapshotFingerprint=$snapshot.Fingerprint;EvidenceFingerprint=(Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes $evidence));Members=$members;MissingCount=@($members|Where-Object State -eq 'Missing').Count;CoveredCount=@($members|Where-Object State -eq 'Covered').Count;ConflictCount=@($members|Where-Object State -eq 'Conflict').Count;UnknownIds=@($unknown|Sort-Object -Unique);CanApply=(@($members|Where-Object State -eq 'Missing').Count -gt 0);Message='仅补齐本次已验证的同安装目录父子程序；保留冲突的专用线路。规则只影响进入流向的新连接，不会退出程序、清理登录会话或绕过系统代理。'}
}
function Set-ProgramFamilyRoute($Plan,[switch]$Confirmed) {
    if(-not $Confirmed){throw '请先查看整组成员和冲突，再确认补齐规则。'}
    if(-not $Plan -or $Plan.Version -ne 1 -or $Plan.DataDirectory -ine [IO.Path]::GetFullPath($script:DataRoot)){throw '整组规则预览无效，请重新预览。'}
    $created=[DateTime]::MinValue
    if(-not [DateTime]::TryParse([string]$Plan.CreatedAt,[ref]$created) -or ([DateTime]::UtcNow-$created.ToUniversalTime()).TotalSeconds -gt 120 -or $created.ToUniversalTime() -gt [DateTime]::UtcNow.AddSeconds(5)){throw '整组规则预览已过期，请重新预览。'}
    Use-ChangeLock {
        $fresh=Get-ProgramFamilyRoutePlan $Plan.Path $Plan.Route
        if($fresh.SnapshotFingerprint -cne $Plan.SnapshotFingerprint){throw '程序或代理配置已改变，请重新预览；保留最新规则。'}
        if($fresh.EvidenceFingerprint -cne $Plan.EvidenceFingerprint){throw '进程成员或文件身份已改变，请重新预览；未应用旧成员列表。'}
        if(-not $fresh.CanApply){throw '没有可补齐的已验证成员；已有规则和冲突保持不变。'}
        $snapshot=Get-RuleMaintenanceSnapshot ''
        if($snapshot.Fingerprint -cne $fresh.SnapshotFingerprint){throw '程序配置已改变，请重新预览。'}
        # This explicit repair must not start/migrate an engine or change Windows settings.
        Assert-RuleMaintenanceEngine $snapshot
        if($fresh.Route -ne 'Direct' -and -not (Test-ProxyRoute $fresh.Route -Fast).Usable){throw '目标代理检测未通过，未补齐规则。'}
        # Check identity after potentially slow control/proxy calls as well as before them.
        $rechecked=Get-ProgramFamilyRoutePlan $fresh.Path $fresh.Route
        if($rechecked.SnapshotFingerprint -cne $fresh.SnapshotFingerprint -or $rechecked.EvidenceFingerprint -cne $fresh.EvidenceFingerprint){throw '检查期间进程或配置已改变，请重新预览。'}
        $before=Get-RoutingSnapshot
        if((Get-RuleMaintenanceSnapshot '').Fingerprint -cne $fresh.SnapshotFingerprint){throw '程序配置已改变，请重新预览。'}
        $next=Copy-RoutingSnapshot $before
        $added=@($fresh.Members|Where-Object State -eq 'Missing')
        foreach($member in $added){$next.entries+=@([pscustomobject]@{path=$member.Path;route=$fresh.Route;identity=$member.Identity})}
        # Retain the complete snapshot for the shared transaction's ownership/rollback check.
        # No existing launch target or unrelated default/ingress selector is changed.
        $verify={
            $live=Invoke-AppRouter @{action='status'}
            if(-not $live.available -or -not $live.rulesAvailable -or $live.mode -ne 'rule'){throw '整组规则无法通过引擎实读校验。'}
            foreach($member in $added){
                $loaded=@($live.entries|Where-Object {$_.path -ieq $member.Path -and $_.route -eq $fresh.Route -and $_.loaded -eq $true})
                if($loaded.Count -ne 1){throw '部分整组规则未载入，不能确认补齐成功。'}
            }
        }
        $backup=Invoke-ManagedRoutingChange $before $next $verify
        [pscustomobject]@{Backup=$backup;AddedCount=$added.Count;PreservedCount=($fresh.CoveredCount+$fresh.ConflictCount);ConflictCount=$fresh.ConflictCount;UnknownIds=$fresh.UnknownIds;Message=('已补齐 '+$added.Count+' 个程序的规则，并核对引擎载入；保留 '+$fresh.ConflictCount+' 个冲突成员的原选择。请在程序内重试并观察新连接；旧连接和登录会话未改变，尚未验证登录成功。')}
    }
}

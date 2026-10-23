# Explicit recovery only. Context and receipts are private; reports and events are redacted.
function Get-NetworkRecoveryReceiptPath {Join-Path $script:DataRoot 'recovery\network-recovery-receipt.json'}
function Get-NetworkRecoveryEventPath {Join-Path $script:DataRoot 'recovery\network-recovery-events.json'}
function Initialize-NetworkRecoveryPrivateDirectory {
    $directory=Join-Path $script:DataRoot 'recovery';$cursor=[IO.Path]::GetFullPath($directory)
    while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){Stop-NetworkRecovery 'ReceiptFailed'};$cursor=[IO.Path]::GetDirectoryName($cursor)}
    [void][IO.Directory]::CreateDirectory($directory)
    $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))){
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    [IO.Directory]::SetAccessControl($directory,$acl)
}
function Get-NetworkRecoveryValue($Value,[string]$Name,$Default=$null) {
    if($null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]){return $Value.$Name};$Default
}
function Copy-NetworkRecoveryValue($Value) {if($null -ne $Value){$Value|ConvertTo-Json -Depth 32|ConvertFrom-Json}}
function Get-NetworkRecoveryCodeMessage([string]$Code) {
    switch($Code){
        'ConfirmationRequired' {'请先预览并明确确认本次恢复。'}
        'PlanExpired' {'恢复预览已过期或无效，请重新预览。'}
        'StateChanged' {'预览后的系统、环境、配置或恢复归属已变化；未覆盖新设置，请重新检查。'}
        'SessionOwnsSettings' {'存在流向入口会话或待恢复归属。请从右下角流向托盘选择“停止代理服务并退出”，重新打开后再检查，避免旧恢复覆盖新设置。'}
        'CleanStartOwnsSettings' {'启动对照仍在运行或恢复状态未知。请到“检查与维护 → 维护与恢复 → 结束对照并恢复”，确认完成后再重新预览。'}
        'NativeCapabilityMissing' {'当前组件无法完整读取自动代理，请使用完整程序包重新预览。'}
        'ObservationUnavailable' {'设置读取不完整，未进行恢复；请重新检查。'}
        'TargetRequired' {'请明确选择一个已登记代理；不会从混合的系统与环境设置猜测目标。'}
        'TargetUnavailable' {'所选代理尚未通过正式切换预检；请在原客户端检查入口后重新预览。'}
        'BackupFailed' {'恢复备份未完成，未更改代理设置。'}
        'ReceiptFailed' {'无法保存恢复归属收据，未更改代理设置。'}
        'ReceiptIncomplete' {'线路操作已提交，但完整收据尚未写完；已保留本机备份与中间收据。请重新检查当前设置，暂不重复操作。'}
        'ApplyFailed' {'恢复未完成；已按归属回退仍属于本次的设置，外部修改已保留。请重新检查。'}
        'RollbackIncomplete' {'恢复未完成且部分回退未能核实。已保留本机备份与收据，请重新检查当前设置。'}
        'UndoUnavailable' {'没有可以安全撤回的最近恢复记录。'}
        'UndoTargetUnavailable' {'原入口已停止、卸载、未知或归属变化，不能撤回到可能断网的旧设置。请先在原客户端恢复有效入口。'}
        'UndoAutomaticUnsupported' {'原设置含自动代理或不一致的代理视图，无法验证可达性，未恢复旧自动模式。'}
        'Partial' {'已重置当前用户应用代理层；隧道、守卫或机器代理仍需处理，尚不能确认普通上网已恢复。'}
        'Applied' {'当前用户应用代理层已按方案恢复并复读确认。实际网站、账号与已运行程序仍需分别检查。'}
        'NoChange' {'当前用户应用代理层已符合目标，无需重复修改；实际联网尚未验证。'}
        default {'请重新检查当前网络设置。'}
    }
}
function Stop-NetworkRecovery([string]$Code) {throw ('NetworkRecovery:'+ $Code)}
function Get-NetworkRecoveryFailureCode($ErrorRecord,[string]$Default='ApplyFailed') {
    $text=[string]$ErrorRecord.Exception.Message
    if($text -match 'NetworkRecovery:([A-Za-z]+)'){return $Matches[1]};$Default
}
function Get-NetworkRecoveryMachineStatus {
    if(Get-Command Get-NetworkRecoveryAdminStatus -ErrorAction SilentlyContinue){return Get-NetworkRecoveryAdminStatus}
    [pscustomobject]@{State='Unavailable';NeedsRepair=$false;WinHttpState='Unknown';Revision='';EnvironmentNames=@();Message='机器级代理尚未检查；请使用完整程序包继续检查。'}
}
function Get-NetworkRecoveryContext {
    # Hash malformed/missing configuration as bytes. Direct never needs to parse profiles.
    $files=[ordered]@{}
    foreach($name in @('config.json','app-rules.json','program-proxies.json','program-shortcuts.json','selection.json','gateway-session.json','clean-start-current.json','daily-proxy-receipt.json')){
        $files[$name]=(Read-RuleMaintenanceFile (Join-Path $script:DataRoot $name)).Hash
    }
    $files['network-recovery-receipt.json']=(Read-RuleMaintenanceFile (Get-NetworkRecoveryReceiptPath)).Hash
    $system=Copy-NetworkRecoveryValue (Get-SystemSnapshot)
    $envs=Copy-NetworkRecoveryValue (Get-UserProxyEnv)
    $views=Get-DailyProxyWindowsViews $system
    $client=Get-ClientInterference
    $topology=Get-NetworkRecoveryValue $client 'Topology'
    $clean='None'
    if($files['clean-start-current.json'] -ne '<missing>'){
        try{if(Test-CleanStartSessionFinished (Get-CleanStartSession)){$clean='Finished'}else{$clean='Active'}}catch{$clean='Unknown'}
    }
    $machine=Get-NetworkRecoveryMachineStatus
    $topologyState=if((Get-NetworkRecoveryValue $topology 'Available' $false) -eq $true){[string](Get-NetworkRecoveryValue $topology 'State' 'Unknown')}else{'Unknown'}
    [pscustomobject]@{System=$system;Environment=$envs;WindowsViews=$views;Files=[pscustomobject]$files;CleanStart=$clean;Client=[pscustomobject]@{Tun=[bool]$client.Tun;Guard=[bool]$client.Guard;Topology=$topologyState};Machine=[pscustomobject]@{State=[string]$machine.State;NeedsRepair=[bool]$machine.NeedsRepair;Revision=[string]$machine.Revision;WinHttpState=[string]$machine.WinHttpState}}
}
function Get-NetworkRecoveryContextCode($Context) {
    if($Context.Files.'gateway-session.json' -ne '<missing>'){return 'SessionOwnsSettings'}
    if($Context.CleanStart -notin @('None','Finished')){return 'CleanStartOwnsSettings'}
    if($null -eq $Context.System.PSObject.Properties['AutoConfigUrl']){return 'NativeCapabilityMissing'}
    if(-not $Context.WindowsViews.Registry.Available -or -not $Context.WindowsViews.WinHttpIE.Available){return 'ObservationUnavailable'}
    ''
}
function Test-NetworkRecoveryDirect($Context) {
    if(($Context.System.Flags -band 14) -or [string]$Context.System.AutoConfigUrl){return $false}
    if(-not (Test-DailyProxyWindowsTarget $Context.System $Context.WindowsViews 'Direct')){return $false}
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){if(-not [string]::IsNullOrEmpty([string]$Context.Environment.$name)){return $false}}
    $true
}
function Test-NetworkRecoveryPartial($Context) {
    ($Context.Client.Tun -or $Context.Client.Guard -or $Context.Client.Topology -ne 'NoEvidence' -or $Context.Machine.State -ne 'Available' -or $Context.Machine.NeedsRepair)
}
function Get-NetworkRecoveryEndpointSummary([string]$Value,$Tcp) {
    if([string]::IsNullOrEmpty($Value)){return 'Unset'}
    $observation=Get-LocalEndpointObservation $Value $Tcp
    if(-not $observation){return 'Unsupported'}
    if($observation.Listening -eq $true){return 'Listening'}
    if($observation.Listening -eq $false -or $observation.Ready -eq $false){return 'Stopped'}
    'Unknown'
}
function Start-NetworkRecoveryDirectProbe([string]$Url) {
    if($Url -notin @('https://www.baidu.com/','https://www.microsoft.com/')){Stop-NetworkRecovery 'TargetRequired'}
    $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=Get-SystemCurlPath
    $start.Arguments='--disable --silent --show-error --head --output NUL --connect-timeout 6 --max-time 10 --proxy "" --noproxy "*" --write-out "%{http_code} %{time_total} %{http_connect}" '+$Url
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start
    try{[void]$process.Start();[pscustomobject]@{Process=$process;Output=$process.StandardOutput.ReadToEndAsync();Error=$process.StandardError.ReadToEndAsync()}}catch{$process.Dispose();throw}
}
function Test-NetworkRecoveryDirectTargets {
    $probes=@();$results=@();$clock=[Diagnostics.Stopwatch]::StartNew()
    try{
        foreach($url in @('https://www.baidu.com/','https://www.microsoft.com/')){try{$probes+=Start-NetworkRecoveryDirectProbe $url}catch{$results+=[pscustomobject]@{Stage='probe-unavailable';HttpCode=0}}}
        foreach($probe in $probes){
            $remaining=[Math]::Max(0,12000-[int]$clock.ElapsedMilliseconds)
            if(-not $probe.Process.HasExited -and -not $probe.Process.WaitForExit($remaining)){$results+=[pscustomobject]@{Stage='probe-timeout';HttpCode=0};continue}
            $parts=$probe.Output.Result.Trim() -split '\s+';$code=0;[void][int]::TryParse($parts[0],[ref]$code)
            $stage=if($probe.Process.ExitCode -eq 0 -and $code -gt 0){'https-response'}elseif($probe.Process.ExitCode -eq 28){'probe-timeout'}else{'proxy-or-target-unreachable'}
            $results+=[pscustomobject]@{Stage=$stage;HttpCode=$code}
        }
    }finally{foreach($probe in $probes){Close-HttpEndpointProbe $probe}}
    @($results)
}
function Get-NetworkRecoveryReport([switch]$Probe,[string]$Key='') {
    $checks=@();$findings=@();$context=$null;$code='';$probeState='NotTested';$targets=@();$admin=Get-NetworkRecoveryMachineStatus
    try{
        $context=Get-NetworkRecoveryContext;$code=Get-NetworkRecoveryContextCode $context
        $tcp=Get-TcpObservationSnapshot
        $manual=[bool]($context.System.Flags -band 2)
        $systemState=if($manual){Get-NetworkRecoveryEndpointSummary $context.System.Server $tcp}else{'Disabled'}
        $checks+=[pscustomobject]@{Name='当前用户手动代理';State=$systemState;Detail='监听只证明入口存在，不代表实际请求成功。'}
        $checks+=[pscustomobject]@{Name='自动代理与自动检测';State=$(if(($context.System.Flags -band 12) -or $context.System.AutoConfigUrl -or $context.WindowsViews.WinHttpIE.HasPac -or $context.WindowsViews.WinHttpIE.AutoDetect){'Enabled'}else{'Disabled'});Detail='恢复普通上网会明确关闭 PAC 和自动检测。'}
        if($systemState -eq 'Stopped'){$findings+=[pscustomobject]@{Code='SystemEntryStopped';Message='手动代理仍开启，但本机入口已停止；可预览恢复普通上网。'}}
        foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){
            $state=Get-NetworkRecoveryEndpointSummary $context.Environment.$name $tcp
            $checks+=[pscustomobject]@{Name=('用户 '+$name);State=$state;Detail='只读取持久用户变量；已运行程序可能保留旧环境。'}
            if($state -ne 'Unset'){$findings+=[pscustomobject]@{Code=$(if($state -eq 'Stopped'){'UserEntryStopped'}elseif(-not $manual){'UserProxyWhileSystemOff'}else{'UserProxyPresent'});Message='存在用户代理变量；恢复普通上网会清除三项代理变量，并保留 NO_PROXY。'}}
        }
        if($context.WindowsViews.Summary.Different){$findings+=[pscustomobject]@{Code='WindowsViewsDiffer';Message='Windows 代理视图不一致，需要写入后重新核对。'}}
        if($context.Client.Tun -or $context.Client.Guard){$findings+=[pscustomobject]@{Code='TunnelOrGuardRemaining';Message='可重置应用代理层，但隧道或代理守卫仍需在原客户端处理；不会停止未知服务或改路由。'}}
        if($context.Client.Topology -ne 'NoEvidence'){$findings+=[pscustomobject]@{Code='TunnelNotCleared';Message='底层隧道存在证据或状态未知，应用代理层直连不代表绕过隧道。'}}
        if($code){$findings+=[pscustomobject]@{Code=$code;Message=(Get-NetworkRecoveryCodeMessage $code)}}
        if($admin.State -ne 'Available' -or $admin.NeedsRepair){$findings+=[pscustomobject]@{Code=$(if($admin.NeedsRepair){'MachineProxyRemaining'}else{'MachineNotChecked'});Message=$admin.Message}}
        if($Probe){
            # Resolve only an unambiguous current system route; mixed views require an explicit key.
            if(-not $Key -and $manual -and -not ($context.System.Flags -band 12) -and -not $context.System.AutoConfigUrl -and -not $context.WindowsViews.Summary.Different){
                try{
                    $candidate=Get-EndpointKey $context.System.Server;$aligned=($candidate -in (Get-ProfileKeys))
                    $candidateProfile=Get-Profile $candidate
                    $sameEndpoints=@(Get-ProfileKeys|ForEach-Object {Get-Profile $_}|Where-Object {$_.Protocol -eq $candidateProfile.Protocol -and $_.Port -eq $candidateProfile.Port -and ($_.Host -eq $candidateProfile.Host -or ($_.Host -in @('127.0.0.1','localhost','::1') -and $candidateProfile.Host -in @('127.0.0.1','localhost','::1')))})
                    if($sameEndpoints.Count -ne 1){$aligned=$false}
                    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){if((Get-EndpointKey $context.Environment.$name) -notin @('Unset',$candidate)){$aligned=$false}}
                    if($aligned){$Key=$candidate}
                }catch{}
            }
            if(($Key -eq 'Direct' -or -not $Key) -and (Test-NetworkRecoveryDirect $context)){
                $targets=@(Test-NetworkRecoveryDirectTargets)
                $probeState=if(@($targets|Where-Object {$_.Stage -eq 'https-response' -and $_.HttpCode -ge 200 -and $_.HttpCode -lt 400}).Count){'RequestSucceeded'}else{'RequestFailed'}
                if((Get-DailyProxyHash $context) -cne (Get-DailyProxyHash (Get-NetworkRecoveryContext))){$probeState='StateChanged';$targets=@()}
            }elseif(-not $Key -or $Key -eq 'Direct'){$probeState='TargetRequired'}else{
                try{
                    $plan=Get-DailyProxyPlan $Key
                    if($plan.Endpoint.State -ne 'Ready'){ $probeState='TargetUnavailable' }
                    else{
                        $endpointHash=Get-DailyProxyHash $plan.Endpoint
                        $targets=@(Test-NetworkTargets (Get-Profile $Key))
                        $afterProbe=Get-NetworkRecoveryContext
                        if($endpointHash -cne (Get-DailyProxyHash (Get-DailyProxyEndpoint $Key)) -or (Get-DailyProxyHash $context) -cne (Get-DailyProxyHash $afterProbe)){$probeState='StateChanged';$targets=@()}
                        else{$probeState=if(@($targets|Where-Object {$_.Stage -eq 'https-response' -and $_.HttpCode -ge 200 -and $_.HttpCode -lt 400}).Count){'RequestSucceeded'}else{'RequestFailed'}}
                    }
                }catch{$probeState='TargetUnavailable'}
            }
            $findings+=[pscustomobject]@{Code=$probeState;Message=$(if($probeState -eq 'RequestSucceeded'){'固定无账号请求取得成功响应；不代表账号或所有程序可用。'}elseif($probeState -eq 'RequestFailed'){'本轮固定请求失败；不能只凭设置或监听判断联网正常。'}else{'未执行通路请求，请明确选择并核验所需代理后再检测。'})}
        }
        if($context.Files.'network-recovery-receipt.json' -ne '<missing>'){
            try{$saved=Read-RuleMaintenanceJson (Read-RuleMaintenanceFile (Get-NetworkRecoveryReceiptPath)) $null;if($saved.Phase -in @('Prepared','UndoPrepared')){$findings+=[pscustomobject]@{Code='RecoveryInterrupted';Message='上次操作未取得完整完成收据。请按当前实读设置重新预览；不会自动重放旧恢复记录。'}}}catch{$findings+=[pscustomobject]@{Code='ReceiptUnreadable';Message='本机恢复记录无法读取，请检查当前设置和备份；不会自动采用旧记录。'}}
        }
    }catch{$code='ObservationUnavailable';$findings+=[pscustomobject]@{Code=$code;Message=(Get-NetworkRecoveryCodeMessage $code)}}
    $summary=if($code){Get-NetworkRecoveryCodeMessage $code}elseif($context -and (Test-NetworkRecoveryDirect $context)){'当前用户应用代理层为直连；实际联网状态需另行检测。'}else{'已完成应用代理层检查；选择恢复普通上网，或明确选择要恢复的代理。'}
    $safeTargets=@($targets|ForEach-Object {[pscustomobject]@{Stage=$(if($_.Stage -in @('https-response','probe-timeout','proxy-rejected','target-tls-failed','target-tls-or-timeout','proxy-or-target-unreachable','probe-unavailable')){$_.Stage}else{'probe-unavailable'});HttpCode=[int]$_.HttpCode;AuthenticationVerified=$false}})
    [pscustomobject]@{Kind='NetworkRecoveryReport';State=$(if($code){'Blocked'}elseif($findings.Count){'Attention'}else{'Checked'});Code=$code;Summary=$summary;Message=$summary;Checks=@($checks);Findings=@($findings);Issues=@($findings);Verification=[pscustomobject]@{Settings='ReadOnly';Request=$probeState;Targets=$safeTargets;AuthenticationVerified=$false};Steps=@('先预览具体恢复范围，确认后备份并执行。','复检系统、自动代理与用户变量；已运行程序请保存工作后按需正常重开。','若仍异常，继续机器级代理检查与原客户端隧道检查；实际网站和账号另行验收。');AdminStatus=$admin}
}
function Get-NetworkRecoveryPlan([ValidateSet('Direct','Proxy')][string]$Goal='Direct',[string]$Key='') {
    $context=$null;$daily=$null;$code='';$noChange=$false
    try{
        $context=Get-NetworkRecoveryContext;$code=Get-NetworkRecoveryContextCode $context
        if($Goal -eq 'Proxy'){
            if(-not $Key -or $Key -eq 'Direct'){$code='TargetRequired'}
            elseif(-not $code){$daily=Get-DailyProxyPlan $Key;if(-not $daily.CanApply){$code='TargetUnavailable'}else{$noChange=[bool]$daily.NoChange}}
        }else{$Key='';if(-not $code){$noChange=Test-NetworkRecoveryDirect $context}}
    }catch{$code='ObservationUnavailable'}
    $steps=if($Goal -eq 'Direct'){@('保存本机私有备份及恢复收据。','关闭当前用户手动代理、PAC 与自动检测，清空 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY。','保留 NO_PROXY、系统绕过项、已登记客户端、配置与程序专线。','复读三个 Windows 代理视图及用户变量；机器级代理、隧道和已有进程另行复检。')}else{@('复用正式日常代理计划，先核验所选目标和实际固定请求。','保存私有备份及收据，再同步系统入口与用户代理变量。','保留 NO_PROXY、客户端与程序专线；不会自动启动客户端。')}
    $message=if($code){Get-NetworkRecoveryCodeMessage $code}elseif($noChange -and $Goal -eq 'Direct' -and (Test-NetworkRecoveryPartial $context)){'当前用户应用代理层已为直连；机器代理、隧道或守卫仍需检查，尚不能确认普通上网已恢复。'}elseif($noChange){Get-NetworkRecoveryCodeMessage 'NoChange'}elseif($Goal -eq 'Direct'){'将重置当前用户应用代理层以恢复普通上网入口。原代理客户端已卸载、未登记或停止也可处理。'+$(if(Test-NetworkRecoveryPartial $context){'机器代理、隧道或守卫仍需继续检查，本步骤只能部分恢复。'}else{''})}else{$daily.Message}
    $revision=Get-DailyProxyHash ([pscustomobject]@{Kind='NetworkRecovery';Goal=$Goal;Key=$Key;Context=$context;DailyRevision=$(if($daily){$daily.Revision}else{''})})
    [pscustomobject]@{Kind='NetworkRecovery';Goal=$Goal;Key=$Key;Revision=$revision;CreatedAt=[DateTimeOffset]::UtcNow.ToString('o');CanApply=(-not $code);NoChange=$noChange;Code=$code;Message=$message;Steps=$steps;Context=$context;DailyPlan=$daily}
}
function Assert-NetworkRecoveryFresh($Plan,[string]$Kind='NetworkRecovery') {
    $created=[DateTimeOffset]::MinValue
    if(-not $Plan -or $Plan.Kind -cne $Kind -or -not [DateTimeOffset]::TryParse([string]$Plan.CreatedAt,[ref]$created)){Stop-NetworkRecovery 'PlanExpired'}
    $age=([DateTimeOffset]::UtcNow-$created).TotalSeconds
    if($age -lt -5 -or $age -gt 120){Stop-NetworkRecovery 'PlanExpired'}
}
function Assert-NetworkRecoveryCurrent($Plan) {
    Assert-NetworkRecoveryFresh $Plan $Plan.Kind
    $fresh=if($Plan.Kind -eq 'NetworkRecoveryUndo'){Get-NetworkRecoveryUndoPlan}else{Get-NetworkRecoveryPlan -Goal $Plan.Goal -Key $Plan.Key}
    if(-not $fresh.CanApply){Stop-NetworkRecovery $fresh.Code}
    if($fresh.Revision -cne $Plan.Revision){Stop-NetworkRecovery 'StateChanged'}
    $fresh
}
function Write-NetworkRecoveryEvent([ValidateSet('Applied','Partial','NoChange','Rejected','Failed','Undone')][string]$State,[string]$Code) {
    # Rebuild only known fields, never append arbitrary exception/proxy/config strings.
    $allowed=@('Applied','Partial','NoChange','PlanExpired','StateChanged','ConfirmationRequired','SessionOwnsSettings','CleanStartOwnsSettings','NativeCapabilityMissing','ObservationUnavailable','TargetRequired','TargetUnavailable','BackupFailed','ReceiptFailed','ReceiptIncomplete','ApplyFailed','RollbackIncomplete','UndoUnavailable','UndoTargetUnavailable','UndoAutomaticUnsupported','Undone')
    if($Code -notin $allowed){$Code='ApplyFailed'}
    try{
        Initialize-NetworkRecoveryPrivateDirectory
        $path=Get-NetworkRecoveryEventPath;$image=Read-RuleMaintenanceFile $path;$rows=@()
        if($image.Exists -and $image.Bytes.Length -le 65536){
            $old=Read-RuleMaintenanceJson $image $null
            foreach($row in @($old.Events|Select-Object -Last 63)){
                $at=[DateTimeOffset]::MinValue
                if($row.State -in @('Applied','Partial','NoChange','Rejected','Failed','Undone') -and $row.Code -in $allowed -and [DateTimeOffset]::TryParse([string]$row.At,[ref]$at)){$rows+=[pscustomobject]@{At=$at.ToUniversalTime().ToString('o');State=[string]$row.State;Code=[string]$row.Code}}
            }
        }
        $rows+=[pscustomobject]@{At=[DateTimeOffset]::UtcNow.ToString('o');State=$State;Code=$Code}
        Set-RuleMaintenanceFile $image (ConvertTo-RuleMaintenanceBytes ([pscustomobject]@{Version=1;Events=@($rows)})) $false
    }catch{} # Logging cannot change a completed operation into a failed setting write.
}
function New-NetworkRecoveryResult([string]$State,[string]$Code,$Backup=$null,$Receipt=$null,$Verification=$null) {
    [pscustomobject]@{State=$State;Code=$Code;Message=(Get-NetworkRecoveryCodeMessage $Code);Backup=$Backup;Receipt=$Receipt;Verification=$Verification}
}
function Test-NetworkRecoveryUnchangedFiles($Before,$After,[string[]]$Except=@()) {
    foreach($name in $Before.PSObject.Properties.Name){if($name -notin $Except -and $Before.$name -cne $After.$name){return $false}};$true
}
function Test-NetworkRecoveryCoherentWindowsBaseline($System,$Views) {
    # Rollback restores a captured setting, not a newly selected daily route. A
    # coherent PAC/auto-detect baseline is valid even though DailyProxy forbids it.
    if(-not $Views.Registry.Available -or -not $Views.WinHttpIE.Available -or -not $Views.Summary -or $Views.Summary.Different){return $false}
    $manual=[bool]($System.Flags -band 2);$pac=[bool]($System.Flags -band 4);$auto=[bool]($System.Flags -band 8)
    if([bool]$Views.Registry.Enabled -ne $manual -or [bool]$Views.WinHttpIE.AutoDetect -ne $auto -or [bool]$Views.WinHttpIE.HasPac -ne $pac){return $false}
    if($pac -ne (-not [string]::IsNullOrEmpty([string]$System.AutoConfigUrl))){return $false}
    $serverHash=Get-DailyProxyHash ([string]$System.Server)
    if($Views.Registry.ServerHash -cne $serverHash){return $false}
    $ieServer=if($manual){[string]$System.Server}else{''}
    $Views.WinHttpIE.ServerHash -ceq (Get-DailyProxyHash $ieServer)
}
function Test-NetworkRecoveryOwnedWindowsTarget($System,$Views,$Target,[string]$Key) {
    if(-not (Test-SameSnapshot $System $Target) -or -not (Test-DailyProxyWindowsTarget $System $Views $Key)){return $false}
    # Disabled-but-edited registry server values also belong to an outside writer.
    if($Views.Registry.ServerHash -cne (Get-DailyProxyHash ([string]$Target.Server))){return $false}
    $ieServer=if($Target.Flags -band 2){[string]$Target.Server}else{''}
    $Views.WinHttpIE.ServerHash -ceq (Get-DailyProxyHash $ieServer)
}
function Test-NetworkRecoveryProxyPreparedOwnership($Receipt,$DailyImage) {
    $dailyReceipt=Read-RuleMaintenanceJson $DailyImage $null;$preparedAt=[DateTimeOffset]::MinValue;$dailyAt=[DateTimeOffset]::MinValue
    ($dailyReceipt -and $dailyReceipt.Phase -eq 'Applied' -and $dailyReceipt.AfterEndpoint.Key -ceq $Receipt.TargetKey -and [DateTimeOffset]::TryParse([string]$Receipt.CreatedAt,[ref]$preparedAt) -and [DateTimeOffset]::TryParse([string]$dailyReceipt.CreatedAt,[ref]$dailyAt) -and ($dailyAt-$preparedAt).TotalSeconds -ge 0 -and ($dailyAt-$preparedAt).TotalSeconds -le 120 -and (Get-DailyProxyHash $dailyReceipt.BeforeSystem) -ceq (Get-DailyProxyHash $Receipt.BeforeSystem) -and (Test-SameEnv $dailyReceipt.BeforeEnvironment $Receipt.BeforeEnvironment))
}
function Invoke-NetworkRecoveryDirectCommit($Plan,$TargetSystem,$TargetEnvironment,$Receipt,$ReceiptImage) {
    $before=$Plan.Context;$written=[pscustomobject]@{Image=$ReceiptImage;Prepared=$false};$backup=$null
    $verify={
        $now=Get-NetworkRecoveryContext
        if((Get-DailyProxyHash $now.System) -cne (Get-DailyProxyHash $before.System) -or -not (Test-SameEnv $now.Environment $before.Environment) -or (Get-DailyProxyHash $now.WindowsViews) -cne (Get-DailyProxyHash $before.WindowsViews) -or -not (Test-NetworkRecoveryUnchangedFiles $before.Files $now.Files @('network-recovery-receipt.json')) -or (Get-DailyProxyHash $now.Client) -cne (Get-DailyProxyHash $before.Client) -or (Get-DailyProxyHash $now.Machine) -cne (Get-DailyProxyHash $before.Machine) -or $now.CleanStart -cne $before.CleanStart){Stop-NetworkRecovery 'StateChanged'}
        if((Read-RuleMaintenanceFile $written.Image.Path).Hash -cne $written.Image.Hash){Stop-NetworkRecovery 'StateChanged'}
    }
    $prepare={
        & $verify
        try{
            Set-RuleMaintenanceFile $ReceiptImage (ConvertTo-RuleMaintenanceBytes $Receipt) $false
            $written.Image=Read-RuleMaintenanceFile $ReceiptImage.Path;$written.Prepared=$true
        }catch{Stop-NetworkRecovery 'ReceiptFailed'}
        & $verify
    }
    $post={
        $after=Get-NetworkRecoveryContext
        if((Get-DailyProxyHash $after.System) -cne (Get-DailyProxyHash $TargetSystem) -or -not (Test-SameEnv $after.Environment $TargetEnvironment) -or -not (Test-NetworkRecoveryUnchangedFiles $before.Files $after.Files @('network-recovery-receipt.json')) -or $after.CleanStart -cne $before.CleanStart){Stop-NetworkRecovery 'StateChanged'}
        if($Plan.Kind -ne 'NetworkRecoveryUndo' -and -not (Test-NetworkRecoveryDirect $after)){Stop-NetworkRecovery 'StateChanged'}
        if($Plan.Kind -eq 'NetworkRecoveryUndo' -and -not (Test-DailyProxyWindowsTarget $after.System $after.WindowsViews $Plan.Key)){Stop-NetworkRecovery 'StateChanged'}
        $Receipt.Phase=if($Plan.Kind -eq 'NetworkRecoveryUndo'){'Undone'}else{'Applied'}
        $Receipt|Add-Member NoteProperty AfterWindowsViews $after.WindowsViews -Force
        Set-RuleMaintenanceFile $written.Image (ConvertTo-RuleMaintenanceBytes $Receipt) $false
        $written.Image=Read-RuleMaintenanceFile $ReceiptImage.Path
    }
    $final={
        $after=Get-NetworkRecoveryContext
        if((Get-DailyProxyHash $after.System) -cne (Get-DailyProxyHash $TargetSystem) -or -not (Test-SameEnv $after.Environment $TargetEnvironment) -or (Read-RuleMaintenanceFile $written.Image.Path).Hash -cne $written.Image.Hash -or -not (Test-NetworkRecoveryUnchangedFiles $before.Files $after.Files @('network-recovery-receipt.json'))){Stop-NetworkRecovery 'StateChanged'}
        if($Plan.Kind -ne 'NetworkRecoveryUndo' -and -not (Test-NetworkRecoveryDirect $after)){Stop-NetworkRecovery 'StateChanged'}
        if($Plan.Kind -eq 'NetworkRecoveryUndo' -and -not (Test-DailyProxyWindowsTarget $after.System $after.WindowsViews $Plan.Key)){Stop-NetworkRecovery 'StateChanged'}
    }
    $rollbackOwner={
        # All Windows views form one write group. A divergent outside view is not ours.
        $sys=Get-SystemSnapshot;$views=Get-DailyProxyWindowsViews $sys
        if(-not (Test-NetworkRecoveryCoherentWindowsBaseline $before.System $before.WindowsViews)){return $false}
        $targetKey=if($Plan.Kind -eq 'NetworkRecoveryUndo'){$Plan.Key}else{'Direct'}
        Test-NetworkRecoveryOwnedWindowsTarget $sys $views $TargetSystem $targetKey
    }
    try{$backup=Save-Backup ([pscustomobject]@{Version=4;System=$before.System;Environment=$before.Environment;Recovery=$Receipt})}catch{Stop-NetworkRecovery 'BackupFailed'}
    $Receipt|Add-Member NoteProperty Backup $backup -Force
    try{
        Invoke-ProxyTransaction $TargetSystem $TargetEnvironment $null $before.System $before.Environment -PreserveSelection -VerifyAction $verify -PreWindowsAction $prepare -PostCommitAction $post -FinalVerifyAction $final -SystemRollbackOwnership $rollbackOwner|Out-Null
    }catch{
        $errorRecord=$_
        $rolled=Get-NetworkRecoveryContext
        if((Get-DailyProxyHash $rolled.System) -cne (Get-DailyProxyHash $before.System) -or -not (Test-SameEnv $rolled.Environment $before.Environment)){
            # Keep the durable ownership record for an interrupted or incomplete rollback.
            Stop-NetworkRecovery 'RollbackIncomplete'
        }
        if($written.Prepared){
            try{$actual=Read-RuleMaintenanceFile $written.Image.Path;if($actual.Hash -ceq $written.Image.Hash){Set-RuleMaintenanceFile $actual $ReceiptImage.Bytes (-not $ReceiptImage.Exists)}}catch{Stop-NetworkRecovery 'RollbackIncomplete'}
        }
        $code=Get-NetworkRecoveryFailureCode $errorRecord
        if(-not $written.Prepared -and $code -eq 'ApplyFailed'){$code='BackupFailed'}
        Stop-NetworkRecovery $code
    }
    $backup
}
function Invoke-NetworkRecoveryPlan($Plan,[switch]$Confirmed) {
    $backup=$null;$receiptPath=$null
    try{
        if(-not $Confirmed){Stop-NetworkRecovery 'ConfirmationRequired'}
        Assert-NetworkRecoveryFresh $Plan
        $result=Use-ChangeLock {
            $fresh=Assert-NetworkRecoveryCurrent $Plan
            if($fresh.NoChange){$state=if($fresh.Goal -eq 'Direct' -and (Test-NetworkRecoveryPartial $fresh.Context)){'Partial'}else{'NoChange'};return New-NetworkRecoveryResult $state $state $null $null ([pscustomobject]@{Settings='Verified';Request='NotTested'})}
            try{Initialize-NetworkRecoveryPrivateDirectory}catch{Stop-NetworkRecovery 'ReceiptFailed'}
            $context=$fresh.Context;$image=Read-RuleMaintenanceFile (Get-NetworkRecoveryReceiptPath)
            $receipt=[pscustomobject]@{Version=1;Id=[Guid]::NewGuid().ToString('N');Phase='Prepared';Goal=$fresh.Goal;TargetKey=$fresh.Key;CreatedAt=[DateTimeOffset]::UtcNow.ToString('o');BeforeSystem=$context.System;BeforeEnvironment=$context.Environment;BeforeWindowsViews=$context.WindowsViews;Files=$context.Files;BeforeEndpoint=$null;BeforeEnvironmentOwnership=$null;AfterSystem=$null;AfterEnvironment=$null}
            if($fresh.Goal -eq 'Proxy'){
                # Prepared recovery ownership must be durable before DailyProxy starts its own transaction.
                try{$backup=Save-Backup ([pscustomobject]@{Version=4;System=$context.System;Environment=$context.Environment;Recovery=$receipt})}catch{Stop-NetworkRecovery 'BackupFailed'}
                $receipt|Add-Member NoteProperty Backup $backup
                try{Set-RuleMaintenanceFile $image (ConvertTo-RuleMaintenanceBytes $receipt) $false}catch{Stop-NetworkRecovery 'ReceiptFailed'}
                $prepared=Read-RuleMaintenanceFile $image.Path
                try{
                    $dailyResult=Set-DailyProxy $fresh.DailyPlan -Confirmed
                    $dailyImage=Read-RuleMaintenanceFile (Get-DailyProxyReceiptPath);$dailyReceipt=Read-RuleMaintenanceJson $dailyImage $null
                    $receipt.Phase='Applied';$receipt|Add-Member NoteProperty DailyReceiptHash $dailyImage.Hash
                    $receipt|Add-Member NoteProperty DailyReceiptId $dailyReceipt.Id
                    Set-RuleMaintenanceFile $prepared (ConvertTo-RuleMaintenanceBytes $receipt) $false
                }catch{
                    # A durable Prepared record is retained if a committed daily result cannot be finalized.
                    if(Test-NetworkRecoveryProxyPreparedOwnership $receipt (Read-RuleMaintenanceFile (Get-DailyProxyReceiptPath))){return New-NetworkRecoveryResult 'Partial' 'ReceiptIncomplete' $backup $image.Path ([pscustomobject]@{Settings='Unknown';Request='NotTested';Receipt='Prepared'})}
                    try{$actual=Read-RuleMaintenanceFile $image.Path;if($actual.Hash -ceq $prepared.Hash){Set-RuleMaintenanceFile $actual $image.Bytes (-not $image.Exists)}}catch{}
                    Stop-NetworkRecovery 'ApplyFailed'
                }
                return New-NetworkRecoveryResult 'Applied' 'Applied' $dailyResult.Backup $image.Path ([pscustomobject]@{Settings='Verified';Request='PreflightSucceeded';AuthenticationVerified=$false})
            }
            $target=[pscustomobject]@{Flags=(($context.System.Flags -band -15) -bor 1);Server='';Bypass=$context.System.Bypass;AutoConfigUrl=''}
            $envTarget=Copy-NetworkRecoveryValue $context.Environment
            foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){$envTarget.$name=$null}
            $receipt.AfterSystem=$target;$receipt.AfterEnvironment=$envTarget
            # Undo is conservative: only a still registered and identity-verified HTTP endpoint may return.
            try{$key=Get-SystemKey $context.System;$receipt.BeforeEndpoint=Get-DailyProxyEndpoint $key;$receipt.BeforeEnvironmentOwnership=Get-DailyProxyEnvironmentOwnership $context.Environment}catch{}
            $backup=Invoke-NetworkRecoveryDirectCommit $fresh $target $envTarget $receipt $image
            $after=Get-NetworkRecoveryContext;$partial=Test-NetworkRecoveryPartial $after
            $state=if($partial){'Partial'}else{'Applied'}
            New-NetworkRecoveryResult $state $state $backup $image.Path ([pscustomobject]@{Settings='Verified';Request='NotTested';ApplicationProxy='Direct';Machine=$after.Machine.State;Tunnel=$after.Client.Topology;AuthenticationVerified=$false})
        }
        Write-NetworkRecoveryEvent $result.State $result.Code;$result
    }catch{$code=Get-NetworkRecoveryFailureCode $_;$state=if($code -in @('ApplyFailed','RollbackIncomplete')){'Failed'}else{'Rejected'};if(Test-Path -LiteralPath (Get-NetworkRecoveryReceiptPath)){$receiptPath=Get-NetworkRecoveryReceiptPath;try{$failedReceipt=Read-RuleMaintenanceJson (Read-RuleMaintenanceFile $receiptPath) $null;$backup=Get-NetworkRecoveryValue $failedReceipt 'Backup'}catch{}};Write-NetworkRecoveryEvent $state $code;New-NetworkRecoveryResult $state $code $backup $receiptPath}
}
function Assert-NetworkRecoveryUndoTargets($System,$Environment) {
    $keys=@();$systemKey=Get-SystemKey $System
    if($systemKey -ne 'Direct'){$keys+=$systemKey}
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){if($Environment.$name){$keys+=Get-EndpointKey $Environment.$name}}
    foreach($key in @($keys|Select-Object -Unique)){
        if($key -notin (Get-ProfileKeys) -or -not (Test-ProxyRoute $key -Fast).Usable){Stop-NetworkRecovery 'UndoTargetUnavailable'}
    }
}
function Get-NetworkRecoveryUndoPlan {
    $context=$null;$receipt=$null;$daily=$null;$code='';$key='';$revision=''
    try{
        $context=Get-NetworkRecoveryContext;$code=Get-NetworkRecoveryContextCode $context
        $image=Read-RuleMaintenanceFile (Get-NetworkRecoveryReceiptPath);$receipt=Read-RuleMaintenanceJson $image $null
        if(-not $code){
            if(-not $receipt -or $receipt.Version -ne 1 -or ($receipt.Phase -ne 'Applied' -and -not ($receipt.Goal -eq 'Proxy' -and $receipt.Phase -eq 'Prepared'))){$code='UndoUnavailable'}
            elseif($receipt.Goal -eq 'Proxy'){
                $daily=Get-DailyProxyUndoPlan
                $dailyImage=Read-RuleMaintenanceFile (Get-DailyProxyReceiptPath)
                $owned=($dailyImage.Hash -ceq (Get-NetworkRecoveryValue $receipt 'DailyReceiptHash' ''))
                if($receipt.Phase -eq 'Prepared'){
                    $owned=Test-NetworkRecoveryProxyPreparedOwnership $receipt $dailyImage
                }
                if(-not $daily.CanApply -or -not $owned){$code='UndoTargetUnavailable'}else{$key=$daily.Key}
            }elseif($receipt.Goal -ne 'Direct'){$code='UndoUnavailable'}
            elseif((Get-DailyProxyHash $context.System) -cne (Get-DailyProxyHash $receipt.AfterSystem) -or -not (Test-SameEnv $context.Environment $receipt.AfterEnvironment) -or (Get-DailyProxyHash $context.WindowsViews) -cne (Get-DailyProxyHash $receipt.AfterWindowsViews) -or -not (Test-NetworkRecoveryUnchangedFiles $receipt.Files $context.Files @('network-recovery-receipt.json'))){$code='StateChanged'}
            elseif(($receipt.BeforeSystem.Flags -band 12) -or $receipt.BeforeSystem.AutoConfigUrl -or -not (Test-DailyProxyWindowsTarget $receipt.BeforeSystem $receipt.BeforeWindowsViews (Get-SystemKey $receipt.BeforeSystem))){$code='UndoAutomaticUnsupported'}
            else{
                $key=Get-SystemKey $receipt.BeforeSystem
                $endpoint=Get-DailyProxyEndpoint $key;$owners=Get-DailyProxyEnvironmentOwnership $receipt.BeforeEnvironment
                if($endpoint.State -ne 'Ready' -or (Get-DailyProxyHash $endpoint) -cne (Get-DailyProxyHash $receipt.BeforeEndpoint) -or -not $owners.Ready -or -not $receipt.BeforeEnvironmentOwnership.Ready -or (Get-DailyProxyHash $owners) -cne (Get-DailyProxyHash $receipt.BeforeEnvironmentOwnership)){$code='UndoTargetUnavailable'}
            }
        }
        $revision=Get-DailyProxyHash ([pscustomobject]@{Context=$context;Receipt=$receipt;DailyRevision=$(if($daily){$daily.Revision}else{''});Endpoint=$(if($key){Get-DailyProxyEndpoint $key}else{$null});Owners=$(if($receipt){Get-DailyProxyEnvironmentOwnership $receipt.BeforeEnvironment}else{$null})})
    }catch{$code='UndoUnavailable'}
    [pscustomobject]@{Kind='NetworkRecoveryUndo';Goal='Undo';Key=$key;Revision=$revision;CreatedAt=[DateTimeOffset]::UtcNow.ToString('o');CanApply=(-not $code);NoChange=$false;Code=$code;Message=$(if($code){Get-NetworkRecoveryCodeMessage $code}else{'仅撤回最近一次仍归属于本次的用户代理恢复；原入口须重新通过有效性预检。'});Steps=@('核对收据与当前设置，拒绝覆盖后来修改。','先检测原入口，已卸载或停止的入口不会被重启或恢复。');Context=$context;Receipt=$receipt;DailyPlan=$daily}
}
function Restore-NetworkRecovery($Plan,[switch]$Confirmed) {
    try{
        if(-not $Confirmed){Stop-NetworkRecovery 'ConfirmationRequired'}
        Assert-NetworkRecoveryFresh $Plan 'NetworkRecoveryUndo'
        $result=Use-ChangeLock {
            $fresh=Assert-NetworkRecoveryCurrent $Plan
            if($fresh.Receipt.Goal -eq 'Proxy'){
                Assert-NetworkRecoveryUndoTargets $fresh.DailyPlan.Receipt.BeforeSystem $fresh.DailyPlan.Receipt.BeforeEnvironment
                $fresh=Assert-NetworkRecoveryCurrent $Plan
                $image=Read-RuleMaintenanceFile (Get-NetworkRecoveryReceiptPath);$next=Copy-NetworkRecoveryValue $fresh.Receipt;$next.Phase='UndoPrepared'
                try{Set-RuleMaintenanceFile $image (ConvertTo-RuleMaintenanceBytes $next) $false}catch{Stop-NetworkRecovery 'ReceiptFailed'}
                $pending=Read-RuleMaintenanceFile $image.Path
                try{$r=Restore-DailyProxy $fresh.DailyPlan -Confirmed}catch{
                    try{$actual=Read-RuleMaintenanceFile $image.Path;if($actual.Hash -ceq $pending.Hash){Set-RuleMaintenanceFile $actual $image.Bytes $false}}catch{Stop-NetworkRecovery 'RollbackIncomplete'}
                    Stop-NetworkRecovery 'ApplyFailed'
                }
                $next.Phase='Undone'
                try{Set-RuleMaintenanceFile $pending (ConvertTo-RuleMaintenanceBytes $next) $false}catch{return New-NetworkRecoveryResult 'Partial' 'ReceiptIncomplete' $r.Backup $image.Path ([pscustomobject]@{Settings='Verified';Request='PreflightSucceeded';Receipt='UndoPrepared'})}
                return New-NetworkRecoveryResult 'Applied' 'Applied' $r.Backup $image.Path ([pscustomobject]@{Settings='Verified';Request='PreflightSucceeded'})
            }
            Assert-NetworkRecoveryUndoTargets $fresh.Receipt.BeforeSystem $fresh.Receipt.BeforeEnvironment
            $fresh=Assert-NetworkRecoveryCurrent $Plan
            $receipt=Copy-NetworkRecoveryValue $fresh.Receipt;$receipt.Phase='UndoPrepared'
            $image=Read-RuleMaintenanceFile (Get-NetworkRecoveryReceiptPath)
            $backup=Invoke-NetworkRecoveryDirectCommit $fresh $receipt.BeforeSystem $receipt.BeforeEnvironment $receipt $image
            New-NetworkRecoveryResult 'Applied' 'Applied' $backup $image.Path ([pscustomobject]@{Settings='Verified';Request=$(if($fresh.Key -ne 'Direct'){'PreflightSucceeded'}else{'NotTested'})})
        }
        Write-NetworkRecoveryEvent 'Undone' 'Undone';$result
    }catch{$code=Get-NetworkRecoveryFailureCode $_;Write-NetworkRecoveryEvent 'Rejected' $code;New-NetworkRecoveryResult 'Rejected' $code}
}
function Undo-NetworkRecovery($Plan,[switch]$Confirmed) {Restore-NetworkRecovery -Plan $Plan -Confirmed:$Confirmed}

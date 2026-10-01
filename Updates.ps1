# UI update coordination. All network transfer occurs in a separate bounded Node worker.
$script:UpdateProcess=$null;$script:UpdateReady=$null;$script:UpdateHandoff=$null;$script:UpdateRequested=$false
$script:UpdateUiReady=$false;$script:UpdateNextTick=[DateTime]::UtcNow.AddSeconds(30)
function Get-FlowUpdateRoot { [IO.Path]::GetFullPath((Join-Path $script:UiRoot '..')) }
function Read-FlowUpdateSettings {
    $file=Join-Path $script:DataRoot 'updates\background.json'
    if(Test-Path -LiteralPath $file){return (Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json)}
    [pscustomobject]@{enabled=$true;nextCheck=0;failures=0}
}
function Set-FlowUpdateAutomatic([bool]$Enabled){
    $value=Read-FlowUpdateSettings;$value|Add-Member NoteProperty enabled $Enabled -Force
    Write-LocalJson (Join-Path $script:DataRoot 'updates\background.json') $value
}
function Start-FlowUpdateCheck([switch]$Manual,[switch]$AllowLarge){
    if($script:UpdateProcess -or $script:UpdateRequested){return}
    $root=Get-FlowUpdateRoot
    if(-not (Test-Path -LiteralPath (Join-Path $root 'update-install.json'))){if($Manual){Write-Activity '当前是源码或旧版未登记安装，请先完整解压支持更新的新程序包。'};return}
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $root 'app\runtime\node.exe';$info.WorkingDirectory=$script:UiRoot
    $info.Arguments=(Quote-DesktopArgument (Join-Path $script:UiRoot 'UpdateEngine.cjs'))+' --root '+(Quote-DesktopArgument $root)+' --data '+(Quote-DesktopArgument $script:DataRoot)+' --manual '+$Manual.IsPresent.ToString().ToLowerInvariant()+' --allow-large '+$AllowLarge.IsPresent.ToString().ToLowerInvariant()
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle='Hidden';$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.EnvironmentVariables.Remove('NODE_OPTIONS');$info.EnvironmentVariables.Remove('NODE_PATH');$info.EnvironmentVariables.Remove('FLOWSWITCH_UPDATE_PROXY')
    try{$system=Get-SystemSnapshot;if(($system.Flags -band 2) -and $system.Server -match '^(localhost|127\.0\.0\.1):\d+$'){$info.EnvironmentVariables['FLOWSWITCH_UPDATE_PROXY']='http://'+$system.Server}}catch{}
    $cancel=Join-Path $script:DataRoot 'updates\cancel';if(Test-Path -LiteralPath $cancel){[IO.File]::Delete($cancel)}
    $p=[Diagnostics.Process]::Start($info)
    $script:UpdateProcess=[pscustomobject]@{Process=$p;Out=$p.StandardOutput.ReadToEndAsync();Error=$p.StandardError.ReadToEndAsync();Manual=$Manual.IsPresent}
    $updateButton.Text='取消检查/暂存'
    if($Manual){Write-Activity '正在检查流向官方稳定版；小于等于 50 MiB 的文件差异可暂存，安装须另行确认。'}
}
function Assert-FlowUpdateIdle {
    if($script:DialogOpen -or $script:MenuOpen -or $script:PendingAction -or $script:ChoiceDirty -or $script:UpdateProcess -or ($script:Worker -and $script:Worker.Kind -ne 'Status')){throw '仍有未应用选择、对话框或操作进行中，请完成后再安装。'}
    $clean=Get-CleanStartSession
    if($clean -and $clean.Status.phase -notin @('restored','completed','cancelled')){throw '直连对照或恢复尚未结束，请先完成恢复再更新。'}
}
function Get-FlowUpdateIdentity([int]$ProcessId){
    $row=@(Get-ProcessInventory -Id $ProcessId)|Select-Object -First 1
    if(-not $row -or -not $row.Path -or -not $row.StartTime){throw '更新无法核实自有进程身份，未停止服务。'}
    [pscustomobject]@{id=$row.Id;ticks=$row.StartTime.ToUniversalTime().Ticks.ToString();path=$row.Path;parent=$row.ParentId}
}
function Prepare-FlowUpdateHandoff {
    Assert-FlowUpdateIdle
    if(-not $script:UpdateReady -or $script:UpdateReady.phase -ne 'staged'){throw '没有已校验的暂存更新。'}
    $candidate=Get-Content -LiteralPath $script:UpdateReady.candidate -Raw -Encoding UTF8|ConvertFrom-Json
    $root=Get-FlowUpdateRoot;$stage=[IO.Path]::GetFullPath([string]$candidate.stage)
    if($candidate.root -ine $root -or $candidate.data -ine $script:DataRoot -or -not $stage.StartsWith((Join-Path $script:DataRoot 'updates\stage-'),[StringComparison]::OrdinalIgnoreCase)){throw '更新目标与当前安装不符。'}
    $self=Get-FlowUpdateIdentity $PID;$parent=Get-FlowUpdateIdentity $self.parent
    if($parent.path -ine (Join-Path $root 'FlowSwitch.exe')){throw '请从已登记的 FlowSwitch.exe 打开后安装更新。'}
    $processes=@($self,$parent);$ports=@()
    if(Test-Path -LiteralPath (Get-IndependentSessionPath)){
        $session=Get-Content -LiteralPath (Get-IndependentSessionPath) -Raw -Encoding UTF8|ConvertFrom-Json
        if($session.OwnerPID -ne $PID -or (Get-RecoveryOwnerState $session) -ne 'alive'){throw '代理服务不归当前窗口或归属未知，未停止其他实例。'}
        $tracked=Get-Content -LiteralPath (Join-Path $script:DataRoot 'gateway\process.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if($tracked.supervisor -ne $session.SupervisorPID -or -not $tracked.coreStartTicks){throw '当前内核归属尚未核实，未停止服务。'}
        $supervisor=Get-FlowUpdateIdentity $session.SupervisorPID;$core=Get-FlowUpdateIdentity $tracked.core
        if($supervisor.ticks -cne [string]$session.SupervisorStart -or $core.ticks -cne [string]$tracked.coreStartTicks -or $core.parent -ne $supervisor.id){throw '内核恢复期间身份变化，请稍后重试。'}
        $processes+=@($supervisor,$core)
        $ports+=@((Get-Profile (Get-GatewayKey)).Port)
        $rules=Get-Content -LiteralPath (Join-Path $script:DataRoot 'app-rules.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $ports+=@($rules.programIngresses|ForEach-Object port)
    }
    $handoff=[pscustomobject]@{candidate=$script:UpdateReady.candidate;nonce=[Guid]::NewGuid().ToString('N');processes=$processes;ports=@($ports|Where-Object {$_ -gt 0}|Select-Object -Unique)}
    $ticket=Join-Path $stage 'handoff.json';Write-LocalJson $ticket $handoff
    $helper=Join-Path $stage 'UpdateInstall.ps1';Copy-Item -LiteralPath (Join-Path $script:UiRoot 'UpdateInstall.ps1') -Destination $helper
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File '+(Quote-DesktopArgument $helper)+' -Ticket '+(Quote-DesktopArgument $ticket)
    # ShellExecute starts the helper without inheriting the launcher's pipe handles.
    # Otherwise launcher EOF and installer wait-for-launcher can deadlock each other.
    $helperInfo=New-Object Diagnostics.ProcessStartInfo
    $helperInfo.FileName=$shell;$helperInfo.Arguments=$args;$helperInfo.WorkingDirectory=$stage
    $helperInfo.UseShellExecute=$true;$helperInfo.WindowStyle='Hidden'
    $p=[Diagnostics.Process]::Start($helperInfo)
    try{
        $ready=Join-Path $stage ('ready-'+$handoff.nonce);$limit=[DateTime]::UtcNow.AddSeconds(10)
        while(-not (Test-Path -LiteralPath $ready)){if($p.HasExited -or [DateTime]::UtcNow -ge $limit){throw '安装器未通过预检，未停止代理。'};Start-Sleep -Milliseconds 80}
        if([IO.File]::ReadAllText($ready) -cne $handoff.nonce){throw '安装器交接无效。'}
    }finally{$p.Dispose()}
    $script:UpdateHandoff=[pscustomobject]@{Stage=$stage;Value=$handoff}
}
function Complete-FlowUpdateHandoff {
    if(-not $script:UpdateHandoff){throw '缺少更新交接。'}
    if(Test-Path -LiteralPath (Get-IndependentSessionPath)){throw '代理恢复或停止尚未完成，暂不退出。'}
    $ports=@($script:UpdateHandoff.Value.ports)
    if($ports.Count){$listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop);foreach($port in $ports){if(@($listeners|Where-Object LocalPort -eq $port).Count){throw '固定入口尚未释放或已被其他程序占用，取消更新退出。'}}}
    $state=Get-Content -LiteralPath (Join-Path $script:UpdateHandoff.Stage 'install-state.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($state.phase -ne 'waiting' -or $state.nonce -cne $script:UpdateHandoff.Value.nonce){throw '安装器已取消交接，窗口保留。'}
    Write-LocalJson (Join-Path $script:DataRoot 'updates\pending-install.json') ([pscustomobject]@{stage=$script:UpdateHandoff.Stage;nonce=$script:UpdateHandoff.Value.nonce})
    [IO.File]::WriteAllText((Join-Path $script:UpdateHandoff.Stage ('commit-'+$script:UpdateHandoff.Value.nonce)),$script:UpdateHandoff.Value.nonce)
}
function Show-FlowUpdateAction {
    if($script:UpdateProcess){[IO.File]::WriteAllText((Join-Path $script:DataRoot 'updates\cancel'),'cancel');Write-Activity '正在取消更新检查/暂存，当前安装与代理不变。';return}
    try{
        Assert-FlowUpdateIdle
        if($script:UpdateReady -and $script:UpdateReady.phase -eq 'staged'){
            $message='已暂存 '+$script:UpdateReady.version+'。安装会先正常恢复代理设置并停止流向服务，进行中的连接可能中断。请先保存其他应用任务。恢复失败将保留窗口，不强杀内核。重启后不会自动接管网络，可按需统一切换恢复入口。现在安装？'
            if([Windows.Forms.MessageBox]::Show($form,$message,'安装流向更新','OKCancel','Warning') -eq 'OK'){$script:UpdateRequested=$true;Request-FlowExit}
        }elseif($script:UpdateReady -and $script:UpdateReady.phase -eq 'consent-required'){
            $message='官方稳定版 '+$script:UpdateReady.version+' 需下载 '+$script:UpdateReady.downloadBytes+' 字节（超过 50 MiB）。是否下载并校验？下载不会退出或安装。'
            if([Windows.Forms.MessageBox]::Show($form,$message,'确认更新下载','OKCancel','Question') -eq 'OK'){Start-FlowUpdateCheck -Manual -AllowLarge}
        }else{Start-FlowUpdateCheck -Manual}
    }catch{$script:UpdateRequested=$false;Write-Activity $_.Exception.Message}
}
function Confirm-FlowUpdateRestart {
    $pending=Join-Path $script:DataRoot 'updates\pending-install.json'
    if(-not (Test-Path -LiteralPath $pending)){return}
    try{
        $p=Get-Content -LiteralPath $pending -Raw -Encoding UTF8|ConvertFrom-Json
        if(-not ([IO.Path]::GetFullPath($p.stage)).StartsWith((Join-Path $script:DataRoot 'updates\stage-'),[StringComparison]::OrdinalIgnoreCase)){return}
        $reg=Get-Content -LiteralPath (Join-Path (Get-FlowUpdateRoot) 'update-install.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $candidate=Get-Content -LiteralPath (Join-Path $p.stage 'candidate.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $state=Get-Content -LiteralPath (Join-Path $p.stage 'install-state.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if($state.phase -eq 'restarting' -and $reg.build -ceq $candidate.target.build -and $reg.version -ceq $script:ProductVersion -and $state.nonce -ceq $p.nonce){
            $identity=Get-FlowUpdateIdentity $PID
            Write-LocalJson (Join-Path $p.stage 'restart-ack.json') ([pscustomobject]@{version=$reg.version;build=$reg.build;nonce=$p.nonce;launcherPID=$identity.parent})
            Write-Activity ('更新文件已安装，'+$reg.version+' 窗口已就绪；代理服务按需手动启动。')
        }elseif($state.phase -in @('rolled-back','rollback-blocked','cancelled','installed-restart-unconfirmed')){Write-Activity ('上次更新状态：'+$state.phase+'。备份和事务记录保留，请勿删除 updates 目录。')}
    }catch{Write-Activity '上次更新结果读取失败；未将其标记为升级成功。'}
}
function Update-FlowUpdateTick {
    if($PreviewPath -or $SmokeTest -or $Demo){return}
    if($script:LastState -and -not $script:UpdateUiReady){
        $script:UpdateUiReady=$true;Confirm-FlowUpdateRestart
        try{$ready=Get-Content -LiteralPath (Join-Path $script:DataRoot 'updates\ready.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json;if($ready.phase -eq 'staged' -and [version]$ready.version -gt [version]$script:ProductVersion){$script:UpdateReady=$ready;$updateButton.Text='安装更新…'}}catch{}
    }
    if($script:UpdateProcess -and $script:UpdateProcess.Process.HasExited){
        $job=$script:UpdateProcess;$script:UpdateProcess=$null
        try{
            $reply=$job.Out.Result|ConvertFrom-Json
            if($reply.phase -in @('staged','consent-required')){$script:UpdateReady=$reply;$updateButton.Text=$(if($reply.phase -eq 'staged'){'安装更新…'}else{'下载更新…'});Write-Activity ('发现流向 '+$reply.version+'，需要传输 '+$reply.downloadBytes+' 字节。'+$(if($reply.phase -eq 'staged'){'已校验暂存；点击安装更新后才会退出。'}else{'超过后台下载上限，请明确确认。'}))}
            elseif($reply.phase -eq 'current'){if($job.Manual){Write-Activity '当前已是官方稳定版。'}}
            elseif($reply.phase -eq 'failed'){Write-Activity ('更新检查未完成：'+$reply.reason+'。保持当前安装，可稍后手动重试。')}
        }catch{Write-Activity '更新检查未完成，保持当前安装。'}finally{$job.Process.Dispose();$updateButton.Text=$(if($script:UpdateReady.phase -eq 'staged'){'安装更新…'}elseif($script:UpdateReady.phase -eq 'consent-required'){'下载更新…'}else{'检查更新'})}
    }
    if($script:UpdateUiReady -and -not $script:UpdateProcess -and [DateTime]::UtcNow -ge $script:UpdateNextTick){
        $script:UpdateNextTick=[DateTime]::UtcNow.AddMinutes(5)
        try{$settings=Read-FlowUpdateSettings;if($settings.enabled -ne $false -and [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -ge [double]$settings.nextCheck){Start-FlowUpdateCheck}}catch{}
    }
}

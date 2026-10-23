function Get-NetworkRecoveryUiState([string]$State) {
    switch($State){
        'Applied' {'设置已更改'} 'Partial' {'部分完成，仍需检查'} 'Rejected' {'条件不满足，未执行'} 'Failed' {'未完成，请重新检查'} 'Cancelled' {'已取消'}
        'NoChange' {'无需更改'} 'Verified' {'设置已复读确认'} 'ReadOnly' {'只读检查'} 'NotTested' {'尚未检测'}
        'Listening' {'入口正在监听'} 'Stopped' {'入口未监听'} 'Unset' {'未设置'} 'Enabled' {'已开启'} 'Disabled' {'已关闭'} 'Unsupported' {'无法识别'} 'Unknown' {'未知'}
        'RequestSucceeded' {'固定请求有成功响应'} 'PreflightSucceeded' {'目标通路预检通过'} 'RequestFailed' {'本轮请求失败'} 'TargetRequired' {'当前通路不明确，请先核对代理设置'} 'TargetUnavailable' {'目标入口不可用'} 'StateChanged' {'检测期间设置发生变化，请重查'}
        'https-response' {'收到 HTTPS 响应'} 'probe-timeout' {'请求超时'} 'proxy-rejected' {'代理拒绝请求'} 'target-tls-failed' {'目标 TLS 失败'} 'target-tls-or-timeout' {'目标连接超时或 TLS 失败'} 'proxy-or-target-unreachable' {'代理或目标无法到达'} 'probe-unavailable' {'检测不可用'}
        default {if($State){$State}else{'未知'}}
    }
}
function New-NetworkRecoveryDialog($Report) {
    $dialog=New-Object Windows.Forms.Form;$dialog.Name='FlowNetworkRecovery';$dialog.Text='网络诊断与恢复';$dialog.Font=$form.Font;$dialog.BackColor=$paper;$dialog.ForeColor=$ink
    $dialog.ClientSize=New-Object Drawing.Size(880,660);$dialog.MinimumSize=New-Object Drawing.Size(700,550);$dialog.StartPosition='CenterParent'
    $grid=New-Grid $dialog 4 @(0,-1,0,0);$grid.Padding=New-Object Windows.Forms.Padding(20)
    $headline=New-Label $grid '先查原因，再恢复；每一步都能看结果' 0 0 800 44 15 $true;$headline.Dock='Fill';$headline.AutoSize=$true;$grid.SetCellPosition($headline,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
    $details=New-Object Windows.Forms.TextBox;$details.Name='RecoveryDetails';$details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical';$details.Dock='Fill';$details.BackColor=$paper;$details.ForeColor=$ink;$details.BorderStyle='None';$details.Margin=New-Object Windows.Forms.Padding(0,12,0,12);$grid.Controls.Add($details,0,1)
    $lines=@('① 检查结果',[string]$Report.Summary)
    foreach($check in @($Report.Checks)){$lines+=([string]$check.Name+'：'+(Get-NetworkRecoveryUiState $check.State));if($check.Detail){$lines+=('  '+[string]$check.Detail)}}
    foreach($finding in @($Report.Findings)){$lines+=('• '+[string]$finding.Message)}
    if($Report.Verification){
        $lines+=@('',('通路检测：'+(Get-NetworkRecoveryUiState $Report.Verification.Request)))
        $index=0;foreach($probe in @($Report.Verification.Targets)){$index++;$lines+=('  检测 '+$index+'：'+(Get-NetworkRecoveryUiState $probe.Stage)+$(if($probe.HttpCode){' · HTTP '+$probe.HttpCode}else{''}))}
    }
    $lines+=@('','② 选择恢复目标','恢复普通上网：备份后关闭当前用户手动代理和自动代理，清除三项用户代理变量。原代理已卸载也可处理。','恢复到所选代理：先检测目标，再预览应用；不自动启动或停止其他客户端。','','③ 复检与后续')
    foreach($step in @($Report.Steps)){$lines+=[string]$step}
    $lines+=@('端口监听、设置复读、网站响应与账号可用分开判断。','保留正在运行的程序及专线；新连接可能受设置改变影响，旧程序环境需自行正常重开。')
    if($Report.AdminStatus){$lines+=@('',('机器级代理：'+[string]$Report.AdminStatus.Message));if($Report.AdminStatus.NeedsRepair){$lines+='发现机器级代理；点击“管理员恢复…”查看第二阶段方案，确认后才申请权限。'}}
    if($script:RecoveryLastResult){$lines+=@('','最近一次操作：'+(Get-NetworkRecoveryUiState $script:RecoveryLastResult.State),[string]$script:RecoveryLastResult.Message);if($script:RecoveryLastResult.Backup){$lines+=('本机备份：'+$script:RecoveryLastResult.Backup)}}
    $details.Text=$lines -join "`r`n";$details.Select(0,0)
    $choicePanel=New-Object Windows.Forms.FlowLayoutPanel;$choicePanel.Dock='Fill';$choicePanel.AutoSize=$true;$choicePanel.WrapContents=$true;$grid.Controls.Add($choicePanel,0,2)
    $label=New-Label $choicePanel '要恢复的代理：' 0 0 124 30 10
    $target=New-Object FlowSwitch.UI.RouteChoice;$target.Name='RecoveryTarget';$target.Width=360;$target.DropDownStyle='DropDownList';$target.DisplayMember='Name'
    foreach($profile in @($script:Profiles.Profiles)){[void]$target.Items.Add([pscustomobject]@{Id=$profile.Id;Name=$profile.Name})}
    $choicePanel.Controls.Add($target)
    if($target.Items.Count){$target.SelectedIndex=0}
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.AutoSize=$true;$buttons.WrapContents=$true;$buttons.Margin=New-Object Windows.Forms.Padding(0,12,0,0);$grid.Controls.Add($buttons,0,3)
    $reset=New-Button $buttons '重置代理／恢复普通上网…' 0 0 268 38 {$d=$this.FindForm();$d.Tag.Action='Direct';$d.DialogResult='OK'};$reset.Name='RecoveryReset';$reset.Primary=$true
    $proxy=New-Button $buttons '恢复到所选代理…' 0 0 188 38 {$d=$this.FindForm();if($d.Tag.Target.SelectedItem){$d.Tag.Action='Proxy';$d.DialogResult='OK'}};$proxy.Name='RecoveryProxy';$proxy.Enabled=($target.Items.Count -gt 0)
    $probe=New-Button $buttons '检测当前通路' 0 0 160 38 {$d=$this.FindForm();$d.Tag.Action='Probe';$d.DialogResult='OK'};$probe.Name='RecoveryProbe'
    $refresh=New-Button $buttons '重新检查' 0 0 128 38 {$d=$this.FindForm();$d.Tag.Action='Refresh';$d.DialogResult='OK'}
    $admin=New-Button $buttons '管理员恢复…' 0 0 164 38 {$d=$this.FindForm();$d.Tag.Action='Admin';$d.DialogResult='OK'};$admin.Name='RecoveryAdmin';$admin.Primary=($Report.AdminStatus -and $Report.AdminStatus.NeedsRepair)
    $undo=New-Button $buttons '撤回上次用户代理恢复…' 0 0 252 38 {$d=$this.FindForm();$d.Tag.Action='Undo';$d.DialogResult='OK'};$undo.Name='RecoveryUndo'
    $client=New-Button $buttons '客户端与内核检查' 0 0 184 38 {$d=$this.FindForm();$d.Tag.Action='Client';$d.DialogResult='OK'}
    $close=New-Button $buttons '关闭' 0 0 92 38 {};$close.DialogResult='Cancel';$dialog.CancelButton=$close
    $dialog.Tag=[pscustomobject]@{Action='';Target=$target;Details=$details;Reset=$reset;Proxy=$proxy;Probe=$probe;Admin=$admin;Undo=$undo;Buttons=$buttons}
    $dialog
}
function Invoke-NetworkRecoveryUIAction([string]$Action,[string]$Key='') {
    $kind=switch($Action){Direct{'RecoveryDirectPlan'}Proxy{if($Key -and @($script:Profiles.Profiles|Where-Object Id -ceq $Key).Count -eq 1){'RecoveryProxyPlan'}}Probe{'RecoveryProbe'}Refresh{'RecoveryScan'}Admin{'RecoveryAdminPlan'}Undo{'RecoveryUndoPlan'}Client{'DoctorScan'}}
    if($kind){$script:PendingAction=[pscustomobject]@{Kind=$kind;Key=$(if($Action -eq 'Proxy'){$Key}else{''})}}
}
function Show-NetworkRecoveryReport($Report) {
    $dialog=New-NetworkRecoveryDialog $Report;$old=$script:DialogOpen;$script:DialogOpen=$true
    try{$answer=$dialog.ShowDialog($form);$action=$dialog.Tag.Action;$key=if($dialog.Tag.Target.SelectedItem){$dialog.Tag.Target.SelectedItem.Id}else{''}}
    finally{$dialog.Dispose();$script:DialogOpen=$old;$script:Controls=@($script:Controls|Where-Object {-not $_.IsDisposed})}
    if($answer -eq 'OK'){Invoke-NetworkRecoveryUIAction $action $key}
}
function Show-NetworkRecoveryPrompt([string]$Text,[string]$Title,[string]$Buttons,[string]$Icon) {
    [Windows.Forms.MessageBox]::Show($form,$Text,$Title,$Buttons,$Icon)
}
function Show-NetworkRecoveryPlan($Plan,[string]$ApplyKind='RecoveryApply') {
    $old=$script:DialogOpen;$script:DialogOpen=$true
    try{
        $text=[string]$Plan.Message
        foreach($step in @($Plan.Steps)){$text+="`r`n"+[string]$step}
        if(-not $Plan.CanApply){[void](Show-NetworkRecoveryPrompt $text '恢复方案尚不能执行' 'OK' 'Information');return}
        if($Plan.NoChange){[void](Show-NetworkRecoveryPrompt ($text+"`r`n接下来查看机器级代理、隧道与通路检查结果。") '设置无需重复更改' 'OK' 'Information');$script:PendingAction=[pscustomobject]@{Kind='RecoveryScan';Key=''};return}
        $text+="`r`n`r`n先备份，执行前再次核对；不会结束正在运行的程序。确认后会影响采用这些设置的新连接。"
        if((Show-NetworkRecoveryPrompt $text '确认本次恢复范围' 'OKCancel' 'Warning') -eq 'OK'){
            $script:PendingAction=[pscustomobject]@{Kind=$ApplyKind;Key=($Plan|ConvertTo-Json -Depth 32 -Compress)}
        }
    }finally{$script:DialogOpen=$old}
}
function Complete-NetworkRecoveryUI($Result) {
    $script:RecoveryLastResult=$Result;Write-Activity $Result.Message
    $script:PendingAction=[pscustomobject]@{Kind='RecoveryScan';Key=''}
}

function New-NetworkDoctorDialog($Report) {
    $dialog=New-Object Windows.Forms.Form;$dialog.Name='FlowNetworkDoctor';$dialog.Text='断网排查与恢复';$dialog.Font=$form.Font;$dialog.BackColor=$paper;$dialog.ForeColor=$ink
    $dialog.ClientSize=New-Object Drawing.Size(820,610);$dialog.MinimumSize=New-Object Drawing.Size(660,480);$dialog.StartPosition='CenterParent'
    $grid=New-Grid $dialog 3 @(0,-1,0);$grid.Padding=New-Object Windows.Forms.Padding(20)
    $caption=New-Label $grid $Report.Headline 0 0 760 42 15 $true;$caption.Name='DoctorHeadline';$caption.Dock='Fill';$caption.AutoSize=$true;$caption.Margin=New-Object Windows.Forms.Padding(0,0,0,14);$grid.SetCellPosition($caption,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
    $grid.Add_SizeChanged({$c=$this.Controls['DoctorHeadline'];if($c){$c.MaximumSize=New-Object Drawing.Size([Math]::Max(1,$this.ClientSize.Width-$this.Padding.Horizontal),0)}})
    $reading=New-Object Windows.Forms.TextBox;$reading.Name='DoctorDetails';$reading.Multiline=$true;$reading.ReadOnly=$true;$reading.ScrollBars='Vertical';$reading.Dock='Fill';$reading.WordWrap=$true;$reading.BackColor=$paper;$reading.ForeColor=$ink;$reading.BorderStyle='None';$reading.Margin=New-Object Windows.Forms.Padding(0,0,0,12);$grid.Controls.Add($reading,0,1)
    $names=@{WindowsProxy='Windows 系统代理';ProxyEndpoint='代理端口';ClashClient='Clash 主程序';ClashCore='Clash 代理内核';ProxyEnvironment='程序代理变量';Startup='开机入口';TopologyIPv4='IPv4 路由';TopologyIPv6='IPv6 路由';NetworkTopology='VPN / 隧道路由';WindowsViews='Windows 设置读取';Configuration='入口配置';EnvironmentProxy='程序代理变量';ClashStartupConfiguration='Clash 启动设置'}
    $states=@{Running='运行中';Stopped='未运行';Ready='监听与归属已确认';Unknown='尚不能确定';VerifiedEndpoint='已确认内核提供入口';Direct='系统手动代理关闭';Unavailable='读取不完整';Mismatch='不一致';Aligned='一致';Unset='未设置';Available='已读取';Current='已核验';Changed='发生变化';Different='目标不同';NoConflictingTarget='未见目标分歧';Evidence='发现隧道路由证据';NoEvidence='未见隧道路由证据'}
    $lines=@($Report.Message,'','检查结果')
    foreach($check in @($Report.Checks)){
        $name=$names[[string]$check.Name];if(-not $name){$name=[string]$check.Name}
        $state=$states[[string]$check.State];if(-not $state){$state=[string]$check.State}
        $lines+=@(($name+'：'+$state),('  '+$check.Detail))
    }
    $lines+=@('','接下来怎么做');$n=0
    foreach($step in @($Report.Steps)){$n++;$lines+=($n.ToString()+'. '+$step)}
    if($Report.Probe){$lines+=@('',('HTTPS 检测：'+$(if($Report.Probe.Usable){'本轮固定站点有成功响应'}else{'本轮未通过'})),$Report.Probe.Message)}
    $lines+=@('','客户端关窗与托盘退出行为以其设置为准；按本轮内核及入口检测判断。','备用客户端异常时，保留仍可用的当前入口。切换前先确认目标入口可用，再从首页预览。','“检查旧代理残留”用于单个程序；“整理旧线路”用于维护记录，不能启动缺失的代理客户端。',('检查时间：'+$Report.CheckedAt))
    $reading.Text=$lines -join "`r`n";$reading.TabStop=$false;$reading.SelectionLength=0
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.AutoSize=$true;$buttons.WrapContents=$true;$grid.Controls.Add($buttons,0,2)
    $start=New-Button $buttons '预览启动 Clash…' 0 0 186 38 {$d=$this.FindForm();if($d.Tag.Report.CanStartClient){$d.Tag.Action='Start';$d.DialogResult='OK'}};$start.Enabled=[bool]$Report.CanStartClient
    $apply=New-Button $buttons '预览恢复代理设置…' 0 0 202 38 {$d=$this.FindForm();if($d.Tag.Report.CanApplyProxy){$d.Tag.Action='Apply';$d.DialogResult='OK'}};$apply.Enabled=[bool]$Report.CanApplyProxy
    $probe=New-Button $buttons '检测 HTTPS 通路' 0 0 178 38 {$d=$this.FindForm();if($d.Tag.Report.CanProbe){$d.Tag.Action='Probe';$d.DialogResult='OK'}};$probe.Enabled=[bool]$Report.CanProbe
    $refresh=New-Button $buttons '重新排查' 0 0 128 38 {$d=$this.FindForm();$d.Tag.Action='Refresh';$d.DialogResult='OK'}
    $programs=New-Button $buttons '只有某个程序出错' 0 0 190 38 {$d=$this.FindForm();$d.Tag.Action='Programs';$d.DialogResult='OK'}
    $close=New-Button $buttons '关闭' 0 0 92 38 {};$close.DialogResult='Cancel';$dialog.CancelButton=$close
    $start.Primary=$start.Enabled;$apply.Primary=(-not $start.Enabled -and $apply.Enabled);$probe.Primary=(-not $start.Enabled -and -not $apply.Enabled -and $probe.Enabled)
    $dialog.ActiveControl=$(if($start.Enabled){$start}elseif($apply.Enabled){$apply}elseif($probe.Enabled){$probe}else{$refresh})
    $dialog.Tag=[pscustomobject]@{Report=$Report;Action='';Details=$reading;Start=$start;Apply=$apply;Probe=$probe;Refresh=$refresh;Programs=$programs;Buttons=$buttons}
    $dialog
}
function Invoke-NetworkDoctorAction($Report,[string]$Action) {
    switch($Action){
        'Start'{if($Report.CanStartClient -and $Report.TargetKey){$script:PendingAction=[pscustomobject]@{Kind='DoctorStartPlan';Key=$Report.TargetKey}}}
        'Apply'{if($Report.CanApplyProxy -and $Report.TargetKey){$script:PendingAction=[pscustomobject]@{Kind='DailyPlan';Key=$Report.TargetKey}}}
        'Probe'{if($Report.CanProbe){$script:PendingAction=[pscustomobject]@{Kind='DoctorProbe';Key=''}}}
        'Refresh'{$script:PendingAction=[pscustomobject]@{Kind='DoctorScan';Key=''}}
        'Programs'{$tabs.SelectedTab=$programPage;Write-Activity '选中出问题的程序，点击“排查此程序网络”。需要时再检查旧代理残留；先保留正在使用的程序。'}
    }
}
function Show-NetworkDoctorReport($Report) {
    $dialog=New-NetworkDoctorDialog $Report;$old=$script:DialogOpen;$script:DialogOpen=$true
    try{$answer=$dialog.ShowDialog($form);$action=$dialog.Tag.Action}finally{$dialog.Dispose();$script:DialogOpen=$old;$script:Controls=@($script:Controls|Where-Object {-not $_.IsDisposed})}
    if($answer -eq 'OK'){Invoke-NetworkDoctorAction $Report $action}
}
function Show-NetworkDoctorStartPlan($Plan) {
    Write-Activity $Plan.Message
    if(-not $Plan.CanApply){return}
    $old=$script:DialogOpen;$script:DialogOpen=$true
    try{
        $text=$Plan.Message+"`r`n`r`n客户端："+$Plan.ClientPath+"`r`n`r`n"+'本次只启动客户端一次。Clash 会按自身设置管理系统代理；流向不会结束其他程序或后台抢回设置。启动后还需要重新排查并检测 HTTPS。'
        if([Windows.Forms.MessageBox]::Show($form,$text,'启动代理客户端前确认','OKCancel','Information') -eq 'OK'){$script:PendingAction=[pscustomobject]@{Kind='DoctorStart';Key=($Plan|ConvertTo-Json -Depth 32 -Compress)}}
    }finally{$script:DialogOpen=$old}
}

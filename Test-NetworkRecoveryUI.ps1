param([string]$OutputDirectory='',[ValidateSet(1,1.5)][double]$Scale=1)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::ThrowException)
$qa=Join-Path $env:TEMP ('FlowSwitch-recovery-ui-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($qa)
$build=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Build-WindowsPackage.ps1'))
$match=[regex]::Match($build,'(?s)\$runtime=@\((.*?)\r?\n\)')
if(-not $match.Success){throw 'Runtime whitelist unavailable'}
foreach($name in @([regex]::Matches($match.Groups[1].Value,"'([^']+)'")|ForEach-Object {$_.Groups[1].Value})){
    $dest=Join-Path $qa $name;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $dest
}
$guards=@'

function Set-SystemSnapshot {throw 'Recovery UI attempted Windows write'}
function Set-UserProxyEnv {throw 'Recovery UI attempted environment write'}
function Enable-IndependentGateway {throw 'Recovery UI attempted engine startup'}
function Start-NetworkRecoveryAdminHelper {throw 'Recovery UI attempted elevation'}
function Get-NetworkRecoveryReport {throw 'Recovery UI attempted synchronous diagnosis'}
'@
[IO.File]::AppendAllText((Join-Path $qa 'ProxyBackend.ps1'),$guards,(New-Object Text.UTF8Encoding($true)))
$checks=@'
        . (Join-Path $PSScriptRoot 'NetworkRecoveryUI.ps1')
        $script:RecoveryChecks=0
        function Check-Recovery($Value,[string]$Message){if(-not $Value){throw ('Recovery UI: '+$Message)};$script:RecoveryChecks++}
        function Start-Work([string]$Kind,[string]$Key){$script:RecoveryRequest=[pscustomobject]@{Kind=$Kind;Key=$Key}}
        $factor=[double]::Parse($env:FLOW_RECOVERY_UI_SCALE,[Globalization.CultureInfo]::InvariantCulture)
        $tabs.SelectedTab=$homePage;$networkDoctorHomeButton.PerformClick()
        Check-Recovery ($script:RecoveryRequest.Kind -eq 'RecoveryScan') 'home starts read-only unified diagnosis'
        $resetProxyHomeButton.PerformClick()
        Check-Recovery ($script:RecoveryRequest.Kind -eq 'RecoveryDirectPlan') 'home reset opens preview only'
        $script:Profiles=[pscustomobject]@{Profiles=@()}
        $fixture=[pscustomobject]@{Summary='代理程序已卸载或停止，当前设置仍指向无响应入口。';Checks=@([pscustomobject]@{Name='系统代理';State='失效入口';Detail='本轮未发现监听。'});Findings=@();Steps=@('先预览恢复普通上网，再检测普通网站。');AdminStatus=[pscustomobject]@{State='Available';NeedsRepair=$true;Message='检测到机器级代理；用户代理恢复后可单独处理。'}}
        $dialog=New-NetworkRecoveryDialog $fixture
        try {
            $dialog.ShowInTaskbar=$false;$dialog.Opacity=0;$dialog.Show();$dialog.CreateControl()
            if($factor -ne 1){$dialog.Scale((New-Object Drawing.SizeF($factor,$factor)));$dialog.Font=New-Object Drawing.Font($form.Font.FontFamily,($form.Font.Size*$factor))}
            foreach($size in @((New-Object Drawing.Size(880,660)),(New-Object Drawing.Size(700,550)))){
                $dialog.ClientSize=$size;$dialog.PerformLayout();[Windows.Forms.Application]::DoEvents()
                foreach($control in @($dialog.Tag.Details,$dialog.Tag.Reset,$dialog.Tag.Proxy,$dialog.Tag.Probe,$dialog.Tag.Admin,$dialog.Tag.Undo)){
                    $rect=$control.RectangleToScreen($control.ClientRectangle)
                    for($p=$control.Parent;$p;$p=$p.Parent){Check-Recovery ($p.RectangleToScreen($p.ClientRectangle).Contains($rect)) ($control.Name+' clipped')}
                }
            }
            Check-Recovery ($dialog.Tag.Reset.Enabled -and -not $dialog.Tag.Proxy.Enabled) 'uninstalled or unregistered client does not block Direct reset'
            Check-Recovery ($dialog.Tag.Admin.Primary -and $dialog.Tag.Details.Text -match '确认后才申请权限') 'machine findings explain elevation before action'
            Check-Recovery ($dialog.Tag.Details.Text -match '账号可用分开判断' -and $dialog.Tag.Details.Text -match '旧程序环境') 'scope and real-app limits visible'
            $dialog.ClientSize=New-Object Drawing.Size(880,660);$dialog.PerformLayout();[Windows.Forms.Application]::DoEvents()
            if($env:FLOW_RECOVERY_UI_OUTPUT){$capture=New-Object Drawing.Bitmap($dialog.Width,$dialog.Height);try{$dialog.DrawToBitmap($capture,(New-Object Drawing.Rectangle(0,0,$dialog.Width,$dialog.Height)));$capture.Save((Join-Path $env:FLOW_RECOVERY_UI_OUTPUT ('recovery-'+$factor+'.png')))}finally{$capture.Dispose()}}
            $dialog.Tag.Reset.PerformClick();Check-Recovery ($dialog.Tag.Action -eq 'Direct' -and $dialog.DialogResult -eq 'OK') 'reset button dispatches fixed goal'
        } finally {$dialog.Dispose()}
        foreach($pair in @(@('Direct','RecoveryDirectPlan'),@('Admin','RecoveryAdminPlan'),@('Undo','RecoveryUndoPlan'),@('Probe','RecoveryProbe'),@('Refresh','RecoveryScan'),@('Client','DoctorScan'))){
            $script:PendingAction=$null;Invoke-NetworkRecoveryUIAction $pair[0];Check-Recovery ($script:PendingAction.Kind -eq $pair[1] -and $script:PendingAction.Key -eq '') ($pair[0]+' dispatch')
        }
        $script:PendingAction=$null;Invoke-NetworkRecoveryUIAction 'Proxy' 'missing';Check-Recovery ($null -eq $script:PendingAction) 'removed proxy cannot be selected'
        $script:Profiles=[pscustomobject]@{Profiles=@([pscustomobject]@{Id='fixture';Name='已登记代理'})}
        Invoke-NetworkRecoveryUIAction 'Proxy' 'fixture';Check-Recovery ($script:PendingAction.Kind -eq 'RecoveryProxyPlan' -and $script:PendingAction.Key -eq 'fixture') 'selected registered proxy preview'
        $dialog=New-NetworkRecoveryDialog $fixture;try{Check-Recovery ($dialog.Tag.Proxy.Enabled -and $dialog.Tag.Target.SelectedItem.Id -eq 'fixture') 'registered proxy selectable'}finally{$dialog.Dispose()}
        $fixture|Add-Member NoteProperty Verification ([pscustomobject]@{Request='RequestFailed';Targets=@([pscustomobject]@{Stage='probe-timeout';HttpCode=0},[pscustomobject]@{Stage='https-response';HttpCode=401})})
        $dialog=New-NetworkRecoveryDialog $fixture;try{Check-Recovery ($dialog.Tag.Details.Text -match '本轮请求失败' -and $dialog.Tag.Details.Text -match '请求超时' -and $dialog.Tag.Details.Text -match 'HTTP 401') 'probe result and status are visible, never hidden behind generic guidance'}finally{$dialog.Dispose()}
        Complete-NetworkRecoveryUI ([pscustomobject]@{State='Partial';Message='设置已重置；通路尚未验证。';Backup='fixture-private-backup'})
        Check-Recovery ($script:PendingAction.Kind -eq 'RecoveryScan' -and $script:RecoveryLastResult.State -eq 'Partial') 'post-action rechecks without automatic network probe'
        function Show-NetworkRecoveryPrompt {$script:PromptChoice}
        $script:PromptChoice='Cancel';$script:PendingAction=$null
        $preview=[pscustomobject]@{CanApply=$true;NoChange=$false;Message='fixture';Steps=@();Revision='bound-fixture'}
        Show-NetworkRecoveryPlan $preview;Check-Recovery ($null -eq $script:PendingAction) 'cancelled confirmation never enqueues mutation'
        $script:PromptChoice='OK';Show-NetworkRecoveryPlan $preview
        Check-Recovery ($script:PendingAction.Kind -eq 'RecoveryApply' -and ($script:PendingAction.Key|ConvertFrom-Json).Revision -eq 'bound-fixture') 'confirmation preserves bound plan for worker revalidation'
        $script:PendingAction=$null;$preview.NoChange=$true;Show-NetworkRecoveryPlan $preview
        Check-Recovery ($script:PendingAction.Kind -eq 'RecoveryScan') 'already Direct opens machine and tunnel diagnosis instead of ending with no-change'
        $script:PendingAction=$null;$preview.CanApply=$false;Show-NetworkRecoveryPlan $preview
        Check-Recovery ($null -eq $script:PendingAction) 'blocked preview never enqueues mutation'
        Write-Output ('PASS: '+$script:RecoveryChecks+' recovery UI checks; scale '+$factor+'; isolated WinForms.')
'@
$path=Join-Path $qa 'ProxyWindow.ps1';$source=[IO.File]::ReadAllText($path);$marker='$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)'
if(([regex]::Matches($source,[regex]::Escape($marker))).Count -ne 1){throw 'Preview marker must be unique'}
[IO.File]::WriteAllText($path,$source.Replace($marker,$checks+"`r`n"+$marker),(New-Object Text.UTF8Encoding($true)))
$prior=$env:FLOW_RECOVERY_UI_SCALE;$priorOutput=$env:FLOW_RECOVERY_UI_OUTPUT
try{
    $env:FLOW_RECOVERY_UI_SCALE=$Scale.ToString([Globalization.CultureInfo]::InvariantCulture);$env:FLOW_RECOVERY_UI_OUTPUT=$OutputDirectory
    if($OutputDirectory){[void][IO.Directory]::CreateDirectory($OutputDirectory)}
    $passed=$false
    & (Join-Path $qa 'ProxySwitch.ps1') -Demo -PreviewView Home -DataDirectory (Join-Path $qa 'data') -PreviewPath (Join-Path $qa 'home.png') | ForEach-Object {if($_ -match '^PASS: \d+ recovery UI checks'){$passed=$true};Write-Output $_}
    if(-not $passed){throw 'Recovery UI assertions did not complete'}
    if($OutputDirectory){Copy-Item -LiteralPath (Join-Path $qa 'home.png') -Destination (Join-Path $OutputDirectory ('home-'+$Scale+'.png'))}
}finally{$env:FLOW_RECOVERY_UI_SCALE=$prior;$env:FLOW_RECOVERY_UI_OUTPUT=$priorOutput}

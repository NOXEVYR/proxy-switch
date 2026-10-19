param([string]$OutputDirectory='',[double]$Scale=1)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'FlowTheme.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing
Add-Type -TypeDefinition 'public class OffscreenFlowDiagnosisForm : System.Windows.Forms.Form { protected override bool ShowWithoutActivation { get { return true; } } }' -ReferencedAssemblies System.Windows.Forms
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'ProxyWindow.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw 'Window parse failed'}
foreach($name in @('New-Label','New-Button','New-Grid','Get-NetworkDiagnosisActions','Invoke-NetworkDiagnosisAction','New-NetworkDiagnosisDialog')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $fn){throw ('Missing dialog function '+$name)}
    $definition=$fn.Extent.Text
    if($name -eq 'New-NetworkDiagnosisDialog'){$definition=$definition.Replace('New-Object Windows.Forms.Form;','New-Object OffscreenFlowDiagnosisForm;')}
    . ([scriptblock]::Create($definition))
}
$script:checks=0;$script:Controls=@()
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
$ink=[Drawing.ColorTranslator]::FromHtml('#EBF3FC');$paper=[Drawing.ColorTranslator]::FromHtml('#121C2B')
$form=New-Object Windows.Forms.Form;$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',[float](10*$Scale))
$report=[pscustomobject]@{Conclusion=[pscustomobject]@{State='ProblemFound';Title='系统代理设置不一致'};Summary="发现的问题：应用读取到的代理设置不一致。`r`n`r`n1. 系统设置：发现差异`r`n2. 当前入口：正在监听`r`n3. 代理通路：收到 HTTPS 响应`r`n4. 程序连接：需要在应用中重试`r`n`r`n下一步：在代理客户端重新核对系统代理，返回应用重试后重新检查。";Message='详细证据保留在独立页面，摘要没有被日志挤掉。';RepairAction='';Revision='fixture';RepairText='fixture only'}
$dialogs=@()
try{
    foreach($size in @(@(880,650),@(620,440))){
        $dialog=New-NetworkDiagnosisDialog $report;$dialogs+=@($dialog)
        $dialog.ShowInTaskbar=$false;$dialog.StartPosition='Manual';$dialog.Location=New-Object Drawing.Point(-32000,-32000)
        $dialog.ClientSize=New-Object Drawing.Size($size[0],$size[1]);$dialog.Show();$dialog.PerformLayout();[Windows.Forms.Application]::DoEvents()
        [void]$dialog.Handle;[void]$dialog.Tag.Pages.Handle
        $dialog.Tag.Grid.PerformLayout();$dialog.Tag.Pages.PerformLayout();$dialog.Tag.Pages.TabPages[0].PerformLayout()
        Check ($dialog.Name -eq 'FlowNetworkDiagnosis') 'Result dialog identity missing'
        Check ($dialog.Tag.Pages.TabPages.Count -eq 3) 'Summary, details and actionable steps must be separate pages'
        Check ($dialog.Tag.Reading.Text -ceq $report.Summary -and $dialog.Tag.Details.Text -ceq $report.Message) 'Summary replaced by raw diagnostic text'
        Check (-not $dialog.Tag.Repair.Enabled) 'Missing repair plan should not offer an enabled mutation'
        Check ($dialog.Tag.Retry.DialogResult -eq 'Retry' -and $dialog.Tag.Close.DialogResult -eq 'Cancel') 'Read-only recheck and close actions missing'
        foreach($control in @($dialog.Tag.Close,$dialog.Tag.Retry,$dialog.Tag.Repair,$dialog.Tag.Steps)){
            Check ($control.Left -ge 0 -and $control.Top -ge 0 -and $control.Right -le $control.Parent.ClientSize.Width -and $control.Bottom -le $control.Parent.ClientSize.Height) 'Dialog action clipped at a supported window size'
        }
        Check ($dialog.Tag.Reading.ClientSize.Height -gt 120) ('Summary height='+$dialog.Tag.Reading.ClientSize.Height+'; page='+$dialog.Tag.Reading.Parent.ClientSize+'; tabs='+$dialog.Tag.Pages.ClientSize+'; grid='+$dialog.Tag.Grid.ClientSize)
        if($OutputDirectory){
            [void][IO.Directory]::CreateDirectory($OutputDirectory)
            $bitmap=New-Object Drawing.Bitmap($dialog.Width,$dialog.Height)
            try{$dialog.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$dialog.Width,$dialog.Height)));$bitmap.Save((Join-Path $OutputDirectory ('diagnosis-'+$size[0]+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
        }
    }
    $system=$report|Select-Object *;$system.RepairAction='recover-session'
    $program=[pscustomobject]@{Conclusion=$report.Conclusion;Summary=$report.Summary;Message='软件检查详情';SystemDiagnosis=$system}
    $dialog=New-NetworkDiagnosisDialog $program 'C:\Fixtures\editor.exe';$dialogs+=@($dialog)
    Check ($dialog.Tag.Repair.Enabled -and $dialog.Tag.Plan.RepairAction -eq 'recover-session') 'Program report failed to expose the explicit system plan'
    Check ($dialog.Tag.TargetPath -ceq 'C:\Fixtures\editor.exe' -and $dialog.Text -eq '程序网络排查') 'Recheck lost the chosen program identity'

    $program|Add-Member NoteProperty Program ([pscustomobject]@{ObservedPath='C:\Fixtures\editor.exe';SavedPath='C:\Fixtures\editor.exe';ObservationState='Observed';Running=$true;HasSavedRule=$true;CanLaunch=$true;RecordRequiresReview=$false;RecordCanRepair=$false})
    $program|Add-Member NoteProperty Evidence ([pscustomobject]@{ControllerVerifiedCount=1})
    foreach($size in @(@(880,650),@(620,440))){
        $dialog=New-NetworkDiagnosisDialog $program 'C:\Fixtures\editor.exe';$dialogs+=@($dialog)
        $dialog.ShowInTaskbar=$false;$dialog.StartPosition='Manual';$dialog.Location=New-Object Drawing.Point(-32000,-32000);$dialog.ClientSize=New-Object Drawing.Size($size[0],$size[1]);$dialog.Show();[Windows.Forms.Application]::DoEvents()
        $dialog.Tag.Steps.PerformClick();[Windows.Forms.Application]::DoEvents()
        Check ($dialog.Tag.Pages.SelectedIndex -eq 2) 'Treatment button does not reveal action page'
        $launch=@($dialog.Tag.ActionChoice.Items|Where-Object Id -eq 'program-launch')[0];$dialog.Tag.ActionChoice.SelectedItem=$launch;[Windows.Forms.Application]::DoEvents()
        Check (-not $dialog.Tag.RunStep.Enabled -and $dialog.Tag.ActionExplanation.Text -match '完整正常退出') 'Running program can be relaunched or lacks explicit exit prerequisite'
        $dialog.Tag.ActionChoice.SelectedIndex=0;[Windows.Forms.Application]::DoEvents()
        Check ($dialog.Tag.RunStep.Enabled -and $dialog.Tag.ActionChoice.SelectedItem.Path -ceq 'C:\Fixtures\editor.exe') 'Targeted navigation loses its path'
        Check ($dialog.Tag.RunStep.Right -le $dialog.Tag.RunStep.Parent.ClientSize.Width -and $dialog.Tag.RunStep.Bottom -le $dialog.Tag.RunStep.Parent.ClientSize.Height) 'Treatment execution button clipped'
        Check ($dialog.Tag.ActionExplanation.ClientSize.Height -gt 90) 'Treatment explanation has no usable viewport'
        if($OutputDirectory){$bitmap=New-Object Drawing.Bitmap($dialog.Width,$dialog.Height);try{$dialog.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$dialog.Width,$dialog.Height)));$bitmap.Save((Join-Path $OutputDirectory ('diagnosis-actions-'+$size[0]+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}}
    }
    $program|Add-Member NoteProperty ObservedProxyScope ([pscustomobject]@{State='Ready';ForwardingState='AllTimeout'})
    $program.Conclusion=[pscustomobject]@{State='NeedsRetest';Title='外部代理入口代测均超时'}
    $stalledDialog=New-NetworkDiagnosisDialog $program 'C:\Fixtures\editor.exe';$dialogs+=@($stalledDialog)
    Check ($stalledDialog.Tag.ActionChoice.SelectedItem.Id -eq 'proxy-catalog' -and $stalledDialog.Tag.ActionExplanation.Text -match '入口仍监听.*代测均超时' -and $stalledDialog.Tag.ActionExplanation.Text -match '只打开') 'A stalled actual proxy promotes restarting or rewriting application settings instead of upstream inspection'
    $program.ObservedProxyScope|Add-Member NoteProperty CoverageLimited $true
    $stalledDialog=New-NetworkDiagnosisDialog $program 'C:\Fixtures\editor.exe';$dialogs+=@($stalledDialog)
    Check ($stalledDialog.Tag.ActionExplanation.Text -match '仅针对已核验成员.*观察不完整') 'Upstream guidance hides the limited process-family coverage'
    if($OutputDirectory){
        $stalledDialog.ShowInTaskbar=$false;$stalledDialog.StartPosition='Manual';$stalledDialog.Location=New-Object Drawing.Point(-32000,-32000);$stalledDialog.ClientSize=New-Object Drawing.Size(620,440);$stalledDialog.Show();$stalledDialog.Tag.Steps.PerformClick();[Windows.Forms.Application]::DoEvents()
        $bitmap=New-Object Drawing.Bitmap($stalledDialog.Width,$stalledDialog.Height)
        try{$stalledDialog.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$stalledDialog.Width,$stalledDialog.Height)));$bitmap.Save((Join-Path $OutputDirectory 'diagnosis-stalled-620.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
    }
    $program.ObservedProxyScope.State='Changed'
    Check (@(Get-NetworkDiagnosisActions $program 'C:\Fixtures\editor.exe')[0].Id -eq 'program-settings') 'Changed observation incorrectly promotes a stale timeout conclusion'
    $program.ObservedProxyScope.State='Ready';$program.ObservedProxyScope.ForwardingState='PartialResponse'
    Check (@(Get-NetworkDiagnosisActions $program 'C:\Fixtures\editor.exe')[0].Id -eq 'program-settings') 'A partial response is treated as all targets timing out'
    # Recheck the current selected identity before a whitelisted action; old AppTarget is unrelated.
    $tabs=New-Object Windows.Forms.TabControl;$programPage=New-Object Windows.Forms.TabPage('programs');$proxyPage=New-Object Windows.Forms.TabPage('proxies');$tabs.TabPages.AddRange(@($programPage,$proxyPage))
    $liveList=New-Object Windows.Forms.ListView;$liveList.MultiSelect=$false;$liveList.HideSelection=$false;$programPage.Controls.Add($liveList);[void]$liveList.Handle
    $app=[pscustomobject]@{Path='C:\Fixtures\editor.exe';SavedPath='C:\Fixtures\editor.exe';ObservationState='Observed';RequiresRepair=$false;CanRepair=$false;CanLaunch=$true;PIDs='123'}
    $item=New-Object Windows.Forms.ListViewItem('editor');$item.Tag=$app;[void]$liveList.Items.Add($item)
    $other=New-Object Windows.Forms.ListViewItem('other');$other.Tag=[pscustomobject]@{Path='C:\Fixtures\other.exe'};[void]$liveList.Items.Add($other);$other.Selected=$true;$script:AppTarget=$other.Tag
    function Write-Activity($Text){$script:lastActivity=$Text}
    function Set-UiActionAvailability {}
    function Show-SelectedMenu {$script:navigated=@($liveList.SelectedItems)[0].Tag.Path}
    $steps=@(Get-NetworkDiagnosisActions $program 'C:\Fixtures\editor.exe')
    Invoke-NetworkDiagnosisAction ($steps|Where-Object Id -eq 'program-settings')
    Check ($script:navigated -ceq $app.Path) 'Action reused unrelated global AppTarget'
    $script:PendingAction=$null
    $launch=$steps|Where-Object Id -eq 'program-launch';$launch.Enabled=$true
    Invoke-NetworkDiagnosisAction $launch
    Check ($null -eq $script:PendingAction -and $script:lastActivity -match '仍在运行') 'Stale launch prerequisite silently restarted a running program'
    $clean=$steps|Where-Object Id -eq 'program-clean';Invoke-NetworkDiagnosisAction $clean
    Check ($script:PendingAction.Kind -eq 'CleanStartPlan' -and -not ($script:PendingAction.Key|ConvertFrom-Json).DirectTest) 'Clean environment shortcut skipped preview or enabled global direct test'
    $script:PendingAction=$null;$app.Path='C:\Fixtures\updated.exe'
    Invoke-NetworkDiagnosisAction $clean
    Check ($null -eq $script:PendingAction -and $script:lastActivity -match '路径已变化') 'Changed executable identity accepted an old action'
    Invoke-NetworkDiagnosisAction ([pscustomobject]@{Id='arbitrary-command';Enabled=$true;Path=$app.Path})
    Check ($null -eq $script:PendingAction -and $script:lastActivity -match '无效') 'Unrecognized action dispatched arbitrary work'
    $tabs.Dispose()

    # Exercise the real selected-program dispatch handler with a non-launching worker stub.
    $assignment=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$programDiagnoseButton'},$true)
    $action=$assignment.Right.Find({param($n)$n -is [Management.Automation.Language.ScriptBlockExpressionAst]},$true)
    function Start-Work([string]$Kind,[string]$Key){$script:request=[pscustomobject]@{Kind=$Kind;Key=$Key}}
    $liveList=[pscustomobject]@{SelectedItems=@([pscustomobject]@{Tag=[pscustomobject]@{Path='C:\Fixtures\editor.exe'}})}
    $actionText=$action.ScriptBlock.Extent.Text;$handler=[scriptblock]::Create($actionText.Substring(1,$actionText.Length-2))
    . $handler
    Check ($script:request.Kind -eq 'ProgramNetworkDiagnose' -and $script:request.Key -ceq 'C:\Fixtures\editor.exe') 'Program check did not bind to selected path'
    $script:request=$null;$liveList.SelectedItems=@()
    . $handler
    Check ($null -eq $script:request) 'No program selection still dispatched a check'
    Write-Output ('PASS: '+$script:checks+' diagnostic dialog and dispatch checks; offscreen synthetic UI only.')
}finally{foreach($dialog in $dialogs){$dialog.Dispose()};$form.Dispose()}

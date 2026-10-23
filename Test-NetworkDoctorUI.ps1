param([string]$OutputDirectory='',[ValidateSet(1,1.5)][double]$Scale=1)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::ThrowException)
$qa=Join-Path $env:TEMP ('FlowSwitch-doctor-ui-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($qa)
$build=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Build-WindowsPackage.ps1'))
$match=[regex]::Match($build,'(?s)\$runtime=@\((.*?)\r?\n\)')
if(-not $match.Success){throw 'Runtime whitelist unavailable'}
$files=@([regex]::Matches($match.Groups[1].Value,"'([^']+)'")|ForEach-Object {$_.Groups[1].Value})
foreach($name in $files){$dest=Join-Path $qa $name;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $dest}
$guards=@'

function Set-SystemSnapshot {throw 'Doctor UI attempted Windows write'}
function Set-UserProxyEnv {throw 'Doctor UI attempted environment write'}
function Enable-IndependentGateway {throw 'Doctor UI attempted engine startup'}
function Start-NetworkDoctorClient {throw 'Doctor UI attempted client startup'}
function Get-NetworkDoctorReport {throw 'Doctor UI attempted synchronous diagnosis'}
function Get-DailyProxyContext {throw 'Doctor UI attempted synchronous network snapshot'}
'@
[IO.File]::AppendAllText((Join-Path $qa 'ProxyBackend.ps1'),$guards,(New-Object Text.UTF8Encoding($true)))
$checks=@'
        . (Join-Path $PSScriptRoot 'NetworkDoctorUI.ps1')
        $script:DoctorChecks=0
        function Check-Doctor($Value,[string]$Message){if(-not $Value){throw ('Doctor UI: '+$Message)};$script:DoctorChecks++}
        function Start-Work([string]$Kind,[string]$Key){$script:DoctorRequest=[pscustomobject]@{Kind=$Kind;Key=$Key}}
        $factor=[double]::Parse($env:FLOW_DOCTOR_UI_SCALE,[Globalization.CultureInfo]::InvariantCulture)
        $tabs.SelectedTab=$homePage;$networkDoctorHomeButton.PerformClick()
        Check-Doctor ($script:DoctorRequest.Kind -eq 'RecoveryScan' -and $script:DoctorRequest.Key -eq '') 'home dispatches local read-only diagnosis'
        $fixture=[pscustomobject]@{Kind='NetworkDoctor';CheckedAt='12:30';State='ClientStopped';Headline='代理客户端未运行';Message='当前设置仍指向 Clash，但主程序和代理内核已停止；仅有服务进程不足以联网。';Steps=@('预览启动 Clash，保留其他程序。','客户端就绪后重新排查，再检测 HTTPS 通路。');Checks=@([pscustomobject]@{Name='WindowsProxy';State='Clash';Detail='系统与代理变量仍指向这个入口。'},[pscustomobject]@{Name='ClashCore';State='Stopped';Detail='没有可核验的监听入口。'});TargetKey='fixture-clash';CanStartClient=$true;CanApplyProxy=$false;CanProbe=$false;ClientPath='C:\Fixture\Clash\clash-verge.exe';Probe=$null}
        $dialog=New-NetworkDoctorDialog $fixture
        try{
            $dialog.ShowInTaskbar=$false;$dialog.Opacity=0;$dialog.Show();$dialog.CreateControl()
            if($factor -ne 1){$dialog.Scale((New-Object Drawing.SizeF($factor,$factor)));$dialog.Font=New-Object Drawing.Font($form.Font.FontFamily,($form.Font.Size*$factor))}
            $dialog.MinimumSize=New-Object Drawing.Size(620,440)
            foreach($size in @((New-Object Drawing.Size(820,610)),(New-Object Drawing.Size(680,500)))){
                $dialog.ClientSize=$size;$dialog.PerformLayout();[Windows.Forms.Application]::DoEvents()
                foreach($control in @($dialog.Tag.Details,$dialog.Tag.Start,$dialog.Tag.Apply,$dialog.Tag.Probe,$dialog.Tag.Refresh,$dialog.Tag.Programs)){
                    $rect=$control.RectangleToScreen($control.ClientRectangle)
                    for($p=$control.Parent;$p;$p=$p.Parent){Check-Doctor ($p.RectangleToScreen($p.ClientRectangle).Contains($rect)) ($control.Text+' clipped')}
                }
            }
            Check-Doctor ($dialog.Tag.Start.Enabled -and -not $dialog.Tag.Apply.Enabled -and -not $dialog.Tag.Probe.Enabled) 'stopped client offers preview, never dead-end proxy apply'
            Check-Doctor ($dialog.Tag.Details.Text -match '内核' -and $dialog.Tag.Details.Text -match '不足以联网' -and $dialog.Tag.Details.Text -match '不能启动缺失') 'explains core/service/cleanup distinction'
            $dialog.ClientSize=New-Object Drawing.Size(820,610);$dialog.PerformLayout();[Windows.Forms.Application]::DoEvents()
            if($env:FLOW_DOCTOR_UI_OUTPUT){$capture=New-Object Drawing.Bitmap($dialog.Width,$dialog.Height);try{$dialog.DrawToBitmap($capture,(New-Object Drawing.Rectangle(0,0,$dialog.Width,$dialog.Height)));$capture.Save((Join-Path $env:FLOW_DOCTOR_UI_OUTPUT 'doctor-stopped.png'))}finally{$capture.Dispose()}}
            $dialog.Tag.Start.PerformClick()
            Check-Doctor ($dialog.Tag.Action -eq 'Start' -and $dialog.DialogResult -eq 'OK') 'button chooses exact start preview action'
            $script:PendingAction=$null;Invoke-NetworkDoctorAction $fixture $dialog.Tag.Action
            Check-Doctor ($script:PendingAction.Kind -eq 'DoctorStartPlan' -and $script:PendingAction.Key -eq 'fixture-clash') 'start uses bound target and plan only'
        }finally{$dialog.Dispose()}
        $fixture.State='Healthy';$fixture.Headline='当前代理入口正常';$fixture.Message='当前由 Clash 提供代理，设置一致。';$fixture.CanStartClient=$false;$fixture.CanProbe=$true
        $dialog=New-NetworkDoctorDialog $fixture
        try{Check-Doctor (-not $dialog.Tag.Start.Enabled -and -not $dialog.Tag.Apply.Enabled -and $dialog.Tag.Probe.Enabled) 'healthy proxy never offers reapply or duplicate start'}finally{$dialog.Dispose()}
        $script:PendingAction=$null;Invoke-NetworkDoctorAction $fixture 'Start';Check-Doctor ($null -eq $script:PendingAction) 'stale start action rejected by report capability'
        Invoke-NetworkDoctorAction $fixture 'Probe';Check-Doctor ($script:PendingAction.Kind -eq 'DoctorProbe') 'fixed probe requires explicit action'
        $fixture.State='SettingsMismatch';$fixture.CanApplyProxy=$true
        $script:PendingAction=$null;Invoke-NetworkDoctorAction $fixture 'Apply';Check-Doctor ($script:PendingAction.Kind -eq 'DailyPlan' -and $script:PendingAction.Key -eq 'fixture-clash') 'settings recovery reuses guarded daily preview'
        $fixture.State='PortUnknown';$fixture.CanApplyProxy=$false;$fixture.CanProbe=$false
        $dialog=New-NetworkDoctorDialog $fixture
        try{Check-Doctor (-not $dialog.Tag.Start.Enabled -and -not $dialog.Tag.Apply.Enabled -and -not $dialog.Tag.Probe.Enabled) 'unknown keeps mutation and probe disabled'}finally{$dialog.Dispose()}
        $script:PendingAction=$null;Invoke-NetworkDoctorAction $fixture 'Apply';Invoke-NetworkDoctorAction $fixture 'Probe';Check-Doctor ($null -eq $script:PendingAction) 'blocked actions cannot enqueue work'
        Invoke-NetworkDoctorAction $fixture 'Refresh';Check-Doctor ($script:PendingAction.Kind -eq 'DoctorScan') 'refresh is local read-only'
        $script:PendingAction=$null;Invoke-NetworkDoctorAction $fixture 'Programs';Check-Doctor ($tabs.SelectedTab -eq $programPage -and $null -eq $script:PendingAction) 'one-app problem navigates instead of modifying whole machine'
        Show-NetworkDoctorStartPlan ([pscustomobject]@{CanApply=$false;Message='客户端已经运行，请核对原窗口。'})
        Check-Doctor ($null -eq $script:PendingAction) 'blocked plan cannot enqueue client launch'
        Write-Output ('PASS: '+$script:DoctorChecks+' doctor UI checks; scale '+$factor+'; isolated WinForms.')
'@
$path=Join-Path $qa 'ProxyWindow.ps1';$source=[IO.File]::ReadAllText($path);$marker='$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)'
if(([regex]::Matches($source,[regex]::Escape($marker))).Count -ne 1){throw 'Preview marker must be unique'}
[IO.File]::WriteAllText($path,$source.Replace($marker,$checks+"`r`n"+$marker),(New-Object Text.UTF8Encoding($true)))
$prior=$env:FLOW_DOCTOR_UI_SCALE;$priorOutput=$env:FLOW_DOCTOR_UI_OUTPUT
try{
    $env:FLOW_DOCTOR_UI_SCALE=$Scale.ToString([Globalization.CultureInfo]::InvariantCulture);$env:FLOW_DOCTOR_UI_OUTPUT=$OutputDirectory
    if($OutputDirectory){[void][IO.Directory]::CreateDirectory($OutputDirectory)}
    $passed=$false
    & (Join-Path $qa 'ProxySwitch.ps1') -Demo -PreviewView Home -DataDirectory (Join-Path $qa 'data') -PreviewPath (Join-Path $qa 'home.png') | ForEach-Object {if($_ -match '^PASS: \d+ doctor UI checks'){$passed=$true};Write-Output $_}
    if(-not $passed){throw 'Doctor UI assertions did not complete'}
}finally{$env:FLOW_DOCTOR_UI_SCALE=$prior;$env:FLOW_DOCTOR_UI_OUTPUT=$priorOutput}

param([string]$OutputDirectory='',[ValidateSet(1,1.5)][double]$Scale=1)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::ThrowException)
$qa=Join-Path $env:TEMP ('FlowSwitch-residue-ui-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($qa)
# Copy the same public runtime closure as the package; data is always isolated.
$build=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Build-WindowsPackage.ps1'))
$match=[regex]::Match($build,'(?s)\$runtime=@\((.*?)\r?\n\)')
if(-not $match.Success){throw 'Runtime whitelist unavailable'}
$files=@([regex]::Matches($match.Groups[1].Value,"'([^']+)'")|ForEach-Object {$_.Groups[1].Value})
foreach($name in $files){$dest=Join-Path $qa $name;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $dest}
$guards=@'

function Set-SystemSnapshot {throw 'Residue UI attempted Windows write'}
function Set-UserProxyEnv {throw 'Residue UI attempted persistent environment write'}
function Enable-IndependentGateway {throw 'Residue UI attempted engine startup'}
function Start-StaleProxyProgram {throw 'Residue UI attempted actual user-program startup'}
function Get-ProcessProxyEnvironmentObservation {throw 'Residue UI attempted real process scan'}
'@
[IO.File]::AppendAllText((Join-Path $qa 'ProxyBackend.ps1'),$guards,(New-Object Text.UTF8Encoding($true)))
$checks=@'
        $script:ResidueChecks=0
        function Check-Residue($Value,[string]$Message){if(-not $Value){throw ('Residue UI: '+$Message)};$script:ResidueChecks++}
        function Start-Work([string]$Kind,[string]$Key){$script:ResidueRequest=[pscustomobject]@{Kind=$Kind;Key=$Key}}
        $factor=[double]::Parse($env:FLOW_RESIDUE_UI_SCALE,[Globalization.CultureInfo]::InvariantCulture)
        $tabs.SelectedTab=$homePage;$staleProxyHomeButton.PerformClick()
        Check-Residue ($script:ResidueRequest.Kind -eq 'StaleProxyScan' -and $script:ResidueRequest.Key -eq '') 'home button requests explicit scan only'
        $fixture=[pscustomobject]@{CheckedAt='12:30';TargetPath='';SystemEndpoint='127.0.0.1:17897';SettingsChanged=$false;CoverageLimited=$false;StaleCount=1;Scope='仅提取代理摘要';Rows=@(
            [pscustomobject]@{Name='Fixture Editor';Path='C:\Fixture\Editor.exe';State='StaleLocal';Label='环境指向已停止入口';Detail='先保存工作并正常退出整组程序。';CanPrepareLaunch=$true;CoverageLimited=$false;Members=@([pscustomobject]@{PID=8701;Name='Editor.exe';State='StaleLocal';Label='环境指向已停止入口';ReasonCode='Verified';Entries=@([pscustomobject]@{Variable='HTTPS_PROXY';Endpoint='127.0.0.1:17777';Listening=$false;ConnectionObserved=$false})})},
            [pscustomobject]@{Name='Fixture Protected';Path='C:\Fixture\Protected.exe';State='Unsupported';Label='不在受限检查范围';Detail='保留未知。';CanPrepareLaunch=$false;CoverageLimited=$false;Members=@()}
        )}
        $dialog=New-StaleProxyDialog $fixture
        try {
            $dialog.ShowInTaskbar=$false;$dialog.Opacity=0;$dialog.Show();$dialog.CreateControl()
            if($factor -ne 1){$dialog.Scale((New-Object Drawing.SizeF($factor,$factor)));$dialog.Font=New-Object Drawing.Font($form.Font.FontFamily,($form.Font.Size*$factor))}
            $dialog.MinimumSize=New-Object Drawing.Size(620,440)
            foreach($size in @((New-Object Drawing.Size(920,650)),(New-Object Drawing.Size(680,500)))){
                $dialog.ClientSize=$size;$dialog.PerformLayout();[Windows.Forms.Application]::DoEvents()
                foreach($control in @($dialog.Tag.List,$dialog.Tag.Details,$dialog.Tag.Launch,$dialog.Tag.Refresh)){
                    $rect=$control.RectangleToScreen($control.ClientRectangle)
                    for($p=$control.Parent;$p;$p=$p.Parent){Check-Residue ($p.RectangleToScreen($p.ClientRectangle).Contains($rect)) ($control.Name+' clipped')}
                }
            }
            Check-Residue ($dialog.Tag.Details.Text -match '8701' -and $dialog.Tag.Details.Text -match '17777' -and $dialog.Tag.Details.Text -match '未确认程序实际采用') 'details separate environment and actual routing'
            Check-Residue ($dialog.Tag.Details.Text -match '正常退出' -and $dialog.Tag.Details.Text -match '不修改快捷方式') 'guidance explains preservation and next action'
            $dialog.Tag.List.SelectedIndex=1
            Check-Residue (-not $dialog.Tag.Launch.Enabled) 'unsupported item cannot prepare launch'
            $dialog.Tag.List.SelectedIndex=0;$dialog.ClientSize=New-Object Drawing.Size(920,650);$dialog.PerformLayout();[Windows.Forms.Application]::DoEvents()
            if($env:FLOW_RESIDUE_UI_OUTPUT){
                $capture=New-Object Drawing.Bitmap($dialog.Width,$dialog.Height)
                try{$dialog.DrawToBitmap($capture,(New-Object Drawing.Rectangle(0,0,$dialog.Width,$dialog.Height)));$capture.Save((Join-Path $env:FLOW_RESIDUE_UI_OUTPUT 'residue-dialog.png'))}finally{$capture.Dispose()}
            }
            $dialog.Tag.Launch.PerformClick()
            Check-Residue ($dialog.DialogResult -eq 'OK' -and $dialog.Tag.SelectedPath -eq 'C:\Fixture\Editor.exe') 'launch button returns exact selected identity for preview'
        }finally{$dialog.Dispose()}
        $fixture.SettingsChanged=$true;$dialog=New-StaleProxyDialog $fixture
        try{Check-Residue (-not $dialog.Tag.Launch.Enabled) 'changed report blocks launch'}finally{$dialog.Dispose()}
        $fixture.SettingsChanged=$false;$fixture.Rows[0].CanPrepareLaunch=$false
        $fixture.Rows[0]|Add-Member NoteProperty HasSavedRoute $true
        $dialog=New-StaleProxyDialog $fixture
        try{
            $dialog.ShowInTaskbar=$false;$dialog.Opacity=0;$dialog.Show();[Windows.Forms.Application]::DoEvents()
            Check-Residue ($dialog.Tag.Launch.Enabled -and $dialog.Tag.Launch.Text -eq '查看已有程序线路') 'saved route offers actionable existing route path'
            Check-Residue ($dialog.Tag.Details.Text -match '不会覆盖已有专线') 'saved route explains preservation'
            $dialog.Tag.Launch.PerformClick()
            Check-Residue ($dialog.Tag.ShowSavedRoute -and $dialog.Tag.SelectedPath -eq 'C:\Fixture\Editor.exe') 'route guidance never requests current-proxy repair'
        }finally{$dialog.Dispose()}
        $script:PendingAction=$null
        Show-StaleProxyLaunchPlan ([pscustomobject]@{CanLaunch=$false;Reason='程序仍在运行，请保存工作并完整退出。'})
        Check-Residue ($null -eq $script:PendingAction) 'running program cannot enqueue apply'
        Write-Output ('PASS: '+$script:ResidueChecks+' residue UI checks; scale '+$factor+'; isolated WinForms.')
'@
$path=Join-Path $qa 'ProxyWindow.ps1';$source=[IO.File]::ReadAllText($path);$marker='$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)'
if(([regex]::Matches($source,[regex]::Escape($marker))).Count -ne 1){throw 'Preview marker must be unique'}
[IO.File]::WriteAllText($path,$source.Replace($marker,$checks+"`r`n"+$marker),(New-Object Text.UTF8Encoding($true)))
$prior=$env:FLOW_RESIDUE_UI_SCALE;$priorOutput=$env:FLOW_RESIDUE_UI_OUTPUT
try{
    $env:FLOW_RESIDUE_UI_SCALE=$Scale.ToString([Globalization.CultureInfo]::InvariantCulture);$env:FLOW_RESIDUE_UI_OUTPUT=$OutputDirectory
    if($OutputDirectory){[void][IO.Directory]::CreateDirectory($OutputDirectory)}
    $passed=$false
    & (Join-Path $qa 'ProxySwitch.ps1') -Demo -PreviewView Home -DataDirectory (Join-Path $qa 'data') -PreviewPath (Join-Path $qa 'home.png') | ForEach-Object {if($_ -match '^PASS: \d+ residue UI checks'){$passed=$true};Write-Output $_}
    if(-not $passed){throw 'Residue UI assertions did not complete'}
}finally{$env:FLOW_RESIDUE_UI_SCALE=$prior;$env:FLOW_RESIDUE_UI_OUTPUT=$priorOutput}

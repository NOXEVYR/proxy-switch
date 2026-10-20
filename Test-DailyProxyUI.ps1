param([string]$OutputDirectory='',[ValidateSet(1,1.5)][double]$Scale=1)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::ThrowException)
$qa=Join-Path $env:TEMP ('FlowSwitch-daily-ui-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qa)
# Same runtime closure as the ordinary usability fixture. Data and network writes are isolated.
foreach($name in @('ProxySwitch.ps1','ProxyWindow.ps1','UiGuidance.ps1','Updates.ps1','ProxyBackend.ps1','DailyProxy.ps1','ProgramRouteAccess.ps1','QtProgramAccess.ps1','ProgramFamilyRouting.ps1','ProgramCleanStart.ps1','CleanStartWorker.ps1','Preferences.ps1','Storage.ps1','RuntimeSupport.ps1','IndependentGateway.ps1','NetworkDiagnostics.ps1','ExternalMihomoObservation.ps1','GatewayWatchdog.ps1','IndependentRouter.cjs','RoutePolicy.cjs','GatewayPortOwnership.ps1','DesktopBranding.cs','ShellShortcut.cs','FlowTheme.cs','ProgramLaunch.ps1','ProcessInventory.ps1','ProgramIdentity.ps1','ManagedRouting.ps1','ProgramFamilyTracking.ps1','ApplicationObservation.ps1','RuleMaintenance.ps1','ProxyDiscovery.ps1','AppRouting.ps1','AppRouter.cjs','config.defaults.json')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $qa}
[void][IO.Directory]::CreateDirectory((Join-Path $qa 'assets'))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'assets/FlowSwitch.ico') -Destination (Join-Path $qa 'assets/FlowSwitch.ico')
$guards=@'

function Set-SystemSnapshot {throw 'Daily UI attempted real Windows write'}
function Set-UserProxyEnv {throw 'Daily UI attempted real environment write'}
function Enable-IndependentGateway {throw 'Daily UI attempted engine startup'}
function Start-ManagedProgram {throw 'Daily UI attempted program launch'}
function Get-DailyProxyContext {throw 'Daily UI attempted synchronous network context collection'}
'@
[IO.File]::AppendAllText((Join-Path $qa 'ProxyBackend.ps1'),$guards,(New-Object Text.UTF8Encoding($true)))
$checks=@'
        $script:DailyChecks=0
        function Check-DailyUI($Value,[string]$Message){if(-not $Value){throw ('Daily UI: '+$Message)};$script:DailyChecks++}
        function Start-Work([string]$Kind,[string]$Key){$script:DailyRequest=[pscustomobject]@{Kind=$Kind;Key=$Key}}
        function Save-DailyUI([string]$Name){
            $capture=New-Object Drawing.Bitmap($form.Width,$form.Height)
            try{$form.DrawToBitmap($capture,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$capture.Save((Join-Path $PSScriptRoot ($Name+'.png')))}finally{$capture.Dispose()}
        }
        function Check-DailyVisible($Control){
            $homePage.ScrollControlIntoView($Control);$homePage.PerformLayout();[Windows.Forms.Application]::DoEvents()
            $rect=$Control.RectangleToScreen($Control.ClientRectangle)
            for($p=$Control.Parent;$p;$p=$p.Parent){Check-DailyUI ($p.RectangleToScreen($p.ClientRectangle).Contains($rect)) ($Control.Name+' clipped by '+$p.GetType().Name)}
        }
        $factor=[double]::Parse($env:FLOW_DAILY_UI_SCALE,[Globalization.CultureInfo]::InvariantCulture)
        if($factor -ne 1){$form.Scale((New-Object Drawing.SizeF($factor,$factor)))}
        $form.MinimumSize=New-Object Drawing.Size(800,600);$form.ClientSize=New-Object Drawing.Size(1180,790)
        $script:Profiles=[pscustomobject]@{Version=3;Routing=[pscustomobject]@{Adapter='none';ProfileId='';UnifiedMode='system'};DiscoveryIgnored=@();Profiles=@(
            [pscustomobject]@{Id='dailyClash';Name='Clash';Protocol='http';Host='127.0.0.1';Port=17897;CorePath='';AppPath='';AutoPort=$false},
            [pscustomobject]@{Id='dailyAlternate';Name='VPN';Protocol='http';Host='127.0.0.1';Port=17777;CorePath='';AppPath='';AutoPort=$false})}
        $script:ChoiceDirty=$false;Reload-ProfileViews
        $state=[pscustomobject]@{Key='dailyClash';Current='Clash';NetworkKey='dailyClash';NetworkName='Clash';Server='127.0.0.1:17897';Aligned=$true;EnvConflict=$false;EndpointReady=$true;Drift=$false;Environment=@();Listeners=@([pscustomobject]@{Key='dailyClash';Ready=$true},[pscustomobject]@{Key='dailyAlternate';Ready=$false});OldConnections=@();Warnings=@();CheckedAt='12:30:00';TcpAvailable=$true}
        Show-State $state;Show-Applications ([pscustomobject]@{Rows=@();RuleCount=0;Available=$false});$tabs.SelectedTab=$homePage
        $form.PerformLayout();[Windows.Forms.Application]::DoEvents()
        Check-DailyUI ($statusLabel.Text -eq '当前系统代理由 Clash 管理') 'current manager uses observed current entry'
        Check-DailyUI ($unify.Text -eq '预览切换…' -and $switchTitle.Text -match '日常线路') 'daily action has explicit preview'
        Check-DailyUI ($engineLabel.Text -match '日常模式' -and $engineLabel.Text -notmatch '会建立入口|请.*启用') 'client mode does not prompt gateway startup'
        Check-DailyUI (-not $undo.Enabled) 'no daily receipt disables arbitrary historic restore'
        Check-DailyUI ($switchScope.Text -match '保留程序专线') 'daily scope retains per-program routes'
        foreach($control in @($networkChoice,$unify,$undo,$switchScope)){Check-DailyVisible $control}
        $homePage.AutoScrollPosition=New-Object Drawing.Point(0,0);Save-DailyUI 'daily-clash-home'
        $state.EndpointReady=$false;Show-State $state;Check-DailyUI ($noticeLabel.Text -match '开始断网排查') 'stopped entry has direct recovery guidance'
        $state.EndpointReady=$true;$state.Key='Direct';$state.EnvConflict=$true;Show-State $state;Check-DailyUI ($statusLabel.Text -match '程序仍有代理设置') 'system-off plus environment conflict is visible at home'
        $state.Key='dailyClash';$state.EnvConflict=$false;Show-State $state
        $networkChoice.SelectedIndex=@($networkChoice.Items|ForEach-Object Id).IndexOf('dailyAlternate');$script:ChoiceDirty=$true;Update-DailyProxyControls
        Check-DailyUI ($switchScope.Text -match 'VPN.*尚未提供可用入口' -and $switchScope.Text -match '当前网络保持不变') 'offline alternate proxy explains prerequisites'
        Check-DailyUI ($statusLabel.Text -eq '当前系统代理由 Clash 管理') 'pending target never becomes current manager'
        Check-DailyVisible $unify;$unify.PerformClick()
        Check-DailyUI ($script:DailyRequest.Kind -eq 'DailyPlan' -and $script:DailyRequest.Key -eq 'dailyAlternate') 'button requests read-only plan, never legacy switch'
        $script:PendingAction=$null;Show-DailyProxyPlan ([pscustomobject]@{CanApply=$false;NoChange=$false;Message='目标未连接'})
        Check-DailyUI ($null -eq $script:PendingAction) 'blocked plan cannot apply'
        Show-DailyProxyPlan ([pscustomobject]@{CanApply=$true;NoChange=$true;Message='当前已使用该入口'})
        Check-DailyUI ($null -eq $script:PendingAction) 'same-route no-op cannot reapply'
        $receipt=[pscustomobject]@{Version=1;Phase='Applied'};Write-LocalJson (Get-DailyProxyReceiptPath) $receipt
        Update-DailyProxyControls;Check-DailyUI $undo.Enabled 'receipt enables preview only'
        Check-DailyVisible $undo;$undo.PerformClick();Check-DailyUI ($script:DailyRequest.Kind -eq 'DailyUndoPlan') 'undo button previews daily receipt'
        $homePage.AutoScrollPosition=New-Object Drawing.Point(0,0);Save-DailyUI 'daily-alternate-pending'
        $state.EndpointReady=$null;Show-State $state
        Check-DailyUI ($statusLabel.Text -match '待确认' -and $noticeLabel.Text -match '开始断网排查') 'unknown entry is not declared disconnected'
        $state.EndpointReady=$false;Show-State $state
        Check-DailyUI ($statusLabel.Text -match '未连接' -and $noticeLabel.Text -notmatch '重新应用|独立入口') 'dead current entry gives actionable client guidance'
        $state.Key='Direct';$state.NetworkKey='Direct';$state.NetworkName='直连';$state.EndpointReady=$true
        $state|Add-Member NoteProperty ApplicationProxyViews ([pscustomobject]@{Different=$true;Message='Fixture three-view disagreement'})
        $script:ChoiceDirty=$false;Show-State $state
        Check-DailyUI ($statusLabel.Text -eq 'Windows 代理视图不一致' -and $entryValue.Text -eq '视图不一致') 'view disagreement is not declared confirmed Direct'
        Check-DailyUI ($networkChoice.SelectedIndex -eq -1 -and $noticeLabel.Text -match '预览核对') 'ambiguous current state does not preselect Direct'
        Write-Output ('PASS: '+$script:DailyChecks+' daily UI checks; scale '+$factor+'; isolated hidden WinForms, no network changes.')
'@
$path=Join-Path $qa 'ProxyWindow.ps1';$source=[IO.File]::ReadAllText($path)
$marker='$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)'
if(([regex]::Matches($source,[regex]::Escape($marker))).Count -ne 1){throw 'Preview marker must be unique'}
$source=$source.Replace($marker,$checks+"`r`n"+$marker)
[IO.File]::WriteAllText($path,$source,(New-Object Text.UTF8Encoding($true)))
$prior=$env:FLOW_DAILY_UI_SCALE
try{
    $env:FLOW_DAILY_UI_SCALE=$Scale.ToString([Globalization.CultureInfo]::InvariantCulture)
    $passed=$false
    & (Join-Path $qa 'ProxySwitch.ps1') -Demo -PreviewView Home -DataDirectory (Join-Path $qa 'data') -PreviewPath (Join-Path $qa 'daily.png') | ForEach-Object {if($_ -match '^PASS: \d+ daily UI checks'){$passed=$true};Write-Output $_}
    if(-not $passed){throw 'Daily UI assertions did not complete'}
    if($OutputDirectory){[void][IO.Directory]::CreateDirectory($OutputDirectory);foreach($name in @('daily-clash-home.png','daily-alternate-pending.png')){Copy-Item -LiteralPath (Join-Path $qa $name) -Destination (Join-Path $OutputDirectory $name)}}
}finally{$env:FLOW_DAILY_UI_SCALE=$prior}

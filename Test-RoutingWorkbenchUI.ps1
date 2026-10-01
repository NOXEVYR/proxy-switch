param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class FlowWebsiteVisual{[DllImport("user32.dll")]public static extern int GetWindowLong(IntPtr window,int index);}'
$qa=Join-Path $env:TEMP ('FlowSwitch-routing-workbench-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qa)
foreach($name in @('ProxySwitch.ps1','ProxyWindow.ps1','Updates.ps1','ProxyBackend.ps1','ProgramRouteAccess.ps1','ProgramFamilyRouting.ps1','ProgramCleanStart.ps1','CleanStartWorker.ps1','Preferences.ps1','Storage.ps1','RuntimeSupport.ps1','IndependentGateway.ps1','NetworkDiagnostics.ps1','GatewayWatchdog.ps1','IndependentRouter.cjs','RoutePolicy.cjs','GatewayPortOwnership.ps1','DesktopBranding.cs','ShellShortcut.cs','FlowTheme.cs','ProgramLaunch.ps1','ProcessInventory.ps1','ProgramIdentity.ps1','ApplicationObservation.ps1','RuleMaintenance.ps1','ProxyDiscovery.ps1','AppRouting.ps1','AppRouter.cjs','config.defaults.json')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $qa}
[void][IO.Directory]::CreateDirectory((Join-Path $qa 'assets'))
foreach($name in @('ManagedRouting.ps1','ProgramFamilyTracking.ps1','RoutePolicy.ps1')){if(Test-Path -LiteralPath (Join-Path $PSScriptRoot $name)){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $qa}}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'assets/FlowSwitch.ico') -Destination (Join-Path $qa 'assets/FlowSwitch.ico')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'UiGuidance.ps1') -Destination $qa
$checks=@'
        $script:Checks=0
        function Check-UI($Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
        function Start-Work([string]$Kind,[string]$Key){$script:Requested=[pscustomobject]@{Kind=$Kind;Key=$Key}}
        function Reveal-Control($Control){
            $pages=@();for($ancestor=$Control.Parent;$ancestor;$ancestor=$ancestor.Parent){if($ancestor -is [Windows.Forms.TabPage]){$pages+=$ancestor}}
            [array]::Reverse($pages);foreach($page in $pages){$page.Parent.SelectedTab=$page}
            $form.PerformLayout();[Windows.Forms.Application]::DoEvents()
            Check-UI ($Control.Visible) ('Actual action is reachable: '+$Control.Text)
        }
        $tabs.SelectedTab=$toolsPage;[Windows.Forms.Application]::DoEvents()
        Reveal-Control $networkDiagnoseButton
        $networkDiagnoseButton.PerformClick()
        Check-UI ($script:Requested.Kind -eq 'NetworkDiagnose') 'Network diagnosis button dispatches the read-only diagnostic worker'
        $script:Requested=$null;$script:NetworkDiagnosis=$null;$networkRepairButton.PerformClick()
        Check-UI ($null -eq $script:Requested) 'Repair without a diagnosis cannot change settings'
        $script:CleanSession=[pscustomobject]@{Status=[pscustomobject]@{Phase='active';Message='Isolated comparison fixture'}};Set-UiActionAvailability
        $priorSize=$form.Size;$form.Size=$form.MinimumSize;[Windows.Forms.Application]::DoEvents()
        foreach($control in @($networkDiagnoseButton,$networkRepairButton,$cleanStopButton,$updateButton,$automaticUpdates)){
            Reveal-Control $control
            Check-UI ($control.Left -ge 0 -and $control.Top -ge 0 -and $control.Right -le $control.Parent.ClientSize.Width -and $control.Bottom -le $control.Parent.ClientSize.Height) ('Grouped tools action fits at minimum width and height: '+$control.Text)
        }
        Reveal-Control $cleanStopButton
        $script:Requested=$null;$cleanStopButton.PerformClick()
        Check-UI ($script:Requested.Kind -eq 'CleanStartStop' -and $script:Requested.Key -eq '') 'Comparison stop action dispatches the current session stop operation'
        $form.Size=$priorSize;$tabs.SelectedTab=$programPage
        $script:AppTarget=[pscustomobject]@{Name='Fixture Editor';Path='C:\Fixtures\editor.exe';SavedPath='C:\Fixtures\editor.exe';Mode='managed';Policy='backup';RequiresRepair=$false;HasSavedRule=$true;CanLaunch=$true}
        foreach($mode in @('launch','engine','observe','managed')){
            $script:AppTarget.Mode=$mode;Request-ApplicationRoute 'Direct';$payload=$script:Requested.Key|ConvertFrom-Json
            $expectedKind=if($mode -eq 'engine'){'ProgramAccessPlan'}else{'ManagedAppRoute'}
            Check-UI ($script:Requested.Kind -eq $expectedKind -and $payload.route -eq 'Direct' -and $payload.path -eq $script:AppTarget.Path) ('Route operation uses verified access preview for engine and native adapter for '+$mode)
        }
        Request-ApplicationRoute 'Follow';$payload=$script:Requested.Key|ConvertFrom-Json
        Check-UI ($script:Requested.Kind -eq 'ManagedAppRoute' -and $payload.route -eq 'Follow') 'Follow keeps application entry rather than removing it'
        Reveal-Control $websiteButton
        $websiteButton.PerformClick()
        Check-UI ($script:Requested.Kind -eq 'WebsiteRules' -and $script:Requested.Key -eq '') 'Main website action opens global rules'
        $tabs.SelectedTab=$programPage;[Windows.Forms.Application]::DoEvents()
        $script:AppTarget.Mode='managed';$script:LastApps=Get-DemoApps
        $script:Requested=$null;$familyRuleItem.PerformClick();$payload=$script:Requested.Key|ConvertFrom-Json
        Check-UI ($script:Requested.Kind -eq 'FamilyRoutePlan' -and $payload.Path -ceq $script:AppTarget.Path -and $payload.Route -eq 'backup') 'Family rules action previews the selected executable and explicit route'
        $script:Requested=$null;$cleanStartItem.PerformClick();$payload=$script:Requested.Key|ConvertFrom-Json
        Check-UI ($script:Requested.Kind -eq 'CleanStartPlan' -and $payload.Path -ceq $script:AppTarget.Path -and $payload.DirectTest -eq $false) 'Clean environment action requests a preview without disabling the system proxy'
        $script:Requested=$null;$directTestItem.PerformClick();$payload=$script:Requested.Key|ConvertFrom-Json
        Check-UI ($script:Requested.Kind -eq 'CleanStartPlan' -and $payload.Path -ceq $script:AppTarget.Path -and $payload.DirectTest -eq $true) 'Direct login comparison is a separate explicit preview'
        $script:AppTarget.Policy='Follow';$script:Requested=$null;$familyRuleItem.PerformClick()
        Check-UI ($null -eq $script:Requested) 'Family rules cannot guess a route from Follow'
        $script:AppTarget.Policy='backup';$script:AppTarget.RequiresRepair=$true
        $appMenu.Show($liveList,(New-Object Drawing.Point(1,1)));[Windows.Forms.Application]::DoEvents()
        Check-UI (-not $familyRuleItem.Enabled -and -not $cleanStartItem.Enabled -and -not $directTestItem.Enabled) 'Unresolved executable identity disables all three new actions'
        $appMenu.Close()
        foreach($item in @($familyRuleItem,$cleanStartItem,$directTestItem)){
            $script:Requested=$null;$item.Enabled=$true;$item.PerformClick()
            Check-UI ($null -eq $script:Requested) 'Click handlers also reject stale identity before dispatching previews'
        }
        $script:AppTarget.RequiresRepair=$false
        foreach($confirm in @($false,$true)){
            $script:PendingAction=$null;$script:ModalError='';$script:ModalChecked=$false;$script:ModalConfirm=$confirm
            $plan=[pscustomobject]@{Path='C:\Fixtures\launcher.exe';DirectTest=$confirm;Elevate=$false;Message='隔离验证：请先完整退出程序。直连对照最多五分钟，并恢复原系统入口。';Version=1}
            $modalTimer=New-Object Windows.Forms.Timer;$modalTimer.Interval=50
            $modalTimer.Add_Tick({
                $candidate=@([Windows.Forms.Application]::OpenForms|Where-Object {$_.Text -in @('干净环境启动','直连登录对照')})|Select-Object -First 1
                if(-not $candidate){return}
                $modalTimer.Stop()
                try{
                    if($candidate.FormBorderStyle -ne 'FixedDialog'){throw 'Fixed-position clean-start dialog can be shrunk until actions are clipped.'}
                    if(@($candidate.Controls|Where-Object {$_.Right -gt $candidate.ClientSize.Width -or $_.Bottom -gt $candidate.ClientSize.Height}).Count){throw 'Clean-start confirmation controls are clipped.'}
                    $notice=@($candidate.Controls|Where-Object {$_ -is [Windows.Forms.TextBox]})[0]
                    if($notice.Text -notmatch '完整退出' -or $notice.Text -notmatch 'launcher.exe'){throw 'Clean-start confirmation lost the target or restart instructions.'}
                    $modalBitmap=New-Object Drawing.Bitmap($candidate.Width,$candidate.Height)
                    try{$candidate.DrawToBitmap($modalBitmap,(New-Object Drawing.Rectangle(0,0,$candidate.Width,$candidate.Height)));$modalBitmap.Save((Join-Path ([IO.Path]::GetDirectoryName($PreviewPath)) ('clean-start-'+$script:ModalConfirm+'.png')))}finally{$modalBitmap.Dispose()}
                    $script:ModalChecked=$true
                    if($script:ModalConfirm){@($candidate.Controls|Where-Object {$_ -is [Windows.Forms.CheckBox]})[0].Checked=$true;$candidate.AcceptButton.PerformClick()}else{$candidate.CancelButton.PerformClick()}
                }catch{$script:ModalError=$_.Exception.Message;$candidate.Close()}
            })
            try{$modalTimer.Start();Show-CleanStartDialog $plan}finally{$modalTimer.Stop();$modalTimer.Dispose()}
            Check-UI ($script:ModalChecked -and -not $script:ModalError -and -not $script:DialogOpen) ('Actual clean-start dialog controls and closing state: '+$script:ModalError)
            if($confirm){$payload=$script:PendingAction.Key|ConvertFrom-Json;Check-UI ($script:PendingAction.Kind -eq 'CleanStart' -and $payload.DirectTest -eq $true -and $payload.Elevate -eq $true -and $payload.Path -ceq $plan.Path) 'Only confirmation queues the exact preview and explicit elevation choice'}
            else{Check-UI ($null -eq $script:PendingAction) 'Canceling the actual clean-start dialog queues no process or network operation'}
        }
        $script:PendingAction=$null
        $appMenu.Show($liveList,(New-Object Drawing.Point(1,1)));[Windows.Forms.Application]::DoEvents();$websiteProgramItem.PerformClick();$appMenu.Close()
        Check-UI ($script:Requested.Kind -eq 'WebsiteRules' -and $script:Requested.Key -eq $script:AppTarget.Path) 'Program menu passes precise executable scope'

        function Get-ProgramDesktopState {param($Executable);[pscustomobject]@{Mode='InApp';Revision='fixture-desktop-revision';External=0}}
        foreach($mode in @('InApp','Separate','Bound','Cancel')){
            $script:DesktopMode=$mode;$script:DesktopDialogSeen=$false;$script:DesktopDialogError='';$script:PendingAction=$null
            $timerDesktop=New-Object Windows.Forms.Timer;$timerDesktop.Interval=50
            $timerDesktop.Add_Tick({
                $candidate=@([Windows.Forms.Application]::OpenForms|Where-Object {$_.Text -eq '启动方式与桌面绑定'})|Select-Object -First 1
                if(-not $candidate){return};$timerDesktop.Stop()
                try{
                    if($candidate.FormBorderStyle -ne 'FixedDialog' -or @($candidate.Controls|Where-Object {$_.Right -gt $candidate.ClientSize.Width -or $_.Bottom -gt $candidate.ClientSize.Height}).Count){throw 'Desktop preference dialog is clipped'}
                    $radios=@($candidate.Controls|Where-Object {$_ -is [Windows.Forms.RadioButton]})
                    if($radios.Count -ne 3){throw 'Three explicit choices are required'}
                    $script:DesktopDialogSeen=$true
                    if($script:DesktopMode -eq 'Cancel'){$candidate.CancelButton.PerformClick()}else{
                        $radio=$radios|Where-Object Tag -eq $script:DesktopMode;$radio.Checked=$true
                        if($script:DesktopMode -eq 'Bound'){$bitmap=New-Object Drawing.Bitmap($candidate.Width,$candidate.Height);try{$candidate.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$candidate.Width,$candidate.Height)));$bitmap.Save((Join-Path ([IO.Path]::GetDirectoryName($PreviewPath)) 'desktop-launch-settings.png'))}finally{$bitmap.Dispose()}}
                        $candidate.AcceptButton.PerformClick()
                    }
                }catch{$script:DesktopDialogError=$_.Exception.Message;$candidate.Close()}
            })
            try{$timerDesktop.Start();Show-ProgramLaunchSettings $script:AppTarget}finally{$timerDesktop.Stop();$timerDesktop.Dispose()}
            Check-UI ($script:DesktopDialogSeen -and -not $script:DesktopDialogError -and -not $script:DialogOpen) ('Actual desktop preference dialog opens with usable controls: '+$script:DesktopDialogError)
            if($mode -eq 'Cancel'){Check-UI ($null -eq $script:PendingAction) 'Cancel cannot queue shortcut writes'}else{$payload=$script:PendingAction.Key|ConvertFrom-Json;Check-UI ($script:PendingAction.Kind -eq 'AppDesktopMode' -and $payload.Mode -ceq $mode -and $payload.Path -ceq $script:AppTarget.Path -and $payload.Revision -ceq 'fixture-desktop-revision') 'Explicit choice dispatches exact executable and revision'}
        }
        $script:AppTarget.RequiresRepair=$true;$script:PendingAction=$null
        Show-ProgramLaunchSettings $script:AppTarget
        Check-UI ($null -eq $script:PendingAction -and -not $script:DialogOpen) 'Stale executable cannot edit desktop integration'
        $script:AppTarget.RequiresRepair=$false
        foreach($width in @($form.MinimumSize.Width,1400)){
            $form.Width=$width;[Windows.Forms.Application]::DoEvents()
            $visibleActions=@($bottom.Controls|Where-Object {$_ -is [Windows.Forms.Button] -and $_.Visible})
            foreach($button in $visibleActions){Check-UI ($button.Left -ge 0 -and $button.Top -ge 0 -and $button.Right -le $bottom.ClientSize.Width -and $button.Bottom -le $bottom.ClientSize.Height) ('Program action remains inside its panel: '+$button.Text)}
            for($i=0;$i -lt $visibleActions.Count;$i++){for($j=$i+1;$j -lt $visibleActions.Count;$j++){Check-UI (-not $visibleActions[$i].Bounds.IntersectsWith($visibleActions[$j].Bounds)) ('Program actions do not overlap: '+$visibleActions[$i].Text+' / '+$visibleActions[$j].Text)}}
        }
        $script:PendingAction=$null

        $snapshot=[pscustomobject]@{Entries=@([pscustomobject]@{Id=('a'*32);Domain='initial.example';Match='exact';Route='Direct';Executable=''});Revision=('b'*64);Available=$true;Loaded=$true;Message='测试规则已加载';ContextExecutable='C:\Fixtures\editor.exe'}
        $editor=New-WebsiteRuleEditor $snapshot
        try{
            $editor.ShowInTaskbar=$false;$editor.Show($form);[Windows.Forms.Application]::DoEvents();$state=$editor.Tag
            $buttons=@{};foreach($control in $editor.Controls[0].Controls){foreach($child in $control.Controls){if($child.Name){$buttons[$child.Name]=$child}}}
            foreach($width in @(930,850,1100)){
                $editor.ClientSize=New-Object Drawing.Size($width,590);$editor.PerformLayout();[Windows.Forms.Application]::DoEvents()
                Check-UI ($buttons.WebsiteSave.Right -le $buttons.WebsiteSave.Parent.ClientSize.Width -and $buttons.WebsiteCancel.Right -lt $buttons.WebsiteSave.Left -and $state.Route.Right -le $state.Route.Parent.ClientSize.Width) 'Website save, cancel and route controls remain visible without overlap when resized'
                $state.List.Refresh();[Windows.Forms.Application]::DoEvents()
                Check-UI (([FlowWebsiteVisual]::GetWindowLong($state.List.Handle,-16) -band 0x100000) -eq 0) ('Website list has no native horizontal scrollbar at width '+$width+'; columns '+(($state.List.Columns|Measure-Object Width -Sum).Sum)+' client '+$state.List.ClientSize.Width)
            }
            $editor.ClientSize=New-Object Drawing.Size(930,590);$editor.PerformLayout();[Windows.Forms.Application]::DoEvents()
            $editorBitmap=New-Object Drawing.Bitmap($editor.Width,$editor.Height);try{$editor.DrawToBitmap($editorBitmap,(New-Object Drawing.Rectangle(0,0,$editor.Width,$editor.Height)));$editorBitmap.Save((Join-Path ([IO.Path]::GetDirectoryName($PreviewPath)) 'website-rules.png'))}finally{$editorBitmap.Dispose()}
            Check-UI ($state.Scope.SelectedItem.Executable -eq 'C:\Fixtures\editor.exe') 'Program editor defaults to requested full-path scope'
            Check-UI ($state.List.Items.Count -eq 1 -and $state.List.Items[0].SubItems[1].Text -eq 'initial.example') 'Existing site rules render in actual controls'
            foreach($bad in @('https://example.com/?code=secret','user:secret@example.com','example.com/path','*.example.com','127.0.0.1')){
                $state.Domain.Text=$bad;$buttons.WebsiteAdd.PerformClick()
                Check-UI ($state.Entries.Count -eq 1 -and $state.Error.Text) 'URL credentials wildcard or IP cannot enter a domain rule'
            }
            $state.Domain.Text='PROJECT.Example.';$state.Match.SelectedIndex=1;$state.Route.SelectedIndex=0;$buttons.WebsiteAdd.PerformClick()
            $added=@($state.Entries|Where-Object Domain -eq 'project.example')[0]
            Check-UI ($state.Entries.Count -eq 2 -and $added.Match -eq 'suffix' -and $added.Executable -eq 'C:\Fixtures\editor.exe') 'Domain is normalized and suffix applies to selected program'
            $id=$added.Id;$state.Domain.Text='project.example';$state.Route.SelectedIndex=$state.Route.Items.Count-1;$buttons.WebsiteAdd.PerformClick()
            Check-UI ($state.Entries.Count -eq 2 -and $added.Id -eq $id -and $added.Route -eq $state.Route.SelectedItem.Id) 'Same scope domain and match updates route without duplicating identity'
            $state.Scope.SelectedIndex=0;$state.Domain.Text='project.example';$state.Match.SelectedIndex=0;$state.Route.SelectedIndex=0;$buttons.WebsiteAdd.PerformClick()
            Check-UI ($state.Entries.Count -eq 3 -and @($state.Entries|Where-Object {$_.Domain -eq 'project.example' -and -not $_.Executable -and $_.Match -eq 'exact'}).Count -eq 1) 'Global exact rule is distinct from program suffix rule'
            Check-UI ($snapshot.Entries.Count -eq 1 -and $snapshot.Entries[0].Route -eq 'Direct') 'Editing never mutates fetched snapshot or backend state'
            $state.Domain.Text='unsaved.example';$buttons.WebsiteSave.PerformClick()
            Check-UI ($null -eq $state.Result -and $state.Error.Text -match '尚未加入') 'Save cannot silently discard an unadded domain draft'
            $state.Domain.Text='';$state.List.Items[0].Selected=$true;$state.List.Items[0].Focused=$true;[Windows.Forms.Application]::DoEvents();$buttons.WebsiteRemove.PerformClick()
            Check-UI ($state.Entries.Count -eq 2 -and $state.Domain.Text -eq '') 'Delete removes only selected staged rule and clears its edit draft'
            $buttons.WebsiteSave.PerformClick()
            Check-UI ($editor.DialogResult -eq 'OK' -and $state.Result.Revision -eq ('b'*64) -and $state.Result.Entries.Count -eq 2) 'Save returns full entries and original revision for backend concurrency validation'
            Check-UI (($state.Result|ConvertTo-Json -Depth 6) -notmatch 'code=|user:secret') 'Rejected authentication strings never enter persisted payload'
        }finally{$editor.Dispose()}
        $cancelEditor=New-WebsiteRuleEditor $snapshot
        try{$cancelEditor.ShowInTaskbar=$false;$cancelEditor.Show($form);[Windows.Forms.Application]::DoEvents();$cancelEditor.Close();Check-UI ($null -eq $cancelEditor.Tag.Result) 'Closing editor without save returns no mutation'}finally{$cancelEditor.Dispose()}
        $snapshot.Available=$false;$unknownEditor=New-WebsiteRuleEditor $snapshot
        try{Check-UI ($unknownEditor.Tag.Status.Text -match '尚未确认' -and $unknownEditor.Tag.Status.Text -notmatch '^网站规则已加载') 'Unavailable website controller cannot be presented as loaded rules'}finally{$unknownEditor.Dispose()}
        $app=[pscustomobject]@{Name='Fixture';Path='C:\Fixtures\editor.exe';Policy='backup';Mode='managed';Managed=$true;NeedsRelaunch=$true;CanLaunch=$true;Loaded=$true;Actual='未观察到 TCP 连接';Status='已保存 B；仍使用旧入口，需要完整重开';HasSavedRule=$true}
        Show-Applications ([pscustomobject]@{Rows=@($app);RuleCount=1;LaunchRuleCount=0;Available=$true;RulesAvailable=$true;TcpAvailable=$true})
        Check-UI ($liveList.Items[0].SubItems[2].Text -eq '未观察到 TCP 连接' -and $liveList.Items[0].SubItems[3].Text -match '旧入口') 'Loaded route cannot manufacture traffic evidence or hide pending restart status'
        Check-UI ($ruleMeta.Text -match '已加载线路设置' -and $ruleMeta.Text -notmatch '已观察到目标出口') 'Loaded rule count is never described as observed actual route'
        $engine=[pscustomobject]@{Name='Fixture Qt Launcher';Path='C:\Fixtures\game.exe';Policy='Direct';Mode='engine';CanLaunch=$false;RequiresRepair=$false;Running=$true;PIDs='123';NeedsEntryConnection=$true;HasSavedRule=$true;Actual='外部代理 ×1';Status='入口绕过流向 · 规则尚未接管'}
        Show-Applications ([pscustomobject]@{Rows=@($engine);RuleCount=1;LaunchRuleCount=0;Available=$true;RulesAvailable=$true;TcpAvailable=$true})
        $liveList.Items[0].Selected=$true;Set-UiActionAvailability
        Check-UI ($programLaunchButton.Text -eq '应用线路并检查' -and $programLaunchButton.Enabled) 'Running non-native launcher has an actionable reapply control rather than a disabled launch promise'
        Check-UI ($programHint.Text -match '系统入口绕过流向' -and $programHint.Text -match '保留其他专线') 'Entry bypass is explained next to the actual selected-object control'
        $script:Requested=$null;$programLaunchButton.PerformClick();$access=$script:Requested.Key|ConvertFrom-Json
        Check-UI ($script:Requested.Kind -eq 'ProgramAccessPlan' -and $access.path -ceq $engine.Path -and $access.route -eq 'Direct') 'Engine primary action previews exact selected game and Direct route without launching or switching all programs'
        $engine.RequiresRepair=$true;Show-Applications ([pscustomobject]@{Rows=@($engine);RuleCount=1;Available=$true;RulesAvailable=$true;TcpAvailable=$true});$liveList.Items[0].Selected=$true;Set-UiActionAvailability
        Check-UI (-not $programLaunchButton.Enabled) 'Changed executable identity cannot reapply an obsolete saved path'
        $preview=[pscustomobject]@{Path='C:\Fixtures\game.exe';Route='Direct';CanApply=$true;Message='确认后接回流向入口。';Impact='保留其他程序专线、网站规则和有效备用。';FamilyPlan=[pscustomobject]@{Members=@([pscustomobject]@{Name='game';Path='C:\Fixtures\game.exe';State='Conflict';Reason='原先走A'},[pscustomobject]@{Name='child-fixed';Path='C:\Fixtures\fixed.exe';State='Conflict';Reason='子程序专线B'})+@(0..149|ForEach-Object {[pscustomobject]@{Name=('helper-'+$_);State='Missing';Reason='同安装目录、已核验父子关系。'}})}}
        $accessDialog=New-ProgramRouteAccessDialog $preview
        try{
            $accessDialog.ShowInTaskbar=$false;$accessDialog.Show($form);$accessDialog.ClientSize=New-Object Drawing.Size(480,360);[Windows.Forms.Application]::DoEvents()
            Check-UI ($accessDialog.Tag.Reading.ReadOnly -and $accessDialog.Tag.Reading.ScrollBars -eq 'Vertical' -and $accessDialog.Tag.Reading.Text -match 'helper-149') 'Large verified family preview stays readable in a scrolling dialog rather than an oversized message box'
            Check-UI ($accessDialog.Tag.Reading.Height -ge ($accessDialog.ClientSize.Height-145)) 'Preview evidence expands with the dialog instead of leaving unused blank space'
            Check-UI ($accessDialog.Tag.Reading.Text -match 'game · 所选程序：将设为“直连”' -and $accessDialog.Tag.Reading.Text -notmatch 'game · 保留原选择' -and $accessDialog.Tag.Reading.Text -match 'child-fixed · 保留原选择') 'Preview explicitly changes root while preserving the conflicting child'
            Check-UI ($accessDialog.Tag.Accept.Enabled -and $accessDialog.Tag.Accept.Bottom -le $accessDialog.Tag.Accept.Parent.ClientSize.Height -and $accessDialog.Tag.Grid.Bottom -le $accessDialog.ClientSize.Height) 'Small workspace retains the explicit apply and cancel controls below the scrolling evidence'
            $accessImage=New-Object Drawing.Bitmap($accessDialog.Width,$accessDialog.Height)
            try{$accessDialog.DrawToBitmap($accessImage,(New-Object Drawing.Rectangle(0,0,$accessDialog.Width,$accessDialog.Height)));$accessImage.Save((Join-Path $script:Root 'program-access-preview.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$accessImage.Dispose()}
            $accessDialog.Tag.Cancel.PerformClick();Check-UI ($accessDialog.DialogResult -eq 'Cancel') 'Cancel preview produces no application operation'
        }finally{$accessDialog.Dispose()}
        $preview.Route='Follow';$followDialog=New-ProgramRouteAccessDialog $preview
        try{Check-UI ($followDialog.Tag.Reading.Text -match '撤回此程序专线，跟随默认' -and $followDialog.Tag.Reading.Text -match '保留此子程序现有选择' -and $followDialog.Tag.Reading.Text -notmatch '将补齐') 'Follow preview never presents Direct family classifications as requested changes'}finally{$followDialog.Dispose()}
        Write-Output ('PASS: '+$script:Checks+' routing workbench UI assertions; actual menus and website editor controls, isolated demo, no network writes or user applications.')
'@
$path=Join-Path $qa 'ProxyWindow.ps1';$source=[IO.File]::ReadAllText($path)
$source=$source.Replace('$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)',$checks+"`r`n"+'$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)')
[IO.File]::WriteAllText($path,$source,(New-Object Text.UTF8Encoding($true)))
$uiResult=@(& (Join-Path $qa 'ProxySwitch.ps1') -Demo -DataDirectory (Join-Path $qa 'data') -PreviewPath (Join-Path $qa 'routing-workbench.png'))
$uiResult|Write-Output
if(-not ($uiResult -match '^PASS: \d+ routing workbench UI assertions')){throw 'Routing workbench UI did not complete its control assertions.'}
if($OutputDirectory){[void][IO.Directory]::CreateDirectory($OutputDirectory);foreach($artifact in Get-ChildItem -LiteralPath $qa -Filter '*.png'){Copy-Item -LiteralPath $artifact.FullName -Destination (Join-Path $OutputDirectory $artifact.Name)}}

param([string]$OutputDirectory='', [ValidateSet(1,1.25,1.5)][double]$Scale=1)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::ThrowException)
$qa=Join-Path $env:TEMP ('FlowSwitch-usability-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qa)
foreach($name in @('ProxySwitch.ps1','ProxyWindow.ps1','Updates.ps1','ProxyBackend.ps1','ProgramFamilyRouting.ps1','ProgramCleanStart.ps1','CleanStartWorker.ps1','Preferences.ps1','Storage.ps1','RuntimeSupport.ps1','IndependentGateway.ps1','NetworkDiagnostics.ps1','GatewayWatchdog.ps1','IndependentRouter.cjs','RoutePolicy.cjs','GatewayPortOwnership.ps1','DesktopBranding.cs','ShellShortcut.cs','FlowTheme.cs','ProgramLaunch.ps1','ProcessInventory.ps1','ProgramIdentity.ps1','ManagedRouting.ps1','ProgramFamilyTracking.ps1','ApplicationObservation.ps1','RuleMaintenance.ps1','ProxyDiscovery.ps1','AppRouting.ps1','AppRouter.cjs','config.defaults.json')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $qa}
[void][IO.Directory]::CreateDirectory((Join-Path $qa 'assets'))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'assets/FlowSwitch.ico') -Destination (Join-Path $qa 'assets/FlowSwitch.ico')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'UiGuidance.ps1') -Destination $qa
# Guard every Windows/network/process mutation even if a future UI handler bypasses Start-Work.
$backendPath=Join-Path $qa 'ProxyBackend.ps1'
[IO.File]::AppendAllText($backendPath,@'

function Set-SystemSnapshot {throw 'UI acceptance attempted a Windows network write.'}
function Set-UserProxyEnv {throw 'UI acceptance attempted a user proxy environment write.'}
function Set-UniversalProxy {throw 'UI acceptance attempted a real unified switch.'}
function Set-ManagedApplicationRoute {throw 'UI acceptance attempted a real program route change.'}
function Start-ManagedProgram {throw 'UI acceptance attempted to start a user program.'}
function Open-Client {throw 'UI acceptance attempted to start a user proxy client.'}
'@,(New-Object Text.UTF8Encoding($true)))
$checks=@'
        $script:UsabilityChecks=0;$script:UsabilityShots=0
        function Assert-Usability($Value,[string]$Message){if(-not $Value){throw ('Usability: '+$Message)};$script:UsabilityChecks++}
        function Start-Work([string]$Kind,[string]$Key){$script:UsabilityRequest=[pscustomobject]@{Kind=$Kind;Key=$Key};$script:UsabilityRequests++}
        function Get-UiTree($Root){foreach($child in $Root.Controls){$child;Get-UiTree $child}}
        function Reveal-UiControl($Control){
            $pages=@();for($ancestor=$Control.Parent;$ancestor;$ancestor=$ancestor.Parent){if($ancestor -is [Windows.Forms.TabPage]){$pages+=$ancestor}}
            [array]::Reverse($pages);foreach($page in $pages){$page.Parent.SelectedTab=$page}
            $form.PerformLayout();[Windows.Forms.Application]::DoEvents()
            Assert-Usability ($Control.Visible) ('Grouped action can be reached: '+$Control.Text)
        }
        function Get-MenuTree($Items){foreach($item in $Items){$item;if($item -is [Windows.Forms.ToolStripMenuItem] -and $item.HasDropDownItems){Get-MenuTree $item.DropDownItems}}}
        function Reveal-MenuItem($Item){
            $owners=@();for($owner=$Item.OwnerItem;$owner;$owner=$owner.OwnerItem){$owners+=$owner};[array]::Reverse($owners)
            foreach($owner in $owners){$owner.ShowDropDown();[Windows.Forms.Application]::DoEvents()}
            Assert-Usability ($Item.Visible -and $Item.Enabled -and $Item.Owner.ClientRectangle.Contains($Item.Bounds)) ('Actual grouped menu item is visible: '+$Item.Text)
        }
        function Save-UiCapture([string]$Name,$Window=$form){
            $capture=New-Object Drawing.Bitmap($Window.Width,$Window.Height)
            try{$Window.DrawToBitmap($capture,(New-Object Drawing.Rectangle(0,0,$Window.Width,$Window.Height)));$capture.Save((Join-Path ([IO.Path]::GetDirectoryName($PreviewPath)) ($Name+'.png')));$script:UsabilityShots++}finally{$capture.Dispose()}
        }
        function Assert-ActionLayout($Root,[string]$Context){
            foreach($control in @(Get-UiTree $Root|Where-Object {$_.Visible -and ($_ -is [Windows.Forms.Button] -or $_ -is [Windows.Forms.CheckBox] -or $_ -is [Windows.Forms.ComboBox])})){
                $parent=$control.Parent
                Assert-Usability ($control.Width -gt 0 -and $control.Height -gt 0 -and $control.Left -ge 0 -and $control.Top -ge 0 -and $control.Right -le $parent.ClientSize.Width -and $control.Bottom -le $parent.ClientSize.Height) ($Context+' action clipped in parent: '+$control.Text+' '+$control.Bounds+' parent '+$parent.ClientSize)
                $screenRect=$control.RectangleToScreen($control.ClientRectangle);$ancestor=$parent
                while($ancestor){$visibleRect=$ancestor.RectangleToScreen($ancestor.ClientRectangle);Assert-Usability ($visibleRect.Contains($screenRect)) ($Context+' action clipped by '+$ancestor.GetType().Name+': '+$control.Text);$ancestor=$ancestor.Parent}
                foreach($sibling in $parent.Controls){
                    if($sibling -ne $control -and $sibling.Visible -and ($sibling -is [Windows.Forms.Button] -or $sibling -is [Windows.Forms.Label] -or $sibling -is [Windows.Forms.CheckBox] -or $sibling -is [Windows.Forms.ComboBox])){Assert-Usability (-not $control.Bounds.IntersectsWith($sibling.Bounds)) ($Context+' action overlaps '+$control.Text+' / '+$sibling.Text)}
                }
                if($control -is [Windows.Forms.Button]){
                    $textSize=[Windows.Forms.TextRenderer]::MeasureText($control.Text,$control.Font)
                    Assert-Usability ($textSize.Width -le $control.ClientSize.Width -and $textSize.Height -le $control.ClientSize.Height) ($Context+' button caption clipped: '+$control.Text+' measured '+$textSize+' client '+$control.ClientSize)
                }
            }
        }
        function Assert-Instruction($Label,[string]$Context){
            Assert-Usability ($null -ne $Label -and $Label.Visible -and -not [string]::IsNullOrWhiteSpace($Label.Text)) ($Context+' instruction is visible')
            $textSize=[Windows.Forms.TextRenderer]::MeasureText($Label.Text,$Label.Font,(New-Object Drawing.Size($Label.ClientSize.Width,10000)),[Windows.Forms.TextFormatFlags]::WordBreak)
            Assert-Usability ($textSize.Height -le $Label.ClientSize.Height) ($Context+' instruction clipped: '+$Label.Text+' requires '+$textSize.Height+'px; available '+$Label.ClientSize.Height+'px')
            $background=$Label;while($background.BackColor.A -lt 255 -and $background.Parent){$background=$background.Parent}
            Assert-Usability ($background.BackColor.GetBrightness() -lt 0.5 -and $Label.ForeColor.GetBrightness() -gt 0.5) ($Context+' instruction preserves readable dark-theme contrast: '+$Label.Text)
        }
        function Invoke-InformationAcceptance([scriptblock]$Open,[string]$CaptureName){
            $script:InfoSeen=$false;$script:InfoError='';$script:InfoText=''
            $infoTimer=New-Object Windows.Forms.Timer;$infoTimer.Interval=50
            $infoTimer.Add_Tick({
                $dialog=@([Windows.Forms.Application]::OpenForms|Where-Object {$_ -ne $form})|Select-Object -First 1
                if(-not $dialog){return};$infoTimer.Stop()
                try{
                    $script:InfoSeen=$true
                    $all=@(Get-UiTree $dialog)
                    $script:InfoText=(@($all|ForEach-Object Text) -join "`r`n")
                    Assert-Usability ($all.Count -ge 3 -and @($all|Where-Object {$_ -is [Windows.Forms.TabControl] -or $_ -is [Windows.Forms.TextBoxBase]}).Count -gt 0) 'Information window uses structured browsable controls'
                    Save-UiCapture $CaptureName $dialog
                    Assert-ActionLayout $dialog 'guide'
                    foreach($hostControl in @($all|Where-Object {$_ -is [Windows.Forms.TabControl]})){
                        foreach($page in $hostControl.TabPages){$hostControl.SelectedTab=$page;[Windows.Forms.Application]::DoEvents();Assert-ActionLayout $dialog ('guide/'+$page.Text);Save-UiCapture ($CaptureName+'-page'+$hostControl.SelectedIndex) $dialog}
                    }
                    foreach($topicList in @($all|Where-Object {$_ -is [Windows.Forms.ListBox]})){
                        Assert-Usability ($topicList.Items.Count -ge 6) 'Guide exposes separate basic and advanced topics'
                        for($topic=0;$topic -lt $topicList.Items.Count;$topic++){
                            $topicList.SelectedIndex=$topic;[Windows.Forms.Application]::DoEvents()
                            $script:InfoText+="`r`n"+(@(Get-UiTree $dialog|ForEach-Object Text) -join "`r`n")
                            Assert-ActionLayout $dialog ('guide/topic'+$topic)
                            $reader=@(Get-UiTree $dialog|Where-Object {$_ -is [Windows.Forms.TextBoxBase]})|Select-Object -First 1
                            Assert-Usability ($reader.ReadOnly -and $reader.Text.Length -gt 40 -and $reader.ScrollBars -ne 'None') ('Guide topic has a readable scrollable explanation: '+$topic)
                            Save-UiCapture ($CaptureName+'-topic'+$topic) $dialog
                        }
                    }
                }catch{$script:InfoError=$_.Exception.Message}finally{$dialog.Close()}
            })
            try{$infoTimer.Start();& $Open}finally{$infoTimer.Stop();$infoTimer.Dispose()}
            Assert-Usability ($script:InfoSeen -and -not $script:InfoError) ('Guide actual dialog opens and fits: '+$script:InfoError)
        }
        $factor=[single]::Parse($env:FLOW_USABILITY_SCALE,[Globalization.CultureInfo]::InvariantCulture)
        $originalDefault=$form.Size;$originalMinimum=$form.MinimumSize
        if($factor -ne 1){$form.Scale((New-Object Drawing.SizeF($factor,$factor)));$form.MinimumSize=New-Object Drawing.Size([int]($originalMinimum.Width*$factor),[int]($originalMinimum.Height*$factor))}
        $dimensions=@(
            [pscustomobject]@{Name='minimum';Width=$form.MinimumSize.Width;Height=$form.MinimumSize.Height},
            [pscustomobject]@{Name='default';Width=[int]($originalDefault.Width*$factor);Height=[int]($originalDefault.Height*$factor)},
            [pscustomobject]@{Name='wide';Width=[int](1600*$factor);Height=[int](980*$factor)}
        )
        Assert-Usability ($tabs.TabPages.Count -eq 4 -and $navigation.Count -eq 4) 'Four pages and four navigation actions are present'
        Assert-Usability ($tabs.TabPages[0] -eq $programPage -and $tabs.TabPages[1] -eq $proxyPage -and $tabs.TabPages[2] -eq $toolsPage -and $tabs.TabPages[3] -eq $homePage) 'Existing tab indices remain compatible and home is appended'
        Assert-Usability ($layout.RowCount -eq 5) 'Shell has header, status, workspace, action and footer rows'
        Assert-Usability ($switchRow.Parent -eq $homeGrid -and $cards.Parent -eq $homeGrid) 'Global controls and summary cards belong to home'
        $pages=@('programs','proxies','tools','home')
        foreach($dimension in $dimensions){
            $form.Size=New-Object Drawing.Size($dimension.Width,$dimension.Height);$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
            Write-Output ('WINDOW scale='+$factor+' case='+$dimension.Name+' actual='+$form.Size+' client='+$form.ClientSize)
            foreach($index in @(3,0,1,2)){
                $navigation[$index].PerformClick();$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
                Assert-Usability ($tabs.SelectedIndex -eq $index -and $brand.Text -eq $tabs.SelectedTab.Text -and @($navigation|Where-Object Selected).Count -eq 1) ('Navigation selects '+$pages[$index])
                Save-UiCapture ($pages[$index]+'-'+$dimension.Name+'-'+$factor)
                Assert-ActionLayout $form ($dimension.Name+'/'+$pages[$index]+'/'+$factor)
                if($index -eq 3){Assert-Usability ($networkChoice.Visible -and $unify.Visible -and $undo.Visible -and $cards.Visible) 'Home exposes global route choice, explicit switch and rollback'}
                else{Assert-Usability (-not $switchRow.Visible -and -not $cards.Visible) 'Other pages reserve space for their own task'}
                if($index -eq 3){foreach($label in @(Get-UiTree $homeTasks|Where-Object {$_ -is [Windows.Forms.Label] -and $_.Visible})){Assert-Instruction $label ($dimension.Name+'/home task')};Assert-Instruction $switchScope ($dimension.Name+'/unified scope')}
                if($index -eq 0){Assert-Instruction $programHint ($dimension.Name+'/program instructions');Assert-Instruction $programSelectionLabel ($dimension.Name+'/program selection')}
                if($index -eq 2){
                    foreach($groupHost in @(Get-UiTree $toolsPage|Where-Object {$_ -is [Windows.Forms.TabControl]})){
                        foreach($groupPage in $groupHost.TabPages){$groupHost.SelectedTab=$groupPage;[Windows.Forms.Application]::DoEvents();Save-UiCapture ('tools-group'+$groupHost.SelectedIndex+'-'+$dimension.Name+'-'+$factor);Assert-ActionLayout $form ($dimension.Name+'/tools/'+$groupPage.Text+'/'+$factor);foreach($label in @(Get-UiTree $groupPage|Where-Object {$_ -is [Windows.Forms.Label] -and $_.Visible})){Assert-Instruction $label ($dimension.Name+'/tools instruction')}}
                    }
                }
            }
        }
        $form.Size=New-Object Drawing.Size($dimensions[1].Width,$dimensions[1].Height)
        $navigation[3].PerformClick();[Windows.Forms.Application]::DoEvents()
        $homeText=(@(Get-UiTree $homePage|Where-Object {$_.Visible -and $_ -is [Windows.Forms.Label]}|ForEach-Object Text) -join "`r`n")
        Assert-Usability ($homeText -match 'Windows|系统代理' -and $homeText -match '环境变量|命令行' -and $homeText -match '程序.*(专用|线路)' -and $homeText -match '(网站.*(保留|例外)|保留.*网站)') 'Home explains unified scope and retained website exceptions'
        $script:UsabilityRequest=$null;$unify.PerformClick()
        Assert-Usability ($script:UsabilityRequest.Kind -eq 'Switch' -and $script:UsabilityRequest.Key -ceq $networkChoice.SelectedItem.Id) 'Home explicit switch dispatches the visible selected route'
        $script:UsabilityRequest=$null;$undo.PerformClick()
        Assert-Usability ($script:UsabilityRequest.Kind -eq 'Restore') 'Home rollback remains reachable'
        $navigation[0].PerformClick();[Windows.Forms.Application]::DoEvents()
        $launchAction=$programLaunchButton
        Assert-Usability ($null -ne $launchAction -and $launchAction.Visible) 'Program page exposes direct launch using its route'
        foreach($item in $liveList.Items){$item.Selected=$false};[Windows.Forms.Application]::DoEvents()
        Assert-Usability (-not $routeButton.Enabled -and -not $programMoreButton.Enabled -and -not $launchAction.Enabled) 'Selection-only route, more settings and launch are disabled without a program'
        $script:UsabilityRequest=$null;$routeButton.PerformClick();$launchAction.PerformClick()
        Assert-Usability ($null -eq $script:UsabilityRequest -and -not $appMenu.Visible) 'Disabled selection actions cannot dispatch or open a stale menu'
        Save-UiCapture ('programs-unselected-'+$factor)
        $fixture=[pscustomobject]@{Name='隔离测试编辑器';Path='C:\Fixtures\editor.exe';SavedPath='C:\Fixtures\editor.exe';Policy='backup';Mode='managed';CanLaunch=$true;HasSavedRule=$true;RequiresRepair=$false;Loaded=$true;Actual='未观察到 TCP 连接';Status='已保存备用线路，等待启动';PIDs='';ChildNames='';Coverage='隔离演示对象'}
        Show-Applications ([pscustomobject]@{Rows=@($fixture);Available=$true;RulesAvailable=$true;TcpAvailable=$true;RuleCount=1;LaunchRuleCount=0;DefaultRoute='office';DefaultLoaded=$true})
        $liveList.Items[0].Selected=$true;$liveList.Items[0].Focused=$true;[Windows.Forms.Application]::DoEvents()
        Assert-Usability ($routeButton.Enabled -and $programMoreButton.Enabled -and $launchAction.Enabled) 'Selecting a valid saved program enables its task actions'
        $selectionText=(@(Get-UiTree $programPage|Where-Object {$_.Visible -and ($_ -is [Windows.Forms.Label] -or $_ -is [Windows.Forms.TextBox])}|ForEach-Object Text) -join "`r`n")
        Assert-Usability ($selectionText.Contains($fixture.Name) -and $selectionText.Contains($fixture.Path)) 'Selected-program explanation identifies the exact name and executable'
        Save-UiCapture ('programs-selected-'+$factor)
        foreach($dimension in $dimensions){$form.Size=New-Object Drawing.Size($dimension.Width,$dimension.Height);[Windows.Forms.Application]::DoEvents();Save-UiCapture ('programs-selected-'+$dimension.Name+'-'+$factor);Assert-ActionLayout $form ('selected/'+$dimension.Name);Assert-Instruction $programSelectionLabel ('selected target/'+$dimension.Name);Assert-Instruction $programHint ('selected scope/'+$dimension.Name)}
        $form.Size=New-Object Drawing.Size($dimensions[1].Width,$dimensions[1].Height);[Windows.Forms.Application]::DoEvents()
        $script:UsabilityRequest=$null;$launchAction.PerformClick()
        Assert-Usability ($script:UsabilityRequest.Kind -eq 'AppLaunch' -and $script:UsabilityRequest.Key -ceq $fixture.Path) 'Direct launch dispatches the selected executable without launching a user application'
        $routeButton.PerformClick();[Windows.Forms.Application]::DoEvents()
        Assert-Usability ($routeMenu.Visible) 'Selected-program route button opens its compact route menu'
        foreach($routeKey in @('Follow','Direct','office','backup')){Assert-Usability (@($routeMenu.Items|Where-Object {$_.Tag -ceq $routeKey -and $_.Available -and $_.Enabled}).Count -eq 1) ('Program route menu still exposes '+$routeKey)}
        Save-UiCapture ('program-route-menu-'+$factor) $routeMenu
        $script:UsabilityRequest=$null;@($routeMenu.Items|Where-Object Tag -eq 'Direct')[0].PerformClick();$routeMenu.Close()
        $requestPayload=$script:UsabilityRequest.Key|ConvertFrom-Json
        Assert-Usability ($script:UsabilityRequest.Kind -eq 'ManagedAppRoute' -and $requestPayload.path -ceq $fixture.Path -and $requestPayload.route -ceq 'Direct') 'Selected route action keeps exact program scope'
        $programMoreButton.PerformClick();[Windows.Forms.Application]::DoEvents()
        Assert-Usability ($appMenu.Visible -and $menuTitle.Text -ceq $fixture.Name) 'Program more-settings menu names the selected target'
        $menuItems=@(Get-MenuTree $appMenu.Items)
        $submenuIndex=0
        foreach($advancedItem in @($websiteProgramItem,$cleanStartItem,$directTestItem,$launchSettingsButton,$detail)){Assert-Usability ($advancedItem.Available -and $advancedItem.Enabled -and $menuItems.Contains($advancedItem)) ('Program advanced menu action remains reachable: '+$advancedItem.Text);Reveal-MenuItem $advancedItem;Save-UiCapture ('program-submenu'+$submenuIndex+'-'+$factor) $advancedItem.Owner;$submenuIndex++}
        Save-UiCapture ('program-more-menu-'+$factor) $appMenu;$appMenu.Close()
        $navigation[1].PerformClick();[Windows.Forms.Application]::DoEvents()
        Assert-Usability ($proxyServiceButton.Visible -and $proxyMoreButton.Visible) 'Proxy service and selected-entry more settings have visible entries'
        $proxyServiceButton.PerformClick();[Windows.Forms.Application]::DoEvents()
        Assert-Usability ($proxyServiceMenu.Visible) 'Proxy service entry opens an actual menu'
        foreach($advancedItem in @($failoverItem,$independentItem,$externalItem,$serviceHelpItem)){Assert-Usability ($advancedItem.Available -and $proxyServiceMenu.Items.Contains($advancedItem)) ('Advanced proxy service action retained: '+$advancedItem.Text)}
        Save-UiCapture ('proxy-services-'+$factor) $proxyServiceMenu
        $script:UsabilityRequest=$null;$externalItem.PerformClick();$proxyServiceMenu.Close()
        Assert-Usability ($script:UsabilityRequest.Kind -eq 'ConfigureGateway') 'Advanced menu dispatches engine configuration through the worker boundary'
        foreach($item in $proxyList.Items){$item.Selected=$false};Set-UiActionAvailability
        Assert-Usability (-not $proxyEditButton.Enabled -and -not $proxyProbeButton.Enabled -and -not $proxyMoreButton.Enabled -and -not $proxyOpenButton.Enabled) 'Proxy selection actions are disabled without an entry'
        $proxyList.Items[0].Selected=$true;[Windows.Forms.Application]::DoEvents()
        Assert-Usability ($proxyEditButton.Enabled -and $proxyProbeButton.Enabled -and $proxyMoreButton.Enabled) 'Selecting a proxy enables only its entry operations'
        $proxyMoreButton.PerformClick();[Windows.Forms.Application]::DoEvents()
        Assert-Usability ($proxyMoreMenu.Visible -and $deleteProxyItem.Available) 'Selected proxy menu retains explicit removal'
        Save-UiCapture ('proxy-more-'+$factor) $proxyMoreMenu;$proxyMoreMenu.Close()
        $script:UsabilityRequest=$null;$proxyProbeButton.PerformClick()
        Assert-Usability ($script:UsabilityRequest.Kind -eq 'Diagnose' -and $script:UsabilityRequest.Key -ceq $proxyList.SelectedItems[0].Tag.Id) 'Proxy diagnosis targets exactly the selected entry'
        Assert-Usability (@(Get-UiTree $toolsPage|Where-Object {$_ -is [Windows.Forms.TabControl]}).Count -ge 1) 'Tools have browsable task groups'
        foreach($control in @($networkDiagnoseButton,$networkRepairButton,$cleanStopButton,$updateButton,$automaticUpdates)){Reveal-UiControl $control;Assert-ActionLayout $form ('tools behavior/'+$control.Text)}
        Reveal-UiControl $networkDiagnoseButton;$script:UsabilityRequest=$null;$networkDiagnoseButton.PerformClick()
        Assert-Usability ($script:UsabilityRequest.Kind -eq 'NetworkDiagnose') 'Network task remains a read-only diagnosis request'
        Reveal-UiControl $networkRepairButton;$script:NetworkDiagnosis=$null;$script:UsabilityRequest=$null;$networkRepairButton.PerformClick()
        Assert-Usability ($null -eq $script:UsabilityRequest) 'Repair without a current diagnosis does not dispatch a write'
        $script:CleanSession=[pscustomobject]@{Status=[pscustomobject]@{Phase='active';Message='Isolated comparison fixture'}};Set-UiActionAvailability
        Reveal-UiControl $cleanStopButton;$script:UsabilityRequest=$null;$cleanStopButton.PerformClick()
        Assert-Usability ($script:UsabilityRequest.Kind -eq 'CleanStartStop') 'Grouped comparison-stop action remains reachable'
        Assert-Usability ((Get-Command Show-Guide).ScriptBlock.ToString() -notmatch 'MessageBox.*::Show') 'Guide is a structured tutorial window'
        Invoke-InformationAcceptance {$help.PerformClick()} ('guide-'+$factor)
        Assert-Usability ($script:InfoText -match '统一切换' -and $script:InfoText -match '程序' -and $script:InfoText -match '网站' -and $script:InfoText -match '启动|重开') 'Guide explains global route, programs, websites and restart effects'
        Invoke-InformationAcceptance {Show-AppDetails $fixture} ('details-'+$factor)
        Assert-Usability ($script:InfoText.Contains($fixture.Name) -and $script:InfoText.Contains($fixture.Path)) 'Scrollable details preserve exact selected-program identity'
        $autoRefresh.Checked=$false;$script:PendingAction=$null;$script:Worker=$null;$script:DialogOpen=$false;$script:MenuOpen=$false
        $queued=[pscustomobject]@{Kind='AppDesktopMode';Key='isolated-exact-payload'}
        try{
            foreach($guard in @('dialog','menu','busy')){
                $script:PendingAction=$queued;$script:UsabilityRequest=$null
                $script:DialogOpen=($guard -eq 'dialog');$script:MenuOpen=($guard -eq 'menu');$script:Worker=$(if($guard -eq 'busy'){[pscustomobject]@{Kind='fixture-busy'}}else{$null})
                Invoke-PendingUiAction
                Assert-Usability ($null -eq $script:UsabilityRequest -and $script:PendingAction -eq $queued) ('Pending action waits without mutation while '+$guard)
            }
            $script:DialogOpen=$false;$script:MenuOpen=$false;$script:Worker=$null;$script:PendingAction=$queued;$requestCount=$script:UsabilityRequests
            Invoke-PendingUiAction
            Assert-Usability ($null -eq $script:PendingAction -and $script:UsabilityRequest.Kind -ceq $queued.Kind -and $script:UsabilityRequest.Key -ceq $queued.Key -and $script:UsabilityRequests -eq $requestCount+1) 'Idle pending action dispatches the exact payload once with automatic refresh disabled'
            Invoke-PendingUiAction
            Assert-Usability ($script:UsabilityRequests -eq $requestCount+1) 'Consumed pending action cannot dispatch twice'
        }finally{$script:PendingAction=$null;$script:Worker=$null;$script:DialogOpen=$false;$script:MenuOpen=$false}
        $script:ProfileFixture=[pscustomobject]@{
            Version=3
            Profiles=@(
                [pscustomobject]@{Id='self';Name='隔离流向入口';Protocol='http';Host='127.0.0.1';Port=18765;AppPath='';CorePath='';AutoPort=$false},
                [pscustomobject]@{Id='backup';Name='隔离上游';Protocol='socks5';Host='127.0.0.1';Port=18766;AppPath='';CorePath='';AutoPort=$false}
            )
            Routing=[pscustomobject]@{Adapter='standalone';ProfileId='self';UnifiedMode='gateway';Failover=[pscustomobject]@{Enabled=$true;Order=@('backup');AllowDirect=$false}}
        }
        function Read-ProfileSettings {if($script:FailoverReadFailure){throw 'Isolated profile read failure'};$script:ProfileFixture|ConvertTo-Json -Depth 12 -Compress|ConvertFrom-Json}
        function Save-ProfileSettings {param($Value,$Expected);$script:ProfileSaveCalls++;$script:ProfileSaved=$Value|ConvertTo-Json -Depth 12 -Compress|ConvertFrom-Json}
        function Reload-ProfileViews {param($Settings);$script:ProfileReloaded=$true}
        foreach($profileId in @('self','backup')){
            $script:ProfileSaved=$null;$script:ProfileReloaded=$false;$script:ProfileSeen=$false;$script:ProfileError='';$script:ProfileEditingId=$profileId
            $profileTimer=New-Object Windows.Forms.Timer;$profileTimer.Interval=50
            $profileTimer.Add_Tick({
                $dialog=@([Windows.Forms.Application]::OpenForms|Where-Object Name -eq 'FlowProfileEditor')|Select-Object -First 1
                if(-not $dialog){return};$profileTimer.Stop()
                try{
                    $script:ProfileSeen=$true;$controls=@{};foreach($control in @(Get-UiTree $dialog)){if($control.Name){$controls[$control.Name]=$control}}
                    $profileTabs=@(Get-UiTree $dialog|Where-Object {$_ -is [Windows.Forms.TabControl]})|Select-Object -First 1
                    Assert-Usability ($profileTabs.TabPages.Count -eq 2) 'Profile editor separates basic entrance fields and advanced associations'
                    foreach($size in @($dialog.MinimumSize,$dialog.Size,(New-Object Drawing.Size(1000,760)))){
                        $dialog.Size=$size;[Windows.Forms.Application]::DoEvents()
                        foreach($page in $profileTabs.TabPages){$profileTabs.SelectedTab=$page;[Windows.Forms.Application]::DoEvents();Save-UiCapture ('profile-'+$script:ProfileEditingId+'-page'+$profileTabs.SelectedIndex+'-width'+$dialog.Width+'-'+$factor) $dialog;Assert-ActionLayout $dialog ('profile/'+$script:ProfileEditingId+'/'+$page.Text);foreach($label in @(Get-UiTree $dialog|Where-Object {$_ -is [Windows.Forms.Label] -and $_.Visible})){Assert-Instruction $label ('profile instruction/'+$page.Text)}}
                    }
                    if($script:ProfileEditingId -eq 'self'){Assert-Usability ($controls.ProfileHost.ReadOnly -and $controls.ProfileAppPath.ReadOnly -and $controls.ProfileCorePath.ReadOnly -and -not $controls.ProfileProtocol.Enabled -and -not $controls.ProfilePort.Enabled) 'Managed self entrance exposes name editing and protects its service fields'}
                    $profileTabs.SelectedIndex=0;$controls.ProfileName.Text='隔离改名-'+$script:ProfileEditingId;$controls.ProfileSave.PerformClick()
                }catch{$script:ProfileError=$_.Exception.Message;$dialog.Close()}
            })
            try{$profileTimer.Start();Show-ProfileEditor (@($script:ProfileFixture.Profiles|Where-Object Id -eq $profileId)[0])}finally{$profileTimer.Stop();$profileTimer.Dispose()}
            Assert-Usability ($script:ProfileSeen -and -not $script:ProfileError) ('Actual profile editor fits and saves: '+$script:ProfileError)
            Assert-Usability ($script:ProfileSaved -and $script:ProfileReloaded -and $script:ProfileSaved.Routing.Adapter -ceq 'standalone' -and $script:ProfileSaved.Routing.ProfileId -ceq 'self' -and ($script:ProfileSaved.Routing.Failover|ConvertTo-Json -Depth 8 -Compress) -ceq ($script:ProfileFixture.Routing.Failover|ConvertTo-Json -Depth 8 -Compress)) 'Saving a name preserves standalone adapter and complete failover policy'
            $savedProfile=@($script:ProfileSaved.Profiles|Where-Object Id -eq $profileId)[0]
            Assert-Usability ($savedProfile.Name -ceq ('隔离改名-'+$profileId) -and $savedProfile.Host -ceq '127.0.0.1' -and $savedProfile.Protocol -ceq @($script:ProfileFixture.Profiles|Where-Object Id -eq $profileId)[0].Protocol) 'Name editing persists only the requested profile fields'
        }
        $script:Profiles=Read-ProfileSettings
        $script:Profiles.Routing.Failover.Enabled=$true;$script:Profiles.Routing.Failover.Order=@('self');$script:Profiles.Routing.Failover.AllowDirect=$false
        $script:ProfileFixture.Routing.Failover.Enabled=$false;$script:ProfileFixture.Routing.Failover.Order=@('backup','self');$script:ProfileFixture.Routing.Failover.AllowDirect=$true
        $script:ProfileFixture.Profiles[1].Name='最新隔离上游'
        $failoverSnapshot=$script:ProfileFixture|ConvertTo-Json -Depth 12 -Compress;$saveCallsBefore=$script:ProfileSaveCalls;$openFormsBefore=[Windows.Forms.Application]::OpenForms.Count
        $script:FailoverReadFailure=$true
        try{Show-FailoverEditor}finally{$script:FailoverReadFailure=$false}
        Assert-Usability (-not $script:DialogOpen -and [Windows.Forms.Application]::OpenForms.Count -eq $openFormsBefore) 'Failover read failure opens no dialog and releases DialogOpen'
        Assert-Usability ($script:ProfileSaveCalls -eq $saveCallsBefore -and ($script:ProfileFixture|ConvertTo-Json -Depth 12 -Compress) -ceq $failoverSnapshot) 'Failover read failure cannot write or change profile settings'
        $script:FailoverSeen=$false;$script:FailoverError=''
        $failoverTimer=New-Object Windows.Forms.Timer;$failoverTimer.Interval=50
        $failoverTimer.Add_Tick({
            $dialog=@([Windows.Forms.Application]::OpenForms|Where-Object Text -eq '备用线路顺序')|Select-Object -First 1
            if(-not $dialog){return};$failoverTimer.Stop()
            try{
                $script:FailoverSeen=$true;$all=@(Get-UiTree $dialog)
                $enabled=@($all|Where-Object {$_ -is [Windows.Forms.CheckBox] -and $_.Text -match '^代理失效'})[0]
                $allowDirect=@($all|Where-Object {$_ -is [Windows.Forms.CheckBox] -and $_.Text -match '^全部代理失效'})[0]
                $order=@($all|Where-Object {$_ -is [Windows.Forms.ListBox]})[0]
                Assert-Usability ($enabled.Checked -eq $false -and $allowDirect.Checked -eq $true) 'Actual failover checkboxes use the freshly read policy rather than stale UI settings'
                Assert-Usability (($order.Items|ForEach-Object Id) -join ',' -ceq 'backup,self') 'Actual failover order uses the freshly read policy'
                Assert-Usability ($order.Items[0].Name -ceq '最新隔离上游') 'Actual failover rows resolve names from the freshly read profile catalog'
                Save-UiCapture ('failover-fresh-cancel-'+$factor) $dialog
            }catch{$script:FailoverError=$_.Exception.Message}finally{$dialog.DialogResult='Cancel';$dialog.Close()}
        })
        try{$failoverTimer.Start();Show-FailoverEditor}finally{$failoverTimer.Stop();$failoverTimer.Dispose()}
        Assert-Usability ($script:FailoverSeen -and -not $script:FailoverError -and -not $script:DialogOpen) ('Latest failover policy dialog opens and cancels cleanly: '+$script:FailoverError)
        Assert-Usability ($script:ProfileSaveCalls -eq $saveCallsBefore -and ($script:ProfileFixture|ConvertTo-Json -Depth 12 -Compress) -ceq $failoverSnapshot) 'Canceling the freshly read policy never saves or changes settings'
        Write-Output ('PASS: '+$script:UsabilityChecks+' usability UI assertions; '+$script:UsabilityShots+' captures; scale '+$factor+'; isolated Demo and mutation guards; fresh failover and read-failure regressions.')
'@
$path=Join-Path $qa 'ProxyWindow.ps1';$source=[IO.File]::ReadAllText($path)
$marker='$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)'
if(([regex]::Matches($source,[regex]::Escape($marker))).Count -ne 1){throw 'Preview injection marker must be unique.'}
$source=$source.Replace($marker,$checks+"`r`n"+$marker)
[IO.File]::WriteAllText($path,$source,(New-Object Text.UTF8Encoding($true)))
$priorScale=$env:FLOW_USABILITY_SCALE
try{
    $env:FLOW_USABILITY_SCALE=$Scale.ToString([Globalization.CultureInfo]::InvariantCulture)
    $uiResult=@(& (Join-Path $qa 'ProxySwitch.ps1') -Demo -DataDirectory (Join-Path $qa 'data') -PreviewPath (Join-Path $qa 'usability.png'))
    $uiResult|Write-Output
    if(-not ($uiResult -match '^PASS: \d+ usability UI assertions')){throw 'Usability UI did not complete its assertions.'}
}finally{
    $env:FLOW_USABILITY_SCALE=$priorScale
    if($OutputDirectory){[void][IO.Directory]::CreateDirectory($OutputDirectory);foreach($artifact in Get-ChildItem -LiteralPath $qa -Filter '*.png'){Copy-Item -LiteralPath $artifact.FullName -Destination (Join-Path $OutputDirectory $artifact.Name)}}
}

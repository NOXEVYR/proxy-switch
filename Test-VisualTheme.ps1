param([string]$OutputDirectory='', [double]$Scale=1)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;using System.Reflection;using System.Windows.Forms;
public static class FlowVisualInput {
    [System.Runtime.InteropServices.DllImport("user32.dll")]private static extern IntPtr SendMessage(IntPtr h,int m,IntPtr w,IntPtr l);
    [System.Runtime.InteropServices.DllImport("user32.dll")]private static extern int GetWindowLong(IntPtr h,int index);
    public static bool HorizontalBar(Control target){return (GetWindowLong(target.Handle,-16)&0x100000)!=0;}
    public static void Key(Control target,int key){SendMessage(target.Handle,0x100,new IntPtr(key),IntPtr.Zero);SendMessage(target.Handle,0x101,new IntPtr(key),IntPtr.Zero);}
    public static void Mouse(Control target,string method,MouseButtons button,int x,int y,int delta) {
        target.GetType().GetMethod(method,BindingFlags.Instance|BindingFlags.NonPublic).Invoke(target,new object[]{new MouseEventArgs(button,1,x,y,delta)});
    }
}
'@
$qa=Join-Path $env:TEMP ('FlowSwitch-visual-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qa)
foreach($name in @('ProxySwitch.ps1','ProxyWindow.ps1','Updates.ps1','ProxyBackend.ps1','ProgramFamilyRouting.ps1','ProgramCleanStart.ps1','CleanStartWorker.ps1','ProgramIdentity.ps1','ManagedRouting.ps1','ProgramFamilyTracking.ps1','ApplicationObservation.ps1','RuleMaintenance.ps1','Preferences.ps1','Storage.ps1','RuntimeSupport.ps1','IndependentGateway.ps1','NetworkDiagnostics.ps1','GatewayWatchdog.ps1','IndependentRouter.cjs','RoutePolicy.cjs','GatewayPortOwnership.ps1','DesktopBranding.cs','ShellShortcut.cs','FlowTheme.cs','ProgramLaunch.ps1','ProcessInventory.ps1','ProxyDiscovery.ps1','AppRouting.ps1','AppRouter.cjs','config.defaults.json')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $qa}
[void][IO.Directory]::CreateDirectory((Join-Path $qa 'assets'))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'assets/FlowSwitch.ico') -Destination (Join-Path $qa 'assets/FlowSwitch.ico')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'UiGuidance.ps1') -Destination $qa
$scriptFile=Join-Path $qa 'ProxyWindow.ps1';$source=[IO.File]::ReadAllText($scriptFile)
$fixture=@'
if($Demo){Set-DemoCatalog}
function Get-DemoApps {
    $rows=@(for($i=0;$i -lt 120;$i++){[pscustomobject]@{Name=('Test program '+$i);Path=('C:\Fixtures\app'+$i+'.exe');Policy='Follow';PolicyName='跟随统一线路';Actual='暂无连接';Status='跟随当前线路';Loaded=$false;Mode='engine'}})
    [pscustomobject]@{Rows=$rows;RuleCount=0;Available=$true;DefaultRoute='office';DefaultLoaded=$true;LaunchRuleCount=0}
}
'@
$source=$source.Replace('if($Demo){Set-DemoCatalog}',$fixture)
$checks=@'
        function Assert-VisibleVisualControl($Control){
            $scrollAncestors=@(for($ancestor=$Control.Parent;$ancestor;$ancestor=$ancestor.Parent){if($ancestor -is [Windows.Forms.ScrollableControl] -and $ancestor.AutoScroll){$ancestor}})
            [array]::Reverse($scrollAncestors)
            # An inner scroll can move the target within its outer viewport; settle both before checking visibility.
            for($pass=0;$pass -lt 2;$pass++){foreach($ancestor in $scrollAncestors){$ancestor.ScrollControlIntoView($Control);$ancestor.PerformLayout();[Windows.Forms.Application]::DoEvents()}}
            if(-not $Control.Visible -or $Control.Width -le 0 -or $Control.Height -le 0){throw ('Network action is not visible: '+$Control.Text)}
            $screenRect=$Control.Parent.RectangleToScreen($Control.Bounds)
            for($ancestor=$Control.Parent;$ancestor;$ancestor=$ancestor.Parent){
                $visibleRect=$ancestor.RectangleToScreen($ancestor.ClientRectangle)
                if(-not $visibleRect.Contains($screenRect)){throw ('Network action clipped by '+$ancestor.GetType().Name+': '+$Control.Text+' control '+$screenRect+' ancestor '+$visibleRect)}
            }
        }
        if($env:FLOW_VISUAL_SCALE){$factor=[single]::Parse($env:FLOW_VISUAL_SCALE,[Globalization.CultureInfo]::InvariantCulture);$form.Scale((New-Object Drawing.SizeF($factor,$factor)));$form.PerformLayout();[Windows.Forms.Application]::DoEvents()}
        if($liveList.Items.Count -ne 120){throw 'Large-list fixture missing.'}
        foreach($index in @(3,1,2,0)){
            $navigation[$index].PerformClick()
            [Windows.Forms.Application]::DoEvents()
            if($tabs.SelectedIndex -ne $index -or $brand.Text -ne $tabs.SelectedTab.Text -or @($navigation|Where-Object Selected).Count -ne 1){throw 'Navigation, title and selection disagree.'}
        }
        $visualMinimum=$form.MinimumSize;$visualDefault=$form.Size
        foreach($dimensions in @(@($visualMinimum.Width,$visualMinimum.Height),@([Math]::Max($visualDefault.Width,1420*$Scale),[Math]::Max($visualDefault.Height,900*$Scale)),@($visualDefault.Width,$visualDefault.Height))){
            $form.Size=New-Object Drawing.Size($dimensions[0],$dimensions[1]);$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
            $navigation[3].PerformClick();[Windows.Forms.Application]::DoEvents()
            if($liveList.Columns[0].Width -lt 140){throw 'Application column is narrower than the readable minimum.'}
            foreach($control in @($networkChoice,$unify,$undo)){Assert-VisibleVisualControl $control}
            # Compare current rectangles in one screen coordinate system, including controls in different parents.
            $choiceRect=$networkChoice.Parent.RectangleToScreen($networkChoice.Bounds)
            $unifyRect=$unify.Parent.RectangleToScreen($unify.Bounds)
            $undoRect=$undo.Parent.RectangleToScreen($undo.Bounds)
            if($choiceRect.IntersectsWith($unifyRect) -or $choiceRect.IntersectsWith($undoRect) -or $unifyRect.IntersectsWith($undoRect)){throw 'Network choice and actions overlap.'}
            if($choiceRect.Bottom -gt $unifyRect.Top -or $choiceRect.Bottom -gt $undoRect.Top -or $unifyRect.Top -ne $undoRect.Top -or $unifyRect.Bottom -ne $undoRect.Bottom -or $unifyRect.Right -gt $undoRect.Left -or $choiceRect.Left -ne $unifyRect.Left -or $choiceRect.Right -le $undoRect.Left){throw 'Network choice must span the first row above the two action buttons.'}
            if($liveList.Items.Count -ne 120){throw 'Resizing lost application rows.'}
            foreach($panel in $panels){if($panel.Bottom -gt $cards.ClientSize.Height){throw 'Summary card clipped'};foreach($label in $panel.Controls){if($label.Right -gt $panel.ClientSize.Width -or $label.Bottom -gt $panel.ClientSize.Height){throw 'Summary label clipped'}}}
            $navigation[0].PerformClick();[Windows.Forms.Application]::DoEvents()
            $total=($liveList.Columns|Measure-Object Width -Sum).Sum
            if($total -gt $liveList.ClientSize.Width){throw ('Columns overflow: '+$total+' > '+$liveList.ClientSize.Width)}
            if($layout.Right -gt $shellLayout.Width -or $layout.Bottom -gt $shellLayout.Height -or $footer.Bottom -gt $layout.Height){throw 'Workspace or footer clipped.'}
        }
        $rail=$liveHost.Rail
        # WinForms can scale native columns after the size event; reproduce that order before painting.
        foreach($column in $liveList.Columns){$column.Width+=12}
        $liveList.Refresh();[Windows.Forms.Application]::DoEvents()
        if([FlowVisualInput]::HorizontalBar($liveList)){throw 'Native horizontal scrollbar visible after late column scaling.'}
        for($frame=0;$frame -lt 80;$frame++){
            $form.Width=$form.MinimumSize.Width+($frame%20)*9
            $form.PerformLayout();$rail.ScrollTo([int]($rail.Maximum*($frame%10)/9))
            $liveList.Refresh();[Windows.Forms.Application]::DoEvents()
            if([FlowVisualInput]::HorizontalBar($liveList)){throw ('Horizontal scrollbar flashed at drag frame '+$frame)}
        }
        $rail.ScrollTo(0)
        if($rail.Maximum -lt 100){throw 'Large list has no usable scroll range.'}
        $rail.ScrollTo($rail.Maximum);[Windows.Forms.Application]::DoEvents()
        if($liveList.TopItem.Index -lt 100){throw 'Scroll-to-bottom failed.'}
        $rail.ScrollTo(0);[Windows.Forms.Application]::DoEvents()
        if($liveList.TopItem.Index -ne 0){throw 'Scroll-to-top failed.'}
        $thumb=$rail.ThumbBounds
        [FlowVisualInput]::Mouse($rail,'OnMouseDown','Left',($thumb.X+1),($thumb.Y+2),0)
        [FlowVisualInput]::Mouse($rail,'OnMouseMove','Left',($thumb.X+1),($rail.Height-4),0)
        [FlowVisualInput]::Mouse($rail,'OnMouseUp','Left',($thumb.X+1),($rail.Height-4),0)
        if($liveList.TopItem.Index -lt 100){throw 'Dragging the thumb failed.'}
        $rail.ScrollTo(0)
        $liveList.Items[0].Selected=$true;$liveList.Items[0].Focused=$true;$liveList.Focus()
        [FlowVisualInput]::Key($liveList,35);[Windows.Forms.Application]::DoEvents()
        if($liveList.TopItem.Index -lt 100){throw ('Native End key scrolling failed; top='+$liveList.TopItem.Index+' focused='+$liveList.FocusedItem.Index+' selected='+($liveList.SelectedIndices -join ',')+' lastBounds='+$liveList.Items[119].Bounds+' viewport='+$liveList.ClientSize+' maximum='+$rail.Maximum)}
        [FlowVisualInput]::Key($liveList,36);[Windows.Forms.Application]::DoEvents()
        if($liveList.TopItem.Index -ne 0){throw 'Native Home key scrolling failed.'}
        $navigation[2].PerformClick();$toolsSections.SelectedIndex=2;$logBox.Text=((1..200|ForEach-Object{'Diagnostic line '+$_}) -join "`r`n");[Windows.Forms.Application]::DoEvents()
        $logHost.Rail.ScrollTo($logHost.Rail.Maximum);[Windows.Forms.Application]::DoEvents()
        if($logHost.Rail.Position -lt 100){throw 'Log scrollbar failed.'}
        $navigation[0].PerformClick();[Windows.Forms.Application]::DoEvents()
        [FlowVisualInput]::Mouse($rail,'OnMouseWheel','None',5,80,-120)
        if($liveList.TopItem.Index -lt 1){throw 'Mouse wheel failed.'}
        $rail.ScrollTo(0)
        Write-Output ('Rail: '+$rail.Bounds+'; visible='+$rail.Visible+'; z='+$liveHost.Controls.GetChildIndex($rail)+'; maximum='+$rail.Maximum)
        $railBitmap=New-Object Drawing.Bitmap($rail.Width,$rail.Height)
        try{$rail.DrawToBitmap($railBitmap,$rail.ClientRectangle);$railBitmap.Save((Join-Path ([IO.Path]::GetDirectoryName($PreviewPath)) 'rail.png'))}finally{$railBitmap.Dispose()}
        if($searchBox.BackColor -ne [FlowSwitch.UI.Palette]::Raised -or $networkChoice.ForeColor -ne [FlowSwitch.UI.Palette]::Text){throw 'Input theme lost.'}
        Write-Output 'PASS: visual checks; late column scaling + 80 drag frames without native horizontal bars, 120 rows, navigation, three widths without overflow/clipping, scroll endpoints, thumb drag, wheel, Home/End, log scrolling and dark inputs.'
'@
$source=$source.Replace('$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)', $checks+"`r`n"+'$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)')
[IO.File]::WriteAllText($scriptFile,$source,(New-Object Text.UTF8Encoding($true)))
$clock=[Diagnostics.Stopwatch]::StartNew()
$priorVisualScale=$env:FLOW_VISUAL_SCALE
try{
    $env:FLOW_VISUAL_SCALE=$Scale.ToString([Globalization.CultureInfo]::InvariantCulture)
    $uiResult=@(& (Join-Path $qa 'ProxySwitch.ps1') -Demo -DataDirectory (Join-Path $qa 'data') -PreviewPath (Join-Path $qa 'large-list.png'))
}finally{$env:FLOW_VISUAL_SCALE=$priorVisualScale}
$uiResult|Write-Output
if(-not ($uiResult -match '^PASS: visual checks')){throw 'Visual UI did not complete its control assertions.'}
if($OutputDirectory){[void][IO.Directory]::CreateDirectory($OutputDirectory);Copy-Item -LiteralPath (Join-Path $qa 'large-list.png') -Destination (Join-Path $OutputDirectory ('large-list-'+$Scale+'.png'));Copy-Item -LiteralPath (Join-Path $qa 'rail.png') -Destination (Join-Path $OutputDirectory ('rail-'+$Scale+'.png'))}
if($clock.Elapsed.TotalSeconds -gt 20){throw 'Visual fixture exceeded 20 seconds; check resize/render loops.'}

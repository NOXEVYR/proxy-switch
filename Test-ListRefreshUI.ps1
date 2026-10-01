param([string]$OutputDirectory='')
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
foreach($name in @('ProxySwitch.ps1','ProxyWindow.ps1','UiGuidance.ps1','Updates.ps1','ProxyBackend.ps1','ProgramRouteAccess.ps1','ProgramFamilyRouting.ps1','ProgramCleanStart.ps1','CleanStartWorker.ps1','ProgramIdentity.ps1','ManagedRouting.ps1','ProgramFamilyTracking.ps1','ApplicationObservation.ps1','RuleMaintenance.ps1','Preferences.ps1','Storage.ps1','RuntimeSupport.ps1','IndependentGateway.ps1','NetworkDiagnostics.ps1','GatewayWatchdog.ps1','IndependentRouter.cjs','RoutePolicy.cjs','GatewayPortOwnership.ps1','DesktopBranding.cs','ShellShortcut.cs','FlowTheme.cs','ProgramLaunch.ps1','ProcessInventory.ps1','ProxyDiscovery.ps1','AppRouting.ps1','AppRouter.cjs','config.defaults.json')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $qa}
[void][IO.Directory]::CreateDirectory((Join-Path $qa 'assets'))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'assets/FlowSwitch.ico') -Destination (Join-Path $qa 'assets/FlowSwitch.ico')
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
        $liveHost.Rail.ScrollTo(60);[Windows.Forms.Application]::DoEvents()
        $expected=Get-ApplicationDisplayKey $liveList.TopItem.Tag
        $index=$liveList.TopItem.Index
        $liveList.Items[65].Selected=$true;$liveList.Items[65].Focused=$true
        Show-Applications (Get-DemoApps);[Windows.Forms.Application]::DoEvents()
        $actual=Get-ApplicationDisplayKey $liveList.TopItem.Tag
        Write-Host ('Refresh top: '+$index+' -> '+$liveList.TopItem.Index)
        if($expected -cne $actual){throw 'Background refresh moved the visible row.'}
        Write-Host ('Focused after refresh: '+$(if($liveList.FocusedItem){$liveList.FocusedItem.Index}else{-1}))
        if(-not $liveList.FocusedItem -or $liveList.FocusedItem.Index -ne 65){throw 'Background refresh lost keyboard focus.'}
        $script:Profiles.Profiles=@(for($n=0;$n -lt 120;$n++){[pscustomobject]@{Id=('proxy'+$n);Name=('Proxy '+$n);Protocol='http';Host='127.0.0.1';Port=(20000+$n)}})
        $navigation[1].PerformClick();Show-ProxyCatalog;[Windows.Forms.Application]::DoEvents()
        $proxyHost.Rail.ScrollTo(60);[Windows.Forms.Application]::DoEvents()
        $proxyTop=$proxyList.TopItem.Tag.Id
        Show-ProxyCatalog;[Windows.Forms.Application]::DoEvents()
        Write-Host ('Proxy top: '+$proxyTop+' -> '+$proxyList.TopItem.Tag.Id)
        if($proxyTop -ne $proxyList.TopItem.Tag.Id){throw 'Background catalog refresh moved the visible row.'}
        $navigation[0].PerformClick();[Windows.Forms.Application]::DoEvents()
        $apps=Get-DemoApps
        $liveList.Items[65].Selected=$true;$liveList.Items[65].Focused=$true
        $stable=$liveList.Items[60]
        $clock=[Diagnostics.Stopwatch]::StartNew()
        for($cycle=0;$cycle -lt 300;$cycle++){
            $apps.Rows[60].Actual='Refresh '+$cycle
            Show-Applications $apps;Show-ProxyCatalog
            if($cycle%15 -eq 0){$navigation[1].PerformClick();Show-Applications $apps;$navigation[0].PerformClick()}
            if($cycle%25 -eq 0){$form.Hide();Show-Applications $apps;Show-ProxyCatalog;$form.Show()}
            if($cycle%10 -eq 0){$form.Size=New-Object Drawing.Size((1180+($cycle%3)*100),(790+($cycle%3)*40));$form.PerformLayout()}
            [Windows.Forms.Application]::DoEvents()
            if(-not [object]::ReferenceEquals($stable,$liveList.Items[60])){throw 'Unchanged row identities were rebuilt.'}
            if($liveList.TopItem.Name -ne $stable.Name -or $liveList.SelectedItems[0].Index -ne 65 -or $liveList.FocusedItem.Index -ne 65){throw ('Refresh state drift at cycle '+$cycle)}
            if($liveList.Items[60].SubItems[2].Text -ne ('Refresh '+$cycle) -or $liveList.Items[60].ForeColor -ne $ink){throw 'Updated row text or color lost.'}
            if([FlowVisualInput]::HorizontalBar($liveList)){throw 'List acquired horizontal scroll displacement.'}
            if($liveHost.Bottom -gt $bottom.Top -or $programGrid.Bottom -gt $programPage.ClientSize.Height){throw 'List overlaps its action bar.'}
            $first=$liveList.TopItem;$next=$liveList.Items[$first.Index+1]
            if($next.Bounds.Top -ne $first.Bounds.Bottom){throw 'Native rows have a gap or overlap.'}
            foreach($item in @($first,$next)){for($c=1;$c -lt $item.SubItems.Count;$c++){if($item.SubItems[$c].Bounds.Left -ne (($liveList.Columns|Select-Object -First $c|Measure-Object Width -Sum).Sum)){throw 'Header and cell columns disagree.'}}}
        }
        Write-Host ('300 refresh/layout cycles: '+[Math]::Round($clock.Elapsed.TotalSeconds,2)+' seconds')
        # Membership changes must preserve identities, not the former numeric row index.
        $changed=Get-DemoApps;$changed.Rows=@($changed.Rows|Select-Object -Skip 5)
        Show-Applications $changed;[Windows.Forms.Application]::DoEvents()
        if($liveList.TopItem.Name -ne $stable.Name -or $liveList.FocusedItem.Name -ne 'C:\Fixtures\app65.exe'){throw 'Membership change lost row identity.'}
        # A data conversion failure must leave the previous complete table usable.
        $bad=Get-DemoApps;$bad.Rows[2].PSObject.Properties.Remove('Actual')
        $bad.Rows[2]|Add-Member ScriptProperty Actual {throw 'fixture conversion failure'}
        $oldFirst=$liveList.Items[0];$oldCount=$liveList.Items.Count
        try{Show-Applications $bad}catch{}
        if($liveList.Items.Count -ne $oldCount -or -not [object]::ReferenceEquals($oldFirst,$liveList.Items[0])){throw 'Failed snapshot partially cleared the table.'}
        Show-Applications $changed
        $searchBox.Text='__missing__';[Windows.Forms.Application]::DoEvents()
        if($liveList.Items.Count -ne 0 -or -not $emptyLabel.Visible){throw 'Empty filter failed.'}
        $searchBox.Text='';[Windows.Forms.Application]::DoEvents()
        if($liveList.Items.Count -ne 115){throw 'Filter reset lost the last valid snapshot.'}
        $liveHost.Rail.ScrollTo($liveHost.Rail.Maximum);[Windows.Forms.Application]::DoEvents()
        if($liveList.Items[$liveList.Items.Count-1].Bounds.Bottom -gt $liveList.ClientSize.Height){throw 'Last row cannot be fully scrolled into view.'}
        $navigation[1].PerformClick();[Windows.Forms.Application]::DoEvents()
        if($proxyList.TopItem.Tag.Id -ne $proxyTop){throw 'Hidden catalog drifted during application refreshes.'}
        $navigation[0].PerformClick();$liveHost.Rail.ScrollTo(60);[Windows.Forms.Application]::DoEvents()
        Write-Output 'PASS: list refresh; 300 cycles, in-place updates, focus/selection/scroll, hidden pages, hide/show, resize, membership changes, failed snapshot, filter, column geometry and final row.'
'@
$source=$source.Replace('$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)', $checks+"`r`n"+'$bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)')
[IO.File]::WriteAllText($scriptFile,$source,(New-Object Text.UTF8Encoding($true)))
$uiResult=@(& (Join-Path $qa 'ProxySwitch.ps1') -Demo -DataDirectory (Join-Path $qa 'data') -PreviewPath (Join-Path $qa 'list-refresh.png'))
$uiResult|Write-Output
if(-not ($uiResult -match '^PASS: list refresh')){throw 'List refresh UI did not complete its control assertions.'}
if($OutputDirectory){[void][IO.Directory]::CreateDirectory($OutputDirectory);Copy-Item -LiteralPath (Join-Path $qa 'list-refresh.png') -Destination (Join-Path $OutputDirectory 'list-refresh.png')}

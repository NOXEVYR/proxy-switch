param([string]$PreviewPath,[switch]$SmokeTest,[switch]$PreviewMenu,[switch]$Demo,[string]$PreviewView='Programs',[string]$DataDirectory='',[string]$InitialLaunchProgram='')
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $DataDirectory
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if(-not ('FlowSwitchDesktop' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'DesktopBranding.cs')}
[FlowSwitchDesktop]::Initialize()
if(-not ('FlowSwitch.UI.Palette' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'FlowTheme.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing}
function Assert-ConfiguredLaunchRequest([string]$Executable) {
    if(-not [IO.Path]::IsPathRooted($Executable)){throw '程序启动路径无效，请从流向重新创建代理启动入口。'}
    try{$configured=[bool](Get-ManagedProgramIngress $Executable) -or @((Get-ProgramLaunchEntries)|Where-Object {$_.path -ieq $Executable}).Count -gt 0}
    catch{throw '程序线路记录无法读取，目标程序尚未启动。请在流向中修复或恢复本机规则后重试。'}
    if(-not $configured){throw '此程序尚未配置代理启动入口。请在流向中添加程序并选择线路，再从生成的入口打开。'}
}
if($InitialLaunchProgram){
    try{Assert-ConfiguredLaunchRequest $InitialLaunchProgram}catch{[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'程序代理启动','OK','Warning');return}
}
$script:WindowLease=$null
if(-not $SmokeTest -and -not $Demo -and -not $PreviewPath){
    $script:WindowLease=New-Object FlowSwitchWindowLease($script:DataRoot)
    if($InitialLaunchProgram){
        try{if(-not $script:WindowLease.RequestLaunch($InitialLaunchProgram)){throw '启动请求未接收，请等待当前操作完成后重试；目标程序尚未启动。'}}
        catch{[void][Windows.Forms.MessageBox]::Show('无法将启动请求交给后台流向。请打开流向窗口，等待当前操作完成后重试。','程序代理启动','OK','Warning');$script:WindowLease.Dispose();return}
    }
    if(-not $script:WindowLease.IsPrimary){$script:WindowLease.Dispose();return}
}
[Windows.Forms.Application]::EnableVisualStyles()
$script:Worker=$null;$script:LastState=$null;$script:LastApps=$null;$script:NextPoll=[DateTime]::MinValue
$script:Controls=@();$script:RouteButtons=@{};$script:UiRoot=$PSScriptRoot
. (Join-Path $PSScriptRoot 'Updates.ps1')
. (Join-Path $PSScriptRoot 'UiGuidance.ps1')
$script:MenuOpen=$false;$script:DialogOpen=$false
$script:DiscoveryStatus='正在自动识别';$script:ChoiceDirty=$false;$script:DiscoveryCache=@()
$ink=[Drawing.ColorTranslator]::FromHtml('#EBF3FC')
$muted=[Drawing.ColorTranslator]::FromHtml('#AFBED0')
$accent=[Drawing.ColorTranslator]::FromHtml('#9EDBFA')
$paper=[Drawing.ColorTranslator]::FromHtml('#121C2B')
$form=New-Object Windows.Forms.Form
$form.Text='流向 · 网络代理管家 | FlowSwitch '+$script:ProductVersion
$form.ClientSize=New-Object Drawing.Size(1260,960)
$form.MinimumSize=New-Object Drawing.Size(1180,790)
$form.StartPosition='CenterScreen';$form.AutoScaleMode='Dpi';$form.BackColor=$paper
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
$form.KeyPreview=$true;$form.AllowDrop=$true
$iconPath=Join-Path $PSScriptRoot 'assets\FlowSwitch.ico'
if(Test-Path -LiteralPath $iconPath){$form.Icon=New-Object Drawing.Icon($iconPath)}
function Quote-DesktopArgument([string]$Value){return '"'+[regex]::Replace($Value,'(\\+)$','$1$1')+'"'}
$desktopLauncher=Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))) 'FlowSwitch.exe'
if(Test-Path -LiteralPath $desktopLauncher){
    $desktopCommand=(Quote-DesktopArgument $desktopLauncher)+' --data-directory '+(Quote-DesktopArgument $script:DataRoot)
}else{
    $desktopShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $desktopCommand=(Quote-DesktopArgument $desktopShell)+' -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File '+(Quote-DesktopArgument (Join-Path $PSScriptRoot 'ProxySwitch.ps1'))+' -DataDirectory '+(Quote-DesktopArgument $script:DataRoot)
}
$form.Add_HandleCreated({$script:TaskbarRelaunchReady=[FlowSwitchDesktop]::ConfigureWindow($form.Handle,$desktopCommand,$iconPath)})
function New-Label($Parent,$Text,$X,$Y,$W,$H,$Size=10,$Bold=$false) {
    $l=New-Object Windows.Forms.Label;$l.Text=$Text;$l.AutoEllipsis=$true
    $l.SetBounds($X,$Y,$W,$H);$style=[Drawing.FontStyle]::Regular
    if($Bold){$style=[Drawing.FontStyle]::Bold}
    $l.Font=New-Object Drawing.Font('Microsoft YaHei UI',$Size,$style);$l.ForeColor=$ink
    $Parent.Controls.Add($l);return $l
}
function New-Button($Parent,$Text,$X,$Y,$W,$H,$Action) {
    $b=New-Object FlowSwitch.UI.ActionButton;$b.Text=$Text;$b.SetBounds($X,$Y,$W,$H)
    $b.FlatStyle='Flat';$b.FlatAppearance.BorderSize=0;$b.BackColor=[Drawing.ColorTranslator]::FromHtml('#263A51')
    $b.ForeColor=$ink;$b.Cursor=[Windows.Forms.Cursors]::Hand;$b.Add_Click($Action)
    $Parent.Controls.Add($b);$script:Controls+=$b;return $b
}
function Write-Activity([string]$Text) {
    if(-not $Text){return}
    if($logBox.TextLength -gt 14000){$logBox.Text=$logBox.Text.Substring($logBox.TextLength-9000)}
    $logBox.AppendText('['+(Get-Date -Format 'HH:mm:ss')+'] '+$Text+"`r`n`r`n")
    $logBox.SelectionStart=$logBox.TextLength;$logBox.ScrollToCaret()
    $actionLabel.Text=($Text -split "`r?`n")[0]
}
# Each page owns its actions. Shared status remains visible without claiming a switch.
function New-Grid($Parent,[int]$Rows,[double[]]$Heights) {
    $g=New-Object Windows.Forms.TableLayoutPanel;$g.Dock='Fill';$g.BackColor=[Drawing.Color]::Transparent;$g.ColumnCount=1;$g.RowCount=$Rows;$g.Margin=New-Object Windows.Forms.Padding(0)
    [void]$g.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    foreach($h in $Heights){if($h -eq -1){[void]$g.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))}elseif($h -eq 0){[void]$g.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))}else{[void]$g.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$h)))}}
    if($Parent){$Parent.Controls.Add($g)};return $g
}
function New-TaskCard($Parent,[int]$Column,[int]$Row,[string]$Title,[string]$Description,[string]$ActionText,$Action) {
    $surface=New-Object FlowSwitch.UI.SurfacePanel;$surface.Dock='Fill';$surface.Margin=New-Object Windows.Forms.Padding(4);$surface.Padding=New-Object Windows.Forms.Padding(12,8,12,8);$Parent.Controls.Add($surface,$Column,$Row)
    $g=New-Grid $surface 3 @(0,-1,36)
    $titleLabel=New-Label $g $Title 0 0 400 30 12 $true;$titleLabel.Name='TaskTitle';$titleLabel.AutoSize=$true;$titleLabel.Dock='Fill';$g.SetCellPosition($titleLabel,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
    $g.Add_SizeChanged({$cardTitle=$this.Controls['TaskTitle'];if($cardTitle){$cardTitle.MaximumSize=New-Object Drawing.Size([Math]::Max(1,$this.ClientSize.Width-$cardTitle.Margin.Horizontal),0)}})
    $descriptionLabel=New-Label $g $Description 0 0 400 70 9;$descriptionLabel.Dock='Fill';$descriptionLabel.ForeColor=$muted;$g.SetCellPosition($descriptionLabel,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,1)))
    $button=New-Button $g $ActionText 0 0 192 36 $Action;$button.Dock='Fill';$button.Margin=New-Object Windows.Forms.Padding(0,4,0,0);$g.SetCellPosition($button,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,2)))
    return $button
}
function New-CardGrid($Parent) {
    $g=New-Object FlowSwitch.UI.TaskGrid;$g.Dock='Fill';$g.Margin=New-Object Windows.Forms.Padding(0)
    if($Parent){$Parent.Controls.Add($g)};return $g
}
$layout=New-Grid $null 5 @(76,58,-1,32,26);$layout.Padding=New-Object Windows.Forms.Padding(24,16,24,12);$layout.BackColor=$paper
$shellLayout=New-Object Windows.Forms.TableLayoutPanel;$shellLayout.Dock='Fill';$shellLayout.ColumnCount=2;$shellLayout.RowCount=1;$shellLayout.Margin=New-Object Windows.Forms.Padding(0)
[void]$shellLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,180)))
[void]$shellLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
$form.Controls.Add($shellLayout)
$sidebar=New-Object Windows.Forms.Panel;$sidebar.Dock='Fill';$sidebar.Margin=New-Object Windows.Forms.Padding(0);$sidebar.BackColor=[Drawing.ColorTranslator]::FromHtml('#162337');$shellLayout.Controls.Add($sidebar,0,0)
$shellLayout.Controls.Add($layout,1,0)
$sideIcon=New-Object Windows.Forms.PictureBox;$sideIcon.SetBounds(18,24,64,64);$sideIcon.SizeMode='Zoom';$sideIcon.Image=(New-Object Drawing.Icon($iconPath,64,64)).ToBitmap();$sidebar.Controls.Add($sideIcon)
$null=New-Label $sidebar '流向' 24 100 150 48 23 $true
$sideSubtitle=New-Label $sidebar 'F L O W S W I T C H' 24 147 150 24 8;$sideSubtitle.ForeColor=$muted
$sectionLabel=New-Label $sidebar '网络工作台' 24 202 130 25 9;$sectionLabel.ForeColor=$muted
$sideFoot=New-Label $sidebar ("每条连接，自由选择。`r`nFlowSwitch "+$script:ProductVersion) 22 740 150 54 9;$sideFoot.ForeColor=$muted;$sideFoot.Anchor='Bottom,Left'
$sidebar.Add_SizeChanged({$sideFoot.Top=$sidebar.ClientSize.Height-$sideFoot.Height-24;$lastNavigationBottom=0;foreach($n in $navigation){$lastNavigationBottom=[Math]::Max($lastNavigationBottom,$n.Bottom)};$sideFoot.Visible=($sideFoot.Top -gt $lastNavigationBottom+16)})
$header=New-Object Windows.Forms.Panel;$header.Dock='Fill';$header.BackColor=$paper;$header.Margin=New-Object Windows.Forms.Padding(0,0,0,12);$layout.Controls.Add($header,0,0)
$brand=New-Label $header '程序线路' 0 1 350 36 20 $true;$brand.ForeColor=[Drawing.Color]::White
$tagline=New-Label $header '选中程序 → 设置线路 → 按此线路打开。' 2 39 670 24 9;$tagline.ForeColor=$muted
$help=New-Button $header '本页用法' 816 17 116 34 {Show-Guide @('programs','proxies','diagnostics','switch')[$tabs.SelectedIndex]};$help.Anchor='Top,Right'
$header.Add_SizeChanged({$help.Left=$header.ClientSize.Width-$help.Width;$brand.Width=[Math]::Max(80,$help.Left-16);$tagline.Width=[Math]::Max(80,$help.Left-16)})
$noticePanel=New-Object Windows.Forms.Panel;$noticePanel.Dock='Fill';$noticePanel.Margin=New-Object Windows.Forms.Padding(0,0,0,8);$layout.Controls.Add($noticePanel,0,1)
$statusLabel=New-Label $noticePanel '正在核对配置' 0 0 1020 22 10 $true;$statusLabel.Anchor='Top,Left,Right'
$noticeLabel=New-Label $noticePanel '打开面板只读取状态；选好线路后再应用。' 0 23 1020 22 9;$noticeLabel.ForeColor=$muted;$noticeLabel.Anchor='Top,Left,Right'
$noticePanel.Add_SizeChanged({$statusLabel.Width=$noticePanel.ClientSize.Width;$noticeLabel.Width=$noticePanel.ClientSize.Width})
$tabs=New-Object FlowSwitch.UI.PageHost;$tabs.Dock='Fill';$tabs.Margin=New-Object Windows.Forms.Padding(0)
$programPage=New-Object FlowSwitch.UI.ScrollablePage('程序线路');$proxyPage=New-Object FlowSwitch.UI.ScrollablePage('代理入口');$toolsPage=New-Object FlowSwitch.UI.ScrollablePage('检查与维护');$homePage=New-Object FlowSwitch.UI.ScrollablePage('网络切换')
foreach($page in @($programPage,$proxyPage,$toolsPage,$homePage)){$page.BackColor=[FlowSwitch.UI.Palette]::Surface}
# Retain existing page indices for keyboard shortcuts and preview integrations.
$tabs.TabPages.AddRange(@($programPage,$proxyPage,$toolsPage,$homePage));$layout.Controls.Add($tabs,0,2)
$homeGrid=New-Grid $homePage 3 @(96,0,-1);$homeGrid.Padding=New-Object Windows.Forms.Padding(12);$homeGrid.MinimumSize=New-Object Drawing.Size(0,740)
$cards=New-Object Windows.Forms.TableLayoutPanel;$cards.Dock='Fill';$cards.ColumnCount=3;$cards.RowCount=1;$cards.Margin=New-Object Windows.Forms.Padding(0)
[void]$cards.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
for($i=0;$i -lt 3;$i++){[void]$cards.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,33.333)))}
$homeGrid.Controls.Add($cards,0,0);$panels=@()
for($i=0;$i -lt 3;$i++){$p=New-Object FlowSwitch.UI.SurfacePanel;$p.Dock='Fill';$p.Margin=New-Object Windows.Forms.Padding(0,0,$(if($i -lt 2){12}else{0}),12);$cards.Controls.Add($p,$i,0);$panels+=$p}
$cardCaption=New-Label $panels[0] '当前系统出口' 16 10 260 22 9;$cardCaption.ForeColor=$muted
$entryValue=New-Label $panels[0] '正在读取…' 16 32 280 29 14 $true
$systemLabel=New-Label $panels[0] 'Windows / 浏览器 / 命令行' 16 61 290 21 8;$systemLabel.ForeColor=$muted
$cardCaption=New-Label $panels[1] '可选代理入口' 16 10 260 22 9;$cardCaption.ForeColor=$muted
$portsLabel=New-Label $panels[1] '检测本地入口…' 16 32 290 29 13 $true
$envLabel=New-Label $panels[1] '正在核对代理变量' 16 61 290 21 8;$envLabel.ForeColor=$muted
$cardCaption=New-Label $panels[2] '程序专用线路' 16 10 260 22 9;$cardCaption.ForeColor=$muted
$ruleValue=New-Label $panels[2] '正在读取…' 16 32 285 29 14 $true
$ruleMeta=New-Label $panels[2] '在程序线路页单独设置' 16 61 290 21 8;$ruleMeta.ForeColor=$muted
foreach($panel in $panels){$panel.Add_SizeChanged({foreach($label in $this.Controls){$label.Width=[Math]::Max(20,$this.ClientSize.Width-$label.Left*2)}})}
$switchRow=New-Object FlowSwitch.UI.SurfacePanel;$switchRow.Dock='Fill';$switchRow.AutoSize=$true;$switchRow.AutoSizeMode='GrowAndShrink';$switchRow.Padding=New-Object Windows.Forms.Padding(16,12,16,12);$switchRow.Margin=New-Object Windows.Forms.Padding(0,0,0,10);$homeGrid.Controls.Add($switchRow,0,1)
$switchGrid=New-Grid $switchRow 3 @(32,0,84);$switchGrid.AutoSize=$true
$switchTitle=New-Label $switchGrid '让所有程序使用同一线路' 0 0 500 30 12 $true;$switchTitle.Dock='Fill';$switchGrid.SetCellPosition($switchTitle,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
$switchScope=New-Label $switchGrid '更改 Windows 系统代理及命令行代理变量；撤销程序专用线路，保留网站例外。旧应用可能需要正常重开。' 0 0 900 30 9;$switchScope.Dock='Fill';$switchScope.ForeColor=$muted;$switchGrid.SetCellPosition($switchScope,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,1)))
$switchScope.AutoSize=$true;$switchGrid.Add_SizeChanged({$switchScope.MaximumSize=New-Object Drawing.Size([Math]::Max(1,$switchGrid.ClientSize.Width),0)})
$switchActions=New-Object Windows.Forms.TableLayoutPanel;$switchActions.Dock='Fill';$switchActions.ColumnCount=2;$switchActions.RowCount=2;$switchActions.Margin=New-Object Windows.Forms.Padding(0)
for($i=0;$i -lt 2;$i++){[void]$switchActions.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,50)));[void]$switchActions.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,50)))};$switchGrid.Controls.Add($switchActions,0,2)
$networkChoice=New-Object FlowSwitch.UI.RouteChoice;$networkChoice.Name='UnifiedRouteChoice';$networkChoice.DropDownStyle='DropDownList';$networkChoice.DisplayMember='Name';$networkChoice.Dock='Fill';$networkChoice.Margin=New-Object Windows.Forms.Padding(0,3,12,3);$switchActions.Controls.Add($networkChoice,0,0)
$switchActions.SetColumnSpan($networkChoice,2)
$networkChoice.Add_SelectionChangeCommitted({$script:ChoiceDirty=$true;$noticeLabel.Text='已选择待应用目标；点击「统一切换」才会更改网络。'})
$unify=New-Button $switchActions '统一切换' 0 0 146 38 {if($networkChoice.SelectedItem){Start-Work 'Switch' $networkChoice.SelectedItem.Id}else{Write-Activity '请先选择目标线路。'}};$unify.Dock='Fill';$unify.Margin=New-Object Windows.Forms.Padding(0,4,12,0);$unify.Primary=$true;$switchActions.SetCellPosition($unify,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,1)))
$undo=New-Button $switchActions '撤回线路更改' 0 0 170 38 {Start-Work 'Restore' ''};$undo.Dock='Fill';$undo.Margin=New-Object Windows.Forms.Padding(0,4,0,0);$switchActions.SetCellPosition($undo,(New-Object Windows.Forms.TableLayoutPanelCellPosition(1,1)))
$homeTasks=New-CardGrid $null;$homeGrid.Controls.Add($homeTasks,0,2)
$null=New-TaskCard $homeTasks 0 0 '1. 准备代理入口' '先运行你已有的代理软件，再发现或填写地址。这里登记入口，不提供代理节点。' '查看代理入口' {$tabs.SelectedTab=$proxyPage}
$null=New-TaskCard $homeTasks 1 0 '2. 为程序单独选线' '希望某个程序走另一条线路？选择它的 EXE 或快捷方式，再设置线路和打开方式。' '设置程序线路' {$tabs.SelectedTab=$programPage}
$websiteButton=New-TaskCard $homeTasks 0 1 '网站例外：直连与代理并用' '只填写域名。例如国内网站直连、其他网站走代理；规则只影响经过流向入口的连接。' '设置网站例外…' {Start-Work 'WebsiteRules' ''}
$null=New-TaskCard $homeTasks 1 1 '连接不通时先检查' '分别检查本地入口、上游和目标网站。端口监听或网页打开都不等于登录成功。' '检查当前网络' {$tabs.SelectedTab=$toolsPage;$toolsSections.SelectedIndex=0;Start-Work 'NetworkDiagnose' ''}
$programGrid=New-Grid $programPage 3 @(0,-1,0);$programGrid.Padding=New-Object Windows.Forms.Padding(14);$programGrid.MinimumSize=New-Object Drawing.Size(0,500)
$toolbar=New-Object Windows.Forms.FlowLayoutPanel;$toolbar.Dock='Fill';$toolbar.AutoSize=$true;$toolbar.AutoSizeMode='GrowAndShrink';$toolbar.WrapContents=$true;$toolbar.Margin=New-Object Windows.Forms.Padding(0,0,0,10);$programGrid.Controls.Add($toolbar,0,0)
$searchLabel=New-Label $toolbar '搜索程序' 0 0 74 26 10;$searchLabel.Margin=New-Object Windows.Forms.Padding(0,6,4,0)
$searchField=New-Object FlowSwitch.UI.SurfacePanel;$searchField.Size=New-Object Drawing.Size(230,36);$searchField.Padding=New-Object Windows.Forms.Padding(10,7,10,7);$searchField.Margin=New-Object Windows.Forms.Padding(0,0,12,6);$searchField.BackColor=[FlowSwitch.UI.Palette]::Raised;$toolbar.Controls.Add($searchField)
$searchBox=New-Object Windows.Forms.TextBox;$searchBox.BorderStyle='None';$searchBox.Dock='Fill';$searchField.Controls.Add($searchBox)
$savedOnly=New-Object Windows.Forms.CheckBox;$savedOnly.Text='只看已设置';$savedOnly.AutoSize=$true;$savedOnly.Margin=New-Object Windows.Forms.Padding(0,7,12,6);$toolbar.Controls.Add($savedOnly)
$add=New-Button $toolbar '添加程序…' 0 0 142 36 {Add-ProgramRule};$add.Margin=New-Object Windows.Forms.Padding(0,0,12,6)
$refresh=New-Button $toolbar '刷新列表' 0 0 106 36 {Start-Work 'Status' ''};$refresh.Margin=New-Object Windows.Forms.Padding(0,0,0,6)
$liveHost=New-Object FlowSwitch.UI.ListHost;$liveHost.Dock='Fill';$liveHost.Margin=New-Object Windows.Forms.Padding(0);$liveList=$liveHost.List;$liveList.View='Details';$liveList.FullRowSelect=$true;$liveList.GridLines=$false;$liveList.BorderStyle='None';$liveList.MultiSelect=$false
$liveList.HideSelection=$false;$liveList.HeaderStyle='Nonclickable';$liveList.ShowItemToolTips=$true;$liveList.ForeColor=$ink
foreach($column in @(@('程序',185),@('已保存的线路',100),@('实际连接（TCP）',355),@('设置与生效状态',320))){[void]$liveList.Columns.Add($column[0],[int]$column[1])};$programGrid.Controls.Add($liveHost,0,1)
$emptyLabel=New-Label $liveList '未找到匹配程序。可清空搜索或添加 EXE / 快捷方式。' 25 65 700 50 11;$emptyLabel.ForeColor=$muted;$emptyLabel.Visible=$false
$bottom=New-Grid $null 3 @(32,0,34);$bottom.AutoSize=$true;$bottom.AutoSizeMode='GrowAndShrink';$bottom.Padding=New-Object Windows.Forms.Padding(0,8,0,0);$programGrid.Controls.Add($bottom,0,2)
$programSelectionLabel=New-Label $bottom '先从列表选择一个程序' 0 0 900 28 11 $true;$programSelectionLabel.Dock='Fill';$bottom.SetCellPosition($programSelectionLabel,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
$programActions=New-Object Windows.Forms.FlowLayoutPanel;$programActions.Dock='Fill';$programActions.AutoSize=$true;$programActions.AutoSizeMode='GrowAndShrink';$programActions.WrapContents=$true;$programActions.Margin=New-Object Windows.Forms.Padding(0);$bottom.Controls.Add($programActions,0,1)
$routeButton=New-Button $programActions '设置此程序线路 ▾' 0 0 190 36 {Show-SelectedMenu};$routeButton.Primary=$true
$programLaunchButton=New-Button $programActions '按此线路打开' 0 0 166 36 {if($liveList.SelectedItems.Count){Start-Work 'AppLaunch' $liveList.SelectedItems[0].Tag.Path}}
$programMoreButton=New-Button $programActions '更多设置 ▾' 0 0 142 36 {if($liveList.SelectedItems.Count){$script:AppTarget=$liveList.SelectedItems[0].Tag;$appMenu.Show($programMoreButton,(New-Object Drawing.Point(0,$programMoreButton.Height)))}}
$programHint=New-Label $bottom '只更改所选程序；网站例外和桌面绑定在更多设置中。空闲时无 TCP 连接不代表断网。' 0 0 900 34 9;$programHint.Dock='Fill';$programHint.ForeColor=$muted;$bottom.SetCellPosition($programHint,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,2)))
$toolsGrid=New-Grid $toolsPage 2 @(0,-1);$toolsGrid.Padding=New-Object Windows.Forms.Padding(14);$toolsGrid.MinimumSize=New-Object Drawing.Size(0,500)
$toolNavigation=New-Object Windows.Forms.FlowLayoutPanel;$toolNavigation.Dock='Fill';$toolNavigation.AutoSize=$true;$toolNavigation.AutoSizeMode='GrowAndShrink';$toolNavigation.WrapContents=$true;$toolNavigation.Margin=New-Object Windows.Forms.Padding(0,0,0,8);$toolsGrid.Controls.Add($toolNavigation,0,0)
$toolsSections=New-Object FlowSwitch.UI.PageHost;$toolsSections.Dock='Fill';$toolsSections.Margin=New-Object Windows.Forms.Padding(0);$toolsGrid.Controls.Add($toolsSections,0,1)
$checkPage=New-Object Windows.Forms.TabPage('连接检查');$maintenancePage=New-Object Windows.Forms.TabPage('维护与恢复');$recordsPage=New-Object Windows.Forms.TabPage('软件与记录');foreach($p in @($checkPage,$maintenancePage,$recordsPage)){$p.BackColor=[FlowSwitch.UI.Palette]::Surface};$toolsSections.TabPages.AddRange(@($checkPage,$maintenancePage,$recordsPage))
$toolCategoryButtons=@()
foreach($spec in @(@('连接检查',0),@('维护与恢复',1),@('软件与记录',2))){$button=New-Button $toolNavigation $spec[0] 0 0 164 36 {$toolsSections.SelectedIndex=[int]$this.Tag};$button.Tag=$spec[1];$toolCategoryButtons+=$button}
$toolsSections.Add_SelectedIndexChanged({foreach($b in $toolCategoryButtons){$b.Primary=([int]$b.Tag -eq $toolsSections.SelectedIndex);$b.Invalidate()}});$toolCategoryButtons[0].Primary=$true
$toolsBar=New-CardGrid $checkPage
$networkDiagnoseButton=New-TaskCard $toolsBar 0 0 '检查当前电脑的网络入口' '读取系统代理、环境变量和入口状态；只检查，不改设置。结果会显示在操作记录中。' '开始网络检查' {Start-Work 'NetworkDiagnose' ''}
$networkRepairButton=New-TaskCard $toolsBar 1 0 '处理检查发现的问题' '先完成左侧检查。有可修复项目时才可操作，并再次确认影响；不会自动结束用户应用。' '查看并修复…' {
    if(-not $script:NetworkDiagnosis -or -not $script:NetworkDiagnosis.RepairAction){Write-Activity '请先检查当前网络，查看可处理项目。';return}
    $script:DialogOpen=$true
    try{if([Windows.Forms.MessageBox]::Show($form,($script:NetworkDiagnosis.RepairText+"`r`n`r`n修复前将重新核验配置。已有应用若仍使用旧入口，需要保存工作后完整重开。"),'修复网络配置','OKCancel','Information') -eq 'OK'){$script:PendingAction=[pscustomobject]@{Kind='NetworkRepair';Key=$script:NetworkDiagnosis.Revision};$script:NetworkDiagnosis=$null}}finally{$script:DialogOpen=$false}
}
$probeSurface=New-Object FlowSwitch.UI.SurfacePanel;$probeSurface.Dock='Fill';$probeSurface.Margin=New-Object Windows.Forms.Padding(6);$probeSurface.Padding=New-Object Windows.Forms.Padding(16,12,16,12);$toolsBar.Controls.Add($probeSurface,0,1)
$probeGrid=New-Grid $probeSurface 4 @(32,-1,38,42)
$probeTitle=New-Label $probeGrid '检测一个代理入口' 0 0 400 30 12 $true;$probeTitle.Dock='Fill';$probeGrid.SetCellPosition($probeTitle,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
$probeNote=New-Label $probeGrid '选择要测试的入口。这里只检查连接，不会替你切换全局线路。' 0 0 400 55 9;$probeNote.Dock='Fill';$probeNote.ForeColor=$muted;$probeGrid.SetCellPosition($probeNote,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,1)))
$diagnosticChoice=New-Object FlowSwitch.UI.RouteChoice;$diagnosticChoice.Name='DiagnosticRouteChoice';$diagnosticChoice.DropDownStyle='DropDownList';$diagnosticChoice.DisplayMember='Name';$diagnosticChoice.Dock='Fill';$probeGrid.Controls.Add($diagnosticChoice,0,2)
$probeButton=New-Button $probeGrid '检测此入口' 0 0 192 36 {if($diagnosticChoice.SelectedItem){Start-Work 'Diagnose' $diagnosticChoice.SelectedItem.Id}};$probeButton.Dock='Fill';$probeButton.Margin=New-Object Windows.Forms.Padding(0,4,0,0);$probeGrid.SetCellPosition($probeButton,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,3)))
$loginDiagnosticButton=New-TaskCard $toolsBar 1 1 'Google 登录链路' '测试当前系统入口和目标 HTTPS 可达性，不读取登录凭据。检测通过不能代替真实账号登录。' 'Google 登录诊断' {Start-Work 'LoginDiagnostic' ''}
$maintenanceCards=New-CardGrid $maintenancePage
$null=New-TaskCard $maintenanceCards 0 0 '重新载入已保存的程序规则' '仅重新提交现有规则；不会为未知程序猜测线路。线路仍不通时，请先查入口和实际连接。' '重新载入规则' {Start-Work 'AppSync' ''}
$cleanStopButton=New-TaskCard $maintenanceCards 1 0 '结束临时直连对照' '对照测试最多五分钟。这里提前恢复仍归测试会话的设置；其他软件后续修改会保留。' '结束对照并恢复' {Start-Work 'CleanStartStop' ''}
$null=New-TaskCard $maintenanceCards 0 1 '启动、托盘与恢复说明' '关闭窗口默认进入系统托盘。停止服务会恢复设置；已运行的应用可能仍需正常重开。' '查看恢复步骤' {Show-Guide 'recovery'}
$null=New-TaskCard $maintenanceCards 1 1 '备用线路和服务设置' '想在代理退出后自动接替？先登记备用入口，再设置接替顺序。服务设置位于代理入口页。' '前往代理入口' {$tabs.SelectedTab=$proxyPage}
$recordsGrid=New-Grid $recordsPage 3 @(108,46,-1)
$clientBar=New-Grid $null 2 @(44,-1);$recordsGrid.Controls.Add($clientBar,0,0)
$updateActions=New-Object Windows.Forms.FlowLayoutPanel;$updateActions.Dock='Fill';$updateActions.WrapContents=$false;$updateActions.Margin=New-Object Windows.Forms.Padding(0);$clientBar.Controls.Add($updateActions,0,0)
$updateButton=New-Button $updateActions '检查更新' 0 0 164 36 {Show-FlowUpdateAction};$updateButton.Name='FlowUpdateAction'
$automaticUpdates=New-Object Windows.Forms.CheckBox;$automaticUpdates.Name='AutomaticUpdates';$automaticUpdates.Text='后台检查更新';$automaticUpdates.Width=180;$automaticUpdates.Height=36
try{$automaticUpdates.Checked=(Read-FlowUpdateSettings).enabled -ne $false}catch{$automaticUpdates.Checked=$false}
$automaticUpdates.Add_CheckedChanged({try{Set-FlowUpdateAutomatic $this.Checked}catch{Write-Activity '更新检查偏好保存失败。'}});$updateActions.Controls.Add($automaticUpdates)
$updateNote=New-Label $clientBar '只从官方稳定版本检查和校验文件；安装需要明确点击并确认。安装前正常恢复代理，失败时保留当前窗口。' 0 0 900 48 9;$updateNote.Dock='Fill';$updateNote.ForeColor=$muted;$clientBar.SetCellPosition($updateNote,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,1)))
$logHeading=New-Object Windows.Forms.Panel;$logHeading.Dock='Fill';$recordsGrid.Controls.Add($logHeading,0,1)
$logTitle=New-Label $logHeading '操作记录与检查结果' 0 8 420 30 11 $true
$exportButton=New-Button $logHeading '导出诊断报告…' 0 0 176 36 {Export-Diagnostics};$exportButton.Anchor='Top,Right';$logHeading.Add_SizeChanged({$exportButton.Left=$logHeading.ClientSize.Width-$exportButton.Width;$logTitle.Width=[Math]::Max(20,$exportButton.Left-16)})
$logHost=New-Object FlowSwitch.UI.LogHost;$logHost.Dock='Fill';$logBox=$logHost.Log;$logBox.Multiline=$true;$logBox.ReadOnly=$true;$logBox.ScrollBars='Vertical';$logBox.Dock='None';$logBox.BackColor=[Drawing.ColorTranslator]::FromHtml('#1B2A3D');$logBox.ForeColor=$ink;$logBox.BorderStyle='None';$recordsGrid.Controls.Add($logHost,0,2)
$actionLabel=New-Label $layout '先准备代理入口，再统一切换或为程序单独选线。' 0 0 1000 32 9;$actionLabel.Dock='Fill';$actionLabel.TextAlign='MiddleLeft';$actionLabel.ForeColor=$muted;$layout.SetCellPosition($actionLabel,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,3)))
$footer=New-Object Windows.Forms.Panel;$footer.Dock='Fill';$footer.Margin=New-Object Windows.Forms.Padding(0);$layout.Controls.Add($footer,0,4)
$autoRefresh=New-Object Windows.Forms.CheckBox;$autoRefresh.Text='自动刷新';$autoRefresh.Checked=$true;$autoRefresh.SetBounds(0,0,105,24);$autoRefresh.ForeColor=$muted;$footer.Controls.Add($autoRefresh)
$autoDiscovery=New-Object Windows.Forms.CheckBox;$autoDiscovery.Text='自动发现代理';$autoDiscovery.Checked=$true;$autoDiscovery.SetBounds(110,0,140,24);$autoDiscovery.ForeColor=$muted;$footer.Controls.Add($autoDiscovery);$autoDiscovery.Add_CheckedChanged({$script:NextPoll=[DateTime]::MinValue})
$countLabel=New-Label $footer '' 260 1 350 24 9;$countLabel.ForeColor=$muted
$checkedLabel=New-Label $footer '' 732 1 260 24 9;$checkedLabel.Anchor='Top,Right';$checkedLabel.TextAlign='TopRight';$checkedLabel.ForeColor=$muted
$footer.Add_SizeChanged({$checkedLabel.Left=$footer.ClientSize.Width-$checkedLabel.Width;$checkedLabel.Visible=($checkedLabel.Left -ge $countLabel.Left+80);$countLabel.Width=[Math]::Max(40,$(if($checkedLabel.Visible){$checkedLabel.Left}else{$footer.ClientSize.Width})-$countLabel.Left-12)})
$uiTips=New-Object Windows.Forms.ToolTip;$uiTips.AutoPopDelay=16000;$uiTips.InitialDelay=450;$uiTips.ReshowDelay=150
$uiTips.SetToolTip($unify,(Get-FlowHelpText 'switch'));$uiTips.SetToolTip($undo,'恢复最近一次线路切换前的网络和程序线路。桌面快捷方式请在启动方式中单独解除绑定。');$uiTips.SetToolTip($routeButton,(Get-FlowHelpText 'programs'));$uiTips.SetToolTip($websiteButton,(Get-FlowHelpText 'websites'));$uiTips.SetToolTip($programLaunchButton,(Get-FlowHelpText 'launch'))
$appMenu=New-Object Windows.Forms.ContextMenuStrip;$appMenu.Font=$form.Font;$appMenu.ShowImageMargin=$false;$appMenu.Renderer=New-Object FlowSwitch.UI.MenuRenderer;$appMenu.BackColor=[FlowSwitch.UI.Palette]::Surface;$appMenu.ForeColor=$ink
$menuTitle=New-Object Windows.Forms.ToolStripMenuItem('程序分流');$menuTitle.Enabled=$false;[void]$appMenu.Items.Add($menuTitle)
foreach($option in @(@('跟随统一线路','Follow'),@('直连','Direct'))){
    $item=New-Object Windows.Forms.ToolStripMenuItem($option[0]);$item.Tag=$option[1]
    $item.Add_Click({if($script:AppTarget){Request-ApplicationRoute ([string]$this.Tag)}})
    [void]$appMenu.Items.Add($item)
}
[void]$appMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$repairItem=New-Object Windows.Forms.ToolStripMenuItem('修复程序路径记录…');$repairItem.Add_Click({if($script:AppTarget.SavedPath){Start-Work 'AppRepairPlan' $script:AppTarget.SavedPath}});[void]$appMenu.Items.Add($repairItem)
$launchItem=New-Object Windows.Forms.ToolStripMenuItem('按指定线路打开（请先退出程序）');$launchItem.Add_Click({if($script:AppTarget){Start-Work 'AppLaunch' $script:AppTarget.Path}});[void]$appMenu.Items.Add($launchItem)
$launchSettingsItem=New-Object Windows.Forms.ToolStripMenuItem('启动方式与桌面绑定…');$launchSettingsItem.Add_Click({if($script:AppTarget){Show-ProgramLaunchSettings $script:AppTarget}});[void]$appMenu.Items.Add($launchSettingsItem)
$entryRepairItem=New-Object Windows.Forms.ToolStripMenuItem('修复旧代理启动入口…');$entryRepairItem.Add_Click({if($script:AppTarget){Start-Work 'AppEntryRepair' $script:AppTarget.Path}});[void]$appMenu.Items.Add($entryRepairItem)
$websiteProgramItem=New-Object Windows.Forms.ToolStripMenuItem('此程序的网站分流…');$websiteProgramItem.Add_Click({if($script:AppTarget){Start-Work 'WebsiteRules' $script:AppTarget.Path}});[void]$appMenu.Items.Add($websiteProgramItem)
$removeSettingItem=New-Object Windows.Forms.ToolStripMenuItem('移除此程序设置');$removeSettingItem.Add_Click({if($script:AppTarget){$saved=$script:AppTarget.SavedPath;if(-not $saved){$saved=$script:AppTarget.Path};Start-Work 'AppRemove' $saved}});[void]$appMenu.Items.Add($removeSettingItem)
$reconnectItem=New-Object Windows.Forms.ToolStripMenuItem('重连此程序的旧线路连接…');$reconnectItem.Add_Click({if($script:AppTarget){Start-Work 'AppReconnectPlan' $script:AppTarget.Path}});[void]$appMenu.Items.Add($reconnectItem)
$familyRuleItem=New-Object Windows.Forms.ToolStripMenuItem('检查并补齐整组程序规则…');$familyRuleItem.Add_Click({if($script:AppTarget -and -not $script:AppTarget.RequiresRepair){$route=$script:AppTarget.Policy;if($route -eq 'Follow' -or -not $route){Write-Activity '请先为主程序选择明确的直连或代理，再预览整组规则。';return};Start-Work 'FamilyRoutePlan' (@{Path=$script:AppTarget.Path;Route=$route}|ConvertTo-Json -Compress)}});[void]$appMenu.Items.Add($familyRuleItem)
$cleanStartItem=New-Object Windows.Forms.ToolStripMenuItem('干净环境启动（请先退出整组程序）…');$cleanStartItem.Add_Click({if($script:AppTarget -and -not $script:AppTarget.RequiresRepair){Start-Work 'CleanStartPlan' (@{Path=$script:AppTarget.Path;DirectTest=$false}|ConvertTo-Json -Compress)}});[void]$appMenu.Items.Add($cleanStartItem)
$directTestItem=New-Object Windows.Forms.ToolStripMenuItem('直连登录对照（限时恢复）…');$directTestItem.Add_Click({if($script:AppTarget -and -not $script:AppTarget.RequiresRepair){Start-Work 'CleanStartPlan' (@{Path=$script:AppTarget.Path;DirectTest=$true}|ConvertTo-Json -Compress)}});[void]$appMenu.Items.Add($directTestItem)
$entryItem=New-Object Windows.Forms.ToolStripMenuItem('复制代理启动入口');$entryItem.Add_Click({
    try{$entries=@(Get-VerifiedProgramShortcuts $script:AppTarget.Path);if(-not $entries.Count){throw '尚未创建代理入口；请打开“启动方式”设置，也可直接在流向中按指定线路打开。'};[Windows.Forms.Clipboard]::SetText(($entries -join "`r`n"));Write-Activity ('已复制代理入口：'+($entries -join '；'))}catch{Write-Activity $_.Exception.Message}
});[void]$appMenu.Items.Add($entryItem)
$copyItem=New-Object Windows.Forms.ToolStripMenuItem('复制程序路径');$copyItem.Add_Click({if($script:AppTarget){[Windows.Forms.Clipboard]::SetText($script:AppTarget.Path);Write-Activity '已复制所选程序的路径。'}});[void]$appMenu.Items.Add($copyItem)
# Keep a short route picker and group the less frequent operations by purpose.
$savedLineMenu=New-Object Windows.Forms.ToolStripMenuItem('更改此程序线路')
$startupMenu=New-Object Windows.Forms.ToolStripMenuItem('启动与桌面入口')
$connectionMenu=New-Object Windows.Forms.ToolStripMenuItem('连接检查与恢复')
$recordsMenu=New-Object Windows.Forms.ToolStripMenuItem('记录与详情')
$detail=New-Object Windows.Forms.ToolStripMenuItem('程序与连接详情…');$detail.Add_Click({Show-AppDetails $script:AppTarget})
$launchSettingsButton=$launchSettingsItem
$programHelpItem=New-Object Windows.Forms.ToolStripMenuItem('此程序怎么设置？');$programHelpItem.Add_Click({Show-Guide 'programs'})
$appMenu.Items.Clear();[void]$appMenu.Items.Add($menuTitle);[void]$appMenu.Items.Add($savedLineMenu);[void]$appMenu.Items.Add($repairItem)
$startupMenu.DropDownItems.AddRange(@($launchItem,$launchSettingsItem,$entryRepairItem,$entryItem))
$connectionMenu.DropDownItems.AddRange(@($websiteProgramItem,$reconnectItem,$familyRuleItem,$cleanStartItem,$directTestItem))
$recordsMenu.DropDownItems.AddRange(@($detail,$copyItem,$removeSettingItem))
$appMenu.Items.AddRange(@($startupMenu,$connectionMenu,$recordsMenu,$programHelpItem))
$launchItem.ToolTipText='先保存工作并正常退出整组程序，再按流向中保存的线路打开。不会自动结束应用。'
$launchSettingsItem.ToolTipText='选择仅从流向内打开、独立代理快捷方式或显式绑定桌面入口；随时可解除绑定。'
$websiteProgramItem.ToolTipText='只有该程序经过流向专用入口时才可设置网站例外；先设置程序线路。'
$familyRuleItem.ToolTipText='预览经过身份核验的联网子进程；确认后补齐缺失规则，保留冲突和网站例外。'
$directTestItem.ToolTipText='会临时更改当前电脑系统代理，最多五分钟；确认后才执行。'
$removeSettingItem.ToolTipText='撤销此程序的线路和流向管理记录，不删除或退出程序。'
$routeMenu=New-Object Windows.Forms.ContextMenuStrip;$routeMenu.Font=$form.Font;$routeMenu.ShowImageMargin=$false;$routeMenu.Renderer=New-Object FlowSwitch.UI.MenuRenderer
function Set-RouteMenuItems($Items) {
    foreach($old in @($Items)){$Items.Remove($old);$old.Dispose()}
    $options=@([pscustomobject]@{Name='跟随统一线路';Id='Follow'},[pscustomobject]@{Name='直连';Id='Direct'})
    $options+=@($script:Profiles.Profiles|Where-Object {-not ($script:Profiles.Routing.Adapter -eq 'standalone' -and $_.Id -eq (Get-GatewayKey))})
    foreach($option in $options){$item=New-Object Windows.Forms.ToolStripMenuItem($option.Name);$item.Tag=$option.Id;$item.Checked=($option.Id -eq $script:AppTarget.Policy);$item.Enabled=(-not $script:AppTarget.RequiresRepair);$item.Add_Click({if($script:AppTarget){Request-ApplicationRoute ([string]$this.Tag)}});[void]$Items.Add($item)}
}
function Complete-ProgramMenu {$script:MenuOpen=$false;if($script:DeferredApps){Show-Applications $script:DeferredApps;$script:DeferredApps=$null}}
$routeMenu.Add_Opening({if(-not $script:AppTarget.Path -or ($script:Worker -and $script:Worker.Kind -ne 'Status')){$_.Cancel=$true;return};$_.Cancel=$false;$script:MenuOpen=$true;Set-RouteMenuItems $routeMenu.Items})
$routeMenu.Add_Closed({Complete-ProgramMenu})
$appMenu.Add_Opening({
    if(-not $script:AppTarget.Path -or ($script:Worker -and $script:Worker.Kind -ne 'Status')){$_.Cancel=$true;return}
    $script:MenuOpen=$true;$menuTitle.Text=$script:AppTarget.Name;Set-RouteMenuItems $savedLineMenu.DropDownItems
    $running=@($script:AppTarget.PIDs|Where-Object {$_}).Count -gt 0 -or [bool]$script:AppTarget.Running
    $launchItem.Enabled=([bool]$script:AppTarget.CanLaunch -and -not $running -and -not $script:AppTarget.RequiresRepair);$entryItem.Enabled=[bool]$script:AppTarget.CanLaunch
    $launchItem.Visible=[bool]$script:AppTarget.CanLaunch;$entryItem.Visible=[bool]$script:AppTarget.CanLaunch
    $reconnectItem.Enabled=([bool](Get-GatewayKey) -and -not $script:AppTarget.RequiresRepair -and $script:LastApps.Available -and $script:LastApps.RulesAvailable -and ($script:AppTarget.Mode -eq 'engine' -or ($script:LastApps.DefaultRoute -and $script:LastApps.DefaultLoaded)))
    $repairItem.Visible=[bool]$script:AppTarget.RequiresRepair;$repairItem.Enabled=[bool]$script:AppTarget.CanRepair
    $launchSettingsItem.Enabled=(-not $script:AppTarget.RequiresRepair)
    $entryRepairItem.Visible=($script:AppTarget.Mode -in @('launch','managed') -and -not $script:AppTarget.RequiresRepair)
    $websiteProgramItem.Enabled=($script:AppTarget.Mode -eq 'managed' -and -not $script:AppTarget.RequiresRepair)
    $familyRuleItem.Enabled=(-not $script:AppTarget.RequiresRepair);$cleanStartItem.Enabled=(-not $script:AppTarget.RequiresRepair);$directTestItem.Enabled=(-not $script:AppTarget.RequiresRepair)
    $removeSettingItem.Visible=[bool]($script:AppTarget.SavedPath -or $script:AppTarget.HasSavedRule)
})
$appMenu.Add_Closed({Complete-ProgramMenu})
$liveList.Add_SelectedIndexChanged({Set-UiActionAvailability})
$liveList.Add_MouseDown({if($_.Button -eq 'Right'){$hit=$liveList.GetItemAt($_.X,$_.Y);if($hit){$hit.Selected=$true;$script:AppTarget=$hit.Tag;$appMenu.Show($liveList,$_.Location)}}})
$liveList.Add_DoubleClick({Show-AppDetails})
$searchBox.Add_TextChanged({if($script:LastApps){Show-Applications $script:LastApps}})
$savedOnly.Add_CheckedChanged({if($script:LastApps){Show-Applications $script:LastApps}})
$form.Add_KeyDown({if($_.Control -and $_.KeyCode -eq 'F'){$tabs.SelectedIndex=0;$searchBox.Focus();$_.SuppressKeyPress=$true};if($_.KeyCode -eq 'F5'){Start-Work 'Status' '';$_.SuppressKeyPress=$true}})
$form.Add_DragEnter({if($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)){$_.Effect='Copy'}})
$form.Add_DragDrop({$files=$_.Data.GetData([Windows.Forms.DataFormats]::FileDrop);if($files.Count -eq 1){Add-ProgramRule $files[0]}else{Write-Activity '每次拖入一个程序，便于确认对应线路。'}})
$proxyGrid=New-Grid $proxyPage 4 @(60,0,-1,0);$proxyGrid.Padding=New-Object Windows.Forms.Padding(14);$proxyGrid.MinimumSize=New-Object Drawing.Size(0,500)
$intro=New-Label $proxyGrid '登记已有代理软件提供的 HTTP / SOCKS5 入口。发现、保存和检测都不会自动切换网络；流向自身不提供代理节点。' 0 0 980 54 10;$intro.Dock='Fill';$proxyGrid.SetCellPosition($intro,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
$proxyBar=New-Object Windows.Forms.FlowLayoutPanel;$proxyBar.Dock='Fill';$proxyBar.AutoSize=$true;$proxyBar.AutoSizeMode='GrowAndShrink';$proxyBar.WrapContents=$true;$proxyBar.Margin=New-Object Windows.Forms.Padding(0,0,0,8);$proxyGrid.Controls.Add($proxyBar,0,1)
$proxyAddButton=New-Button $proxyBar '添加代理入口…' 0 0 166 36 {Show-ProfileEditor}
$discoveryButton=New-Button $proxyBar '发现后台代理' 0 0 166 36 {Start-Work 'Discover' ''}
$proxyServiceButton=New-Button $proxyBar '备用与服务 ▾' 0 0 166 36 {$proxyServiceMenu.Show($proxyServiceButton,(New-Object Drawing.Point(0,$proxyServiceButton.Height)))}
$proxyServiceMenu=New-Object Windows.Forms.ContextMenuStrip;$proxyServiceMenu.ShowImageMargin=$false;$proxyServiceMenu.Renderer=New-Object FlowSwitch.UI.MenuRenderer;$proxyServiceMenu.Font=$form.Font
$failoverItem=New-Object Windows.Forms.ToolStripMenuItem('备用线路顺序…');$failoverItem.Add_Click({Show-FailoverEditor});[void]$proxyServiceMenu.Items.Add($failoverItem)
$independentItem=New-Object Windows.Forms.ToolStripMenuItem('使用流向独立入口…');$independentItem.Add_Click({$script:DialogOpen=$true;try{if([Windows.Forms.MessageBox]::Show($form,'将建立流向固定入口用于程序分流，并迁移当前设置。需要先准备可用的上游代理。是否继续？','使用流向独立入口','OKCancel','Information') -eq 'OK'){$script:PendingAction=[pscustomobject]@{Kind='Independent';Key=''}}}finally{$script:DialogOpen=$false}});[void]$proxyServiceMenu.Items.Add($independentItem)
$externalItem=New-Object Windows.Forms.ToolStripMenuItem('配置外部 Clash 引擎（高级）…');$externalItem.Add_Click({Start-Work 'ConfigureGateway' ''});[void]$proxyServiceMenu.Items.Add($externalItem)
$serviceHelpItem=New-Object Windows.Forms.ToolStripMenuItem('这些设置怎么选？');$serviceHelpItem.Add_Click({Show-Guide 'failover'});[void]$proxyServiceMenu.Items.Add($serviceHelpItem)
$proxyHost=New-Object FlowSwitch.UI.ListHost;$proxyHost.Dock='Fill';$proxyHost.Margin=New-Object Windows.Forms.Padding(0);$proxyList=$proxyHost.List;$proxyList.View='Details';$proxyList.FullRowSelect=$true;$proxyList.MultiSelect=$false;$proxyList.HideSelection=$false
foreach($column in @(@('名称',240),@('协议',100),@('地址',245),@('端口',85),@('用途',135),@('状态',150))){[void]$proxyList.Columns.Add($column[0],[int]$column[1])};$proxyGrid.Controls.Add($proxyHost,0,2);$proxyList.Add_DoubleClick({Edit-SelectedProfile})
$proxyEmpty=New-Label $proxyList '先运行代理软件，再点击「发现后台代理」；也可添加自定义地址。' 28 60 750 45 12;$proxyEmpty.ForeColor=$muted
$proxySelection=New-Grid $null 3 @(30,0,32);$proxySelection.AutoSize=$true;$proxySelection.AutoSizeMode='GrowAndShrink';$proxySelection.Padding=New-Object Windows.Forms.Padding(0,6,0,0);$proxyGrid.Controls.Add($proxySelection,0,3)
$proxySelectionLabel=New-Label $proxySelection '先选择一个代理入口' 0 0 900 28 11 $true;$proxySelectionLabel.Dock='Fill';$proxySelection.SetCellPosition($proxySelectionLabel,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
$proxyActions=New-Object Windows.Forms.FlowLayoutPanel;$proxyActions.Dock='Fill';$proxyActions.AutoSize=$true;$proxyActions.AutoSizeMode='GrowAndShrink';$proxyActions.WrapContents=$true;$proxyActions.Margin=New-Object Windows.Forms.Padding(0);$proxySelection.Controls.Add($proxyActions,0,1)
$proxyEditButton=New-Button $proxyActions '编辑入口…' 0 0 140 36 {Edit-SelectedProfile}
$proxyProbeButton=New-Button $proxyActions '检测此入口' 0 0 140 36 {if($proxyList.SelectedItems.Count){Start-Work 'Diagnose' $proxyList.SelectedItems[0].Tag.Id}}
$proxyOpenButton=New-Button $proxyActions '打开关联代理软件' 0 0 192 36 {if($proxyList.SelectedItems.Count){Open-Client $proxyList.SelectedItems[0].Tag.Id}}
$proxyMoreButton=New-Button $proxyActions '更多 ▾' 0 0 106 36 {$proxyMoreMenu.Show($proxyMoreButton,(New-Object Drawing.Point(0,$proxyMoreButton.Height)))}
$proxyMoreMenu=New-Object Windows.Forms.ContextMenuStrip;$proxyMoreMenu.ShowImageMargin=$false;$proxyMoreMenu.Renderer=New-Object FlowSwitch.UI.MenuRenderer;$proxyMoreMenu.Font=$form.Font
$deleteProxyItem=New-Object Windows.Forms.ToolStripMenuItem('从列表移除此入口…');$deleteProxyItem.Add_Click({$script:DialogOpen=$true;try{if($proxyList.SelectedItems.Count -and (Confirm-ProxyRemoval $proxyList.SelectedItems[0].Tag)){Remove-SelectedProfile}}finally{$script:DialogOpen=$false}});[void]$proxyMoreMenu.Items.Add($deleteProxyItem)
$engineLabel=New-Label $proxySelection '' 0 0 980 32 9;$engineLabel.Dock='Fill';$engineLabel.ForeColor=$muted;$proxySelection.SetCellPosition($engineLabel,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,2)))
$uiTips.SetToolTip($discoveryButton,'只识别和登记本机代理，不更改系统或程序线路。');$uiTips.SetToolTip($proxyServiceButton,(Get-FlowHelpText 'failover'))
function Request-ApplicationRoute([string]$Route) {
    if($script:AppTarget.RequiresRepair){Write-Activity '程序路径已变化，请先修复路径记录；也可移除旧设置后重新添加。';return}
    Start-Work 'ManagedAppRoute' (@{path=$script:AppTarget.Path;route=$Route}|ConvertTo-Json -Compress)
}
function Get-ApplicationDisplayKey($App) {if($App.RowKey){return $App.RowKey};return $App.Path}
function Show-SelectedMenu {
    if(-not $liveList.SelectedItems.Count){Write-Activity '请先选中一个程序。';return}
    $script:AppTarget=$liveList.SelectedItems[0].Tag;$routeMenu.Show($routeButton,(New-Object Drawing.Point(0,$routeButton.Height)))
}
function Add-ProgramRule([string]$TargetPath='') {
    if($script:Worker -and $script:Worker.Kind -ne 'Status'){return}
    $script:DialogOpen=$true
    try{
        if(-not $TargetPath){
            $picker=New-Object Windows.Forms.OpenFileDialog;$picker.Filter='程序或快捷方式 (*.exe;*.lnk)|*.exe;*.lnk';$picker.Title='选择程序或桌面快捷方式';$picker.DereferenceLinks=$false
            try{if($picker.ShowDialog($form) -ne 'OK'){return};$TargetPath=$picker.FileName}finally{$picker.Dispose()}
        }
        $path=Resolve-ProgramTarget $TargetPath
        $match=$script:LastApps.Rows | Where-Object {$_.Path -ieq $path} | Select-Object -First 1
        $policy='Follow';if($match){$policy=$match.Policy}
        if($match){$script:AppTarget=$match}else{$script:AppTarget=[pscustomobject]@{Path=$path;Name=[IO.Path]::GetFileNameWithoutExtension($path);Policy=$policy;SavedPath='';RequiresRepair=$false;CanRepair=$false}}
        $routeMenu.Show([Windows.Forms.Cursor]::Position)
    }catch{Write-Activity $_.Exception.Message}finally{$script:DialogOpen=$false}
}
function Show-AppDetails($App=$null) {
    if(-not $App -and $liveList.SelectedItems.Count){$App=$liveList.SelectedItems[0].Tag}
    if(-not $App){Write-Activity '请先选中一个程序。';return}
    $script:DialogOpen=$true;$dialog=$null
    try{
        $connections='未观察到 TCP 连接；空闲不代表断网。'
        if($App.ConnectionDetails){$connections=($App.ConnectionDetails|Select-Object -First 30|ForEach-Object {'PID '+$_.PID+' · '+$_.LocalAddress+':'+$_.LocalPort+' → '+$_.RemoteAddress+':'+$_.RemotePort+' · '+$_.IngressName+' → '+$_.RouteName+' · '+$_.State+$(if($_.TargetAddress){' · 目标 '+$_.TargetAddress+':'+$_.TargetPort}else{''})}) -join "`r`n"}
        $entries='未创建独立桌面入口。可在启动方式中设置；桌面绑定是可选项。'
        if($App.CanLaunch){$shortcuts=@(Get-VerifiedProgramShortcuts $App.Path);if($shortcuts.Count){$entries=$shortcuts -join "`r`n"}}
        $content=$App.Name+"`r`n`r`n【程序与设置】`r`n程序路径："+$App.Path+"`r`n保存路径："+$App.SavedPath+"`r`n身份识别："+$App.IdentityReason+"`r`n进程 ID："+$(if($App.PIDs){$App.PIDs}else{'未运行'})+"`r`n线路状态："+$App.Status+"`r`n`r`n【当前连接证据】`r`n"+$connections+"`r`n`r`n【启动入口】`r`n"+$entries+"`r`n请先正常退出整组程序，再按此线路打开。普通启动仍取决于应用和系统配置。`r`n`r`n【观察范围】`r`n已识别子进程："+$App.ChildNames+"`r`n"+$App.Coverage+"`r`n接入固定入口的主程序与继承入口的子进程可一起改线；保留旧代理地址的进程需要正常重开。未经过入口的连接不能靠保存设置强制改变。已建立连接不证明登录成功。"
        $dialog=New-Object Windows.Forms.Form;$dialog.Name='FlowProgramDetails';$dialog.Text='程序与连接详情';$dialog.Font=$form.Font;$dialog.ClientSize=New-Object Drawing.Size(820,600);$dialog.MinimumSize=New-Object Drawing.Size(660,450);$dialog.StartPosition='CenterParent';$dialog.BackColor=$paper;$dialog.ForeColor=$ink
        $grid=New-Grid $dialog 2 @(-1,48);$grid.Padding=New-Object Windows.Forms.Padding(18)
        $reading=New-Object Windows.Forms.TextBox;$reading.Name='FlowProgramDetailsReading';$reading.Multiline=$true;$reading.ReadOnly=$true;$reading.ScrollBars='Vertical';$reading.Dock='Fill';$reading.BorderStyle='None';$reading.BackColor=[FlowSwitch.UI.Palette]::Surface;$reading.ForeColor=$ink;$reading.Text=$content;$grid.Controls.Add($reading,0,0)
        $close=New-Object Windows.Forms.Button;$close.Text='关闭';$close.Dock='Right';$close.Width=112;$close.DialogResult='Cancel';$grid.Controls.Add($close,0,1);$dialog.CancelButton=$close
        [void]$dialog.ShowDialog($form)
    }catch{Write-Activity $_.Exception.Message}finally{if($dialog){$dialog.Dispose()};$script:DialogOpen=$false}
}

function Show-ProgramLaunchSettings($App) {
    if(-not $App.Path -or $App.RequiresRepair){Write-Activity '请先选择路径有效的程序；失效路径需要先修复。';return}
    if($script:Worker -and $script:Worker.Kind -ne 'Status'){return}
    $script:DialogOpen=$true;$dialog=$null
    try{
        $current=Get-ProgramDesktopState $App.Path
        $dialog=New-Object Windows.Forms.Form;$dialog.Text='启动方式与桌面绑定';$dialog.ClientSize=New-Object Drawing.Size(620,390);$dialog.FormBorderStyle='FixedDialog';$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font;$dialog.BackColor=$form.BackColor;$dialog.ForeColor=$form.ForeColor;$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false
        $description=New-Object Windows.Forms.Label;$description.SetBounds(20,16,580,90);$description.Text=[IO.Path]::GetFileName($App.Path)+"`r`n指定线路与桌面绑定分别设置。普通启动不经过流向启动器；实际联网仍取决于应用和系统配置。按指定线路打开会检查并启动所需代理服务。";$dialog.Controls.Add($description)
        $choices=@();$index=0
        foreach($option in @(@('InApp','不绑定桌面：仅在流向中按指定线路打开（推荐）'),@('Separate','独立代理入口：保留原图标，另建一个代理启动图标'),@('Bound','绑定原桌面入口：双击时先经过流向，可在此解除'))){
            $choice=New-Object Windows.Forms.RadioButton;$choice.Tag=$option[0];$choice.Text=$option[1];$choice.SetBounds(24,116+($index++*42),570,34);$choice.Checked=($option[0] -eq $current.Mode);$choice.Enabled=($option[0] -eq 'InApp' -or [bool]$App.CanLaunch);$dialog.Controls.Add($choice);$choices+=@($choice)
        }
        $notice=New-Object Windows.Forms.Label;$notice.SetBounds(20,250,580,65);$notice.Text='取消绑定会恢复原桌面入口，并移除本工具创建且未被修改的独立入口。保存的线路保留，不会关闭程序或切换当前网络。'+$(if(-not $App.CanLaunch){' 请先指定程序线路，才能创建代理入口。'}else{''});$dialog.Controls.Add($notice)
        $ok=New-Object Windows.Forms.Button;$ok.Text='保存启动方式';$ok.SetBounds(338,335,132,36);$ok.DialogResult='OK';$dialog.Controls.Add($ok);$dialog.AcceptButton=$ok
        $cancel=New-Object Windows.Forms.Button;$cancel.Text='取消';$cancel.SetBounds(480,335,120,36);$cancel.DialogResult='Cancel';$dialog.Controls.Add($cancel);$dialog.CancelButton=$cancel
        if($dialog.ShowDialog($form) -eq 'OK'){
            $selected=$choices|Where-Object Checked|Select-Object -First 1
            if(-not $selected -or -not $selected.Enabled){throw '请选择可用启动方式。'}
            $script:PendingAction=[pscustomobject]@{Kind='AppDesktopMode';Key=(@{Path=$App.Path;Mode=[string]$selected.Tag;Revision=$current.Revision}|ConvertTo-Json -Compress)}
        }
    }catch{Write-Activity $_.Exception.Message}finally{if($dialog){$dialog.Dispose()};$script:DialogOpen=$false}
}

function Show-CleanStartDialog($Plan) {
    $dialog=New-Object Windows.Forms.Form;$dialog.Text=$(if($Plan.DirectTest){'直连登录对照'}else{'干净环境启动'});$dialog.Size=New-Object Drawing.Size(640,390);$dialog.FormBorderStyle='FixedDialog';$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font;$dialog.BackColor=$form.BackColor;$dialog.ForeColor=$form.ForeColor;$dialog.MinimizeBox=$false;$dialog.MaximizeBox=$false
    $description=New-Object Windows.Forms.TextBox;$description.Multiline=$true;$description.ReadOnly=$true;$description.TabStop=$false;$description.ScrollBars='Vertical';$description.BorderStyle='None';$description.BackColor=$form.BackColor;$description.ForeColor=$form.ForeColor;$description.SetBounds(22,18,578,210);$description.Text=[IO.Path]::GetFileName($Plan.Path)+"`r`n"+$Plan.Path+"`r`n`r`n"+$Plan.Message+"`r`n`r`n请先正常退出启动器及全部相关进程。流向不会自动结束程序。";$dialog.Controls.Add($description)
    $elevate=New-Object Windows.Forms.CheckBox;$elevate.Text='此程序需要管理员权限（显示正常 UAC 确认）';$elevate.SetBounds(22,240,575,30);$dialog.Controls.Add($elevate)
    $accept=New-Object Windows.Forms.Button;$accept.Text='确认并启动';$accept.SetBounds(374,295,110,34);$accept.DialogResult='OK';$dialog.Controls.Add($accept)
    $cancel=New-Object Windows.Forms.Button;$cancel.Text='取消';$cancel.SetBounds(495,295,100,34);$cancel.DialogResult='Cancel';$dialog.Controls.Add($cancel);$dialog.AcceptButton=$accept;$dialog.CancelButton=$cancel
    $script:DialogOpen=$true
    try{if($dialog.ShowDialog($form) -eq 'OK'){$Plan.Elevate=[bool]$elevate.Checked;$script:PendingAction=[pscustomobject]@{Kind='CleanStart';Key=($Plan|ConvertTo-Json -Depth 8 -Compress)}}}finally{$script:DialogOpen=$false;$dialog.Dispose()}
}
function Show-Guide([string]$Topic='start') {
    $wasOpen=$script:DialogOpen;$script:DialogOpen=$true
    try{Show-FlowGuide $form $Topic}finally{$script:DialogOpen=$wasOpen}
}
function Show-ToolResults {$tabs.SelectedTab=$toolsPage;$toolsSections.SelectedIndex=2}
function ConvertTo-WebsiteRuleDomain([string]$Value) {
    $domain=$Value.Trim().TrimEnd('.')
    if(-not $domain -or $domain -match '[:/\\?#@\s*]'){throw '只填写域名，例如 example.com；不要粘贴网址、登录链接、端口或授权信息。'}
    try{$domain=(New-Object Globalization.IdnMapping).GetAscii($domain).ToLowerInvariant()}catch{throw '域名格式无效，请检查拼写。'}
    if($domain.Length -gt 253 -or $domain -notmatch '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$'){throw '域名格式无效，请只填写有效域名。'}
    $ip=$null;if([Net.IPAddress]::TryParse($domain,[ref]$ip)){throw '请填写域名；此编辑器不保存 IP 地址规则。'}
    return $domain
}
function Update-WebsiteRuleList($Dialog) {
    $state=$Dialog.Tag;$state.List.BeginUpdate();$state.List.Items.Clear()
    foreach($entry in $state.Entries){
        $scope=$(if($entry.Executable){[IO.Path]::GetFileNameWithoutExtension($entry.Executable)}else{'所有程序'})
        $item=New-Object Windows.Forms.ListViewItem($scope);$item.Tag=$entry;$item.ToolTipText=$entry.Executable
        foreach($value in @($entry.Domain,$(if($entry.Match -eq 'suffix'){'域名及其子域'}else{'仅此域名'}),(Get-RouteName $entry.Route))){[void]$item.SubItems.Add($value)}
        [void]$state.List.Items.Add($item)
    }
    $state.List.EndUpdate();$state.Count.Text='共 '+$state.Entries.Count+' 条网站例外；保存后应用，取消不会更改线路。'
}
function New-WebsiteRuleEditor($Snapshot) {
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='网站分流';$dialog.ClientSize=New-Object Drawing.Size(930,590);$dialog.MinimumSize=New-Object Drawing.Size(850,560)
    $dialog.Font=$form.Font;$dialog.StartPosition='CenterParent';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.BackColor=$paper;$dialog.ForeColor=$ink
    $grid=New-Object Windows.Forms.TableLayoutPanel;$grid.Dock='Fill';$grid.Padding=New-Object Windows.Forms.Padding(18);$grid.ColumnCount=1;$grid.RowCount=6
    foreach($height in @(64,38)){[void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height)))}
    [void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    foreach($height in @(82,43,42)){[void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height)))}
    $dialog.Controls.Add($grid)
    $intro=New-Label $grid '同一个浏览器，不同网站可以分别直连或走代理。只保存域名，不填写登录链接。指定程序的网站例外优先于全局例外；同一范围内更具体域名优先，同名时「仅此域名」优先。网站例外优先于程序线路，统一切换会保留这些例外。' 0 0 880 60 10;$intro.Dock='Fill';$grid.SetCellPosition($intro,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
    $ruleState=$(if(-not $Snapshot.Available){'入口状态不可用，现有规则是否生效尚未确认'}elseif(-not $Snapshot.Loaded){'网站规则尚未加载'}else{'网站规则已加载'})
    $status=New-Label $grid ($ruleState+' · '+$(if($Snapshot.Message){$Snapshot.Message}else{'保存并应用后会重新核验；实际使用仍以连接证据为准。'})) 0 0 880 34 9;$status.ForeColor=$muted;$status.Dock='Fill';$grid.SetCellPosition($status,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,1)))
    $hostPanel=New-Object FlowSwitch.UI.ListHost;$hostPanel.Dock='Fill';$list=$hostPanel.List;$list.View='Details';$list.FullRowSelect=$true;$list.MultiSelect=$false;$list.HideSelection=$false;$list.ShowItemToolTips=$true
    foreach($column in @(@('范围',180),@('域名',320),@('匹配',145),@('线路',200))){[void]$list.Columns.Add($column[0],[int]$column[1])};$list.SetColumnWeights([double[]]@(0.22,0.36,0.18,0.24));$grid.Controls.Add($hostPanel,0,2)
    $editor=New-Object Windows.Forms.TableLayoutPanel;$editor.Dock='Fill';$editor.ColumnCount=4;$editor.RowCount=2
    foreach($width in @(26,34,20,20)){[void]$editor.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,$width)))}
    [void]$editor.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,27)));[void]$editor.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    $grid.Controls.Add($editor,0,3)
    $scope=New-Object FlowSwitch.UI.RouteChoice;$scope.Name='WebsiteScope';$scope.DropDownStyle='DropDownList';$scope.DisplayMember='Name';$scope.Dock='Top'
    [void]$scope.Items.Add([pscustomobject]@{Name='所有程序';Executable=''})
    $paths=@($Snapshot.ContextExecutable)+@($Snapshot.Entries|ForEach-Object Executable)
    foreach($path in @($paths|Where-Object {$_}|Select-Object -Unique)){[void]$scope.Items.Add([pscustomobject]@{Name=[IO.Path]::GetFileNameWithoutExtension($path);Executable=$path})};$scope.SelectedIndex=0
    if($Snapshot.ContextExecutable){for($i=0;$i -lt $scope.Items.Count;$i++){if($scope.Items[$i].Executable -ieq $Snapshot.ContextExecutable){$scope.SelectedIndex=$i;break}}}
    $domain=New-Object Windows.Forms.TextBox;$domain.Name='WebsiteDomain';$domain.Dock='Top';$domain.MaxLength=253
    $match=New-Object FlowSwitch.UI.RouteChoice;$match.Name='WebsiteMatch';$match.DropDownStyle='DropDownList';$match.DisplayMember='Name';$match.Dock='Top'
    [void]$match.Items.Add([pscustomobject]@{Name='仅此域名';Id='exact'});[void]$match.Items.Add([pscustomobject]@{Name='域名及其子域';Id='suffix'});$match.SelectedIndex=1
    $route=New-Object FlowSwitch.UI.RouteChoice;$route.Name='WebsiteRoute';$route.DropDownStyle='DropDownList';$route.DisplayMember='Name';$route.Dock='Top';[void]$route.Items.Add([pscustomobject]@{Name='直连';Id='Direct'})
    foreach($profile in $script:Profiles.Profiles){if($script:Profiles.Routing.Adapter -eq 'standalone' -and $profile.Id -eq (Get-GatewayKey)){continue};[void]$route.Items.Add([pscustomobject]@{Name=$profile.Name;Id=$profile.Id})};$route.SelectedIndex=0
    $controls=@($scope,$domain,$match,$route);$labels=@('适用范围','域名，例如 example.com','匹配方式','使用线路')
    for($i=0;$i -lt 4;$i++){$label=New-Label $editor $labels[$i] 0 0 200 25 9;$label.Dock='Fill';$editor.SetCellPosition($label,(New-Object Windows.Forms.TableLayoutPanelCellPosition($i,0)));$controls[$i].Margin=New-Object Windows.Forms.Padding(0,0,10,0);$editor.Controls.Add($controls[$i],$i,1)}
    $editBar=New-Object Windows.Forms.Panel;$editBar.Dock='Fill';$grid.Controls.Add($editBar,0,4)
    $addRule=New-Object FlowSwitch.UI.ActionButton;$addRule.Name='WebsiteAdd';$addRule.Text='添加 / 更新';$addRule.SetBounds(0,0,120,33);$editBar.Controls.Add($addRule)
    $removeRule=New-Object FlowSwitch.UI.ActionButton;$removeRule.Name='WebsiteRemove';$removeRule.Text='删除选中';$removeRule.SetBounds(130,0,110,33);$editBar.Controls.Add($removeRule)
    $errorLabel=New-Label $editBar '' 252 4 620 34 9;$errorLabel.ForeColor=[Drawing.ColorTranslator]::FromHtml('#E5A6A2');$errorLabel.Anchor='Top,Left,Right'
    $bottom=New-Object Windows.Forms.Panel;$bottom.Dock='Fill';$grid.Controls.Add($bottom,0,5)
    $count=New-Label $bottom '' 0 5 600 32 9;$count.Name='WebsiteCount';$count.ForeColor=$muted;$count.Anchor='Top,Left,Right'
    $cancel=New-Object FlowSwitch.UI.ActionButton;$cancel.Text='取消';$cancel.Name='WebsiteCancel';$cancel.SetBounds(655,0,94,34);$cancel.Anchor='Top,Right';$cancel.DialogResult='Cancel';$bottom.Controls.Add($cancel)
    $save=New-Object FlowSwitch.UI.ActionButton;$save.Name='WebsiteSave';$save.Text='保存并应用';$save.SetBounds(760,0,134,34);$save.Anchor='Top,Right';$save.Primary=$true;$bottom.Controls.Add($save);$dialog.CancelButton=$cancel
    $bottom.Add_Layout({$saveButton=$this.Controls['WebsiteSave'];$cancelButton=$this.Controls['WebsiteCancel'];$saveButton.Left=$this.ClientSize.Width-$saveButton.Width;$cancelButton.Left=$saveButton.Left-$cancelButton.Width-10;$this.Controls['WebsiteCount'].Width=[Math]::Max(100,$cancelButton.Left-10)})
    $entries=New-Object Collections.ArrayList
    foreach($entry in @($Snapshot.Entries)){if($entry){[void]$entries.Add([pscustomobject]@{Id=$entry.Id;Domain=$entry.Domain;Match=$entry.Match;Route=$entry.Route;Executable=$entry.Executable})}}
    $dialog.Tag=[pscustomobject]@{Entries=$entries;Revision=$Snapshot.Revision;List=$list;Scope=$scope;Domain=$domain;Match=$match;Route=$route;Error=$errorLabel;Count=$count;Status=$status;Result=$null}
    $addRule.Add_Click({
        $window=$this.FindForm();$state=$window.Tag
        try{
            $value=ConvertTo-WebsiteRuleDomain $state.Domain.Text
            if(-not $state.Scope.SelectedItem -or -not $state.Match.SelectedItem -or -not $state.Route.SelectedItem){throw '请选择有效的范围、匹配方式和线路；原代理可能已从列表中移除。'}
            $executable=$state.Scope.SelectedItem.Executable;$matchId=$state.Match.SelectedItem.Id;$routeId=$state.Route.SelectedItem.Id
            $existing=@($state.Entries|Where-Object {$_.Domain -ieq $value -and $_.Match -eq $matchId -and $_.Executable -ieq $executable})|Select-Object -First 1
            if($existing){$existing.Route=$routeId}else{[void]$state.Entries.Add([pscustomobject]@{Id=[Guid]::NewGuid().ToString('N');Domain=$value;Match=$matchId;Route=$routeId;Executable=$executable})}
            $state.Error.Text='';$state.Domain.Text='';Update-WebsiteRuleList $window
        }catch{$state.Error.Text=$_.Exception.Message}
    })
    $removeRule.Add_Click({$window=$this.FindForm();$state=$window.Tag;if($state.List.SelectedItems.Count){$state.Entries.Remove($state.List.SelectedItems[0].Tag);$state.Error.Text='';$state.Domain.Text='';Update-WebsiteRuleList $window}else{$state.Error.Text='请先选中要删除的网站规则。'}})
    $list.Add_SelectedIndexChanged({
        if($this.SelectedItems.Count){$state=$this.FindForm().Tag;$entry=$this.SelectedItems[0].Tag;$state.Domain.Text=$entry.Domain;$state.Route.SelectedIndex=-1
            foreach($pair in @(@($state.Scope,'Executable',$entry.Executable),@($state.Match,'Id',$entry.Match),@($state.Route,'Id',$entry.Route))){for($i=0;$i -lt $pair[0].Items.Count;$i++){if($pair[0].Items[$i].($pair[1]) -ieq $pair[2]){$pair[0].SelectedIndex=$i;break}}}
        }
    })
    $save.Add_Click({$window=$this.FindForm();$state=$window.Tag
        if($state.Domain.Text.Trim()){
            $existing=@($state.Entries|Where-Object {$_.Domain -ieq $state.Domain.Text.Trim().TrimEnd('.') -and $_.Executable -ieq $state.Scope.SelectedItem.Executable -and $_.Match -eq $state.Match.SelectedItem.Id -and $_.Route -eq $state.Route.SelectedItem.Id})
            if(-not $existing.Count){$state.Error.Text='输入尚未加入列表，请先点击「添加 / 更新」，或清空域名输入后保存。';return}
        }
        $state.Result=[pscustomobject]@{Entries=@($state.Entries.ToArray());Revision=$state.Revision};$window.DialogResult='OK';$window.Close()
    })
    [FlowSwitch.UI.Palette]::Apply($dialog);Update-WebsiteRuleList $dialog
    return $dialog
}
function Show-WebsiteRulesEditor($Snapshot) {
    $script:DialogOpen=$true;$dialog=$null
    try{
        $dialog=New-WebsiteRuleEditor $Snapshot
        if($dialog.ShowDialog($form) -eq 'OK'){$script:PendingAction=[pscustomobject]@{Kind='WebsiteRulesSave';Key=($dialog.Tag.Result|ConvertTo-Json -Depth 8 -Compress)}}
    }catch{Write-Activity $_.Exception.Message}finally{if($dialog){$dialog.Dispose()};$script:DialogOpen=$false}
}
function Show-ProfileEditor($Profile=$null) {
    $script:DialogOpen=$true;$dialog=$null
    try{
        $current=Read-ProfileSettings
        if(-not $Profile){$Profile=[pscustomobject]@{Id=('p'+[Guid]::NewGuid().ToString('N').Substring(0,12));Name='新代理';Protocol='http';Host='127.0.0.1';Port=8080;AppPath='';CorePath='';AutoPort=$false}}
        $isSelf=($current.Routing.Adapter -eq 'standalone' -and $current.Routing.ProfileId -eq $Profile.Id)
        $dialog=New-Object Windows.Forms.Form;$dialog.Name='FlowProfileEditor';$dialog.Text='编辑代理入口';$dialog.ClientSize=New-Object Drawing.Size(760,610);$dialog.MinimumSize=New-Object Drawing.Size(720,580);$dialog.Font=$form.Font;$dialog.BackColor=$paper;$dialog.ForeColor=$ink;$dialog.StartPosition='CenterParent';$dialog.MinimizeBox=$false
        $root=New-Grid $dialog 4 @(34,64,-1,52);$root.Padding=New-Object Windows.Forms.Padding(18)
        $heading=New-Label $root $(if($isSelf){'流向自有入口'}else{'填写代理软件的入口'}) 0 0 600 32 16 $true;$heading.Dock='Fill';$root.SetCellPosition($heading,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
        $description=New-Label $root $(if($isSelf){'地址和服务类型由流向管理，这里可以改名称。备用线路顺序请在「备用与服务」设置。'}else{'打开你的代理软件设置，找到 HTTP 或 SOCKS5 监听地址和端口，然后填写下方字段。保存只登记入口，之后再选择线路。'}) 0 0 690 60 10;$description.Dock='Fill';$description.ForeColor=$muted;$root.SetCellPosition($description,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,1)))
        $profileTabs=New-Object Windows.Forms.TabControl;$profileTabs.Dock='Fill';$profileTabs.Padding=New-Object Drawing.Point(14,7);$root.Controls.Add($profileTabs,0,2)
        $basicPage=New-Object Windows.Forms.TabPage('基本入口（常用）');$advancedPage=New-Object Windows.Forms.TabPage('关联软件与外部引擎（高级）');foreach($page in @($basicPage,$advancedPage)){$page.BackColor=[FlowSwitch.UI.Palette]::Surface};$profileTabs.TabPages.AddRange(@($basicPage,$advancedPage))
        $basic=New-Object Windows.Forms.TableLayoutPanel;$basic.Dock='Fill';$basic.Padding=New-Object Windows.Forms.Padding(16);$basic.ColumnCount=2;$basic.RowCount=5
        [void]$basic.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,112)));[void]$basic.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
        for($i=0;$i -lt 4;$i++){[void]$basic.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,48)))};[void]$basic.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)));$basicPage.Controls.Add($basic)
        $fields=@{}
        $name=New-Object Windows.Forms.TextBox;$name.Name='ProfileName';$name.Text=$Profile.Name;$fields.Name=$name
        $protocol=New-Object Windows.Forms.ComboBox;$protocol.Name='ProfileProtocol';$protocol.DropDownStyle='DropDownList';$protocol.Items.AddRange(@('HTTP','SOCKS5'));$protocol.SelectedItem=$Profile.Protocol.ToUpperInvariant()
        $hostBox=New-Object Windows.Forms.TextBox;$hostBox.Name='ProfileHost';$hostBox.Text=$Profile.Host;$fields.Host=$hostBox
        $port=New-Object Windows.Forms.NumericUpDown;$port.Name='ProfilePort';$port.Minimum=1;$port.Maximum=65535;$port.Value=$Profile.Port
        $row=0
        foreach($pair in @(@('显示名称',$name),@('代理协议',$protocol),@('监听地址',$hostBox),@('监听端口',$port))){$label=New-Label $basic $pair[0] 0 0 112 30 10;$label.Dock='Fill';$label.TextAlign='MiddleLeft';$basic.SetCellPosition($label,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,$row)));$pair[1].Dock='Top';$pair[1].Margin=New-Object Windows.Forms.Padding(0,10,0,4);$basic.Controls.Add($pair[1],1,$row);$row++}
        $example=New-Label $basic '示例：地址 127.0.0.1，端口填写代理软件显示的数字。不要填写订阅链接、网页地址或账号；其他电脑的入口可填写其主机地址。' 0 0 680 100 9;$example.Dock='Fill';$example.ForeColor=$muted;$basic.Controls.Remove($example);$basic.Controls.Add($example,0,4);$basic.SetColumnSpan($example,2)
        $advanced=New-Grid $advancedPage 6 @(62,48,48,42,38,-1);$advanced.Padding=New-Object Windows.Forms.Padding(14)
        $advancedNote=New-Label $advanced '普通 HTTP / SOCKS5 代理只需填写基本入口。关联软件方便从流向打开它；外部引擎选项仅用于已有 Clash Verge 配置。' 0 0 680 56 9;$advancedNote.Dock='Fill';$advancedNote.ForeColor=$muted;$advanced.SetCellPosition($advancedNote,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
        $i=1
        foreach($spec in @(@('AppPath','关联代理软件'),@('CorePath','外部分流内核'))){
            $line=New-Object Windows.Forms.TableLayoutPanel;$line.Dock='Fill';$line.ColumnCount=3;$line.RowCount=1;$line.Margin=New-Object Windows.Forms.Padding(0);[void]$line.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,130)));[void]$line.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)));[void]$line.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,88)));$advanced.Controls.Add($line,0,$i++)
            $label=New-Label $line $spec[1] 0 0 126 30 10;$label.Dock='Fill';$label.TextAlign='MiddleLeft';$line.SetCellPosition($label,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
            $box=New-Object Windows.Forms.TextBox;$box.Name='Profile'+$spec[0];$box.Dock='Top';$box.Margin=New-Object Windows.Forms.Padding(0,9,8,3);$box.Text=$Profile.($spec[0]);$line.Controls.Add($box,1,0);$fields[$spec[0]]=$box
            $browse=New-Button $line '选择…' 0 0 80 34 {$picker=New-Object Windows.Forms.OpenFileDialog;$picker.Filter='Windows 程序 (*.exe)|*.exe';try{if($picker.ShowDialog($dialog) -eq 'OK'){$this.Tag.Text=$picker.FileName}}finally{$picker.Dispose()}};$browse.Tag=$box;$browse.Dock='Fill';$browse.Margin=New-Object Windows.Forms.Padding(0,5,0,5);$line.SetCellPosition($browse,(New-Object Windows.Forms.TableLayoutPanelCellPosition(2,0)));$browse.Enabled=(-not $isSelf)
        }
        $engine=New-Object Windows.Forms.CheckBox;$engine.Text='使用此外部 Clash Verge HTTP / 混合入口进行程序分流';$engine.Dock='Fill';$engine.Checked=($current.Routing.Adapter -eq 'clash-verge' -and $current.Routing.ProfileId -eq $Profile.Id);$engine.Enabled=(-not $isSelf);$advanced.Controls.Add($engine,0,3)
        $auto=New-Object Windows.Forms.CheckBox;$auto.Text='从外部引擎自动读取端口';$auto.Dock='Fill';$auto.Checked=[bool]$Profile.AutoPort;$auto.Enabled=$engine.Checked;$advanced.Controls.Add($auto,0,4)
        $fixed=New-Object Windows.Forms.CheckBox;$fixed.Text='保留外部引擎固定入口，切换时只改变出口';$fixed.Dock='Top';$fixed.Height=36;$fixed.Checked=($current.Routing.UnifiedMode -eq 'gateway' -or $current.Routing.Adapter -eq 'none');$fixed.Enabled=$engine.Checked;$advanced.Controls.Add($fixed,0,5)
        $engine.Add_CheckedChanged({$auto.Enabled=$engine.Checked;$fixed.Enabled=$engine.Checked})
        if($isSelf){foreach($key in @('Host','AppPath','CorePath')){$fields[$key].ReadOnly=$true};$port.Enabled=$false;$protocol.Enabled=$false;$auto.Enabled=$false;$fixed.Enabled=$false}
        $actions=New-Object Windows.Forms.FlowLayoutPanel;$actions.Dock='Fill';$actions.FlowDirection='RightToLeft';$actions.Margin=New-Object Windows.Forms.Padding(0,8,0,0);$root.Controls.Add($actions,0,3)
        $save=New-Button $actions '保存入口' 0 0 146 36 {
            try{
                $value=Read-ProfileSettings
                if(($current.Routing|ConvertTo-Json -Depth 8 -Compress) -cne ($value.Routing|ConvertTo-Json -Depth 8 -Compress)){throw '服务配置已被其他操作修改，请关闭此窗口后重新编辑。'}
                $entry=[pscustomobject]@{Id=$Profile.Id;Name=$fields.Name.Text;Protocol=$protocol.SelectedItem.ToString().ToLowerInvariant();Host=$fields.Host.Text;Port=[int]$port.Value;AppPath=$fields.AppPath.Text;CorePath=$fields.CorePath.Text;AutoPort=$(if($isSelf){[bool]$Profile.AutoPort}else{$engine.Checked -and $auto.Checked})}
                $value.Profiles=@($value.Profiles|Where-Object {$_.Id -ne $entry.Id})+@($entry)
                if(-not $isSelf){
                    if($engine.Checked){$value.Routing=[pscustomobject]@{Adapter='clash-verge';ProfileId=$entry.Id;UnifiedMode=$(if($fixed.Checked){'gateway'}else{'system'})}}
                    elseif($value.Routing.ProfileId -eq $entry.Id){$value.Routing=[pscustomobject]@{Adapter='none';ProfileId=''}}
                }
                Save-ProfileSettings $value -Expected $current;$dialog.DialogResult='OK';$dialog.Close()
            }catch{[void][Windows.Forms.MessageBox]::Show($dialog,$_.Exception.Message,'无法保存入口','OK','Warning')}
        };$save.Name='ProfileSave'
        $cancel=New-Button $actions '取消' 0 0 112 36 {$dialog.DialogResult='Cancel';$dialog.Close()};$dialog.CancelButton=$cancel
        [FlowSwitch.UI.Palette]::Apply($dialog)
        if($dialog.ShowDialog($form) -eq 'OK'){Reload-ProfileViews;Write-Activity '代理入口已保存。请在网络切换页选择线路并应用，或在程序线路页单独设置；本次保存不切换网络。';$script:NextPoll=[DateTime]::MinValue}
    }catch{Write-Activity $_.Exception.Message}finally{if($dialog){$dialog.Dispose()};$script:DialogOpen=$false;$script:Controls=@($script:Controls|Where-Object {-not $_.IsDisposed})}
}
function Show-FailoverEditor {
    if($script:Profiles.Routing.Adapter -ne 'standalone'){Write-Activity '请先启用独立分流，再设置备用顺序。';return}
    $script:DialogOpen=$true;$dialog=$null
    try{
    $failoverBefore=Read-ProfileSettings
    if($failoverBefore.Routing.Adapter -ne 'standalone'){throw '服务配置已变化，请刷新代理入口后重试。'}
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='备用线路顺序';$dialog.ClientSize=New-Object Drawing.Size(570,410);$dialog.Font=$form.Font;$dialog.StartPosition='CenterParent'
    $enabled=New-Object Windows.Forms.CheckBox;$enabled.Text='代理失效时自动使用备用线路';$enabled.SetBounds(20,15,500,28);$enabled.Checked=$failoverBefore.Routing.Failover.Enabled;$dialog.Controls.Add($enabled)
    $list=New-Object Windows.Forms.ListBox;$list.SetBounds(20,52,425,215);$list.DisplayMember='Name';$dialog.Controls.Add($list)
    foreach($id in $failoverBefore.Routing.Failover.Order){$p=@($failoverBefore.Profiles|Where-Object Id -eq $id)[0];[void]$list.Items.Add($p)}
    foreach($spec in @(@('上移',-1,60),@('下移',1,105))){$button=New-Object Windows.Forms.Button;$button.Text=$spec[0];$button.Tag=$spec[1];$button.SetBounds(462,$spec[2],85,34);$dialog.Controls.Add($button);$button.Add_Click({$index=$list.SelectedIndex;$next=$index+[int]$this.Tag;if($index -ge 0 -and $next -ge 0 -and $next -lt $list.Items.Count){$item=$list.Items[$index];$list.Items.RemoveAt($index);$list.Items.Insert($next,$item);$list.SelectedIndex=$next}})}
    $direct=New-Object Windows.Forms.CheckBox;$direct.Text='全部代理失效时允许直连（默认关闭）';$direct.SetBounds(20,282,525,28);$direct.Checked=$failoverBefore.Routing.Failover.AllowDirect;$dialog.Controls.Add($direct)
    $note=New-Object Windows.Forms.Label;$note.Text='每个程序先使用它指定的线路，再按上面顺序尝试。连续失败后切换；恢复后保留可用备用线路，避免来回跳。';$note.SetBounds(20,316,525,46);$dialog.Controls.Add($note)
    $save=New-Object Windows.Forms.Button;$save.Text='保存';$save.SetBounds(445,365,100,32);$dialog.Controls.Add($save)
    $save.Add_Click({try{
        $value=Read-ProfileSettings;$value.Routing.Failover=[pscustomobject]@{Enabled=$enabled.Checked;Order=@($list.Items|ForEach-Object Id);AllowDirect=$direct.Checked}
        $before=Read-ProfileSettings
        Save-ProfileSettings $value -Expected $failoverBefore
        try{Sync-ApplicationRoutes | Out-Null}catch{Save-ProfileSettings $before -Expected $value;throw}
        Reload-ProfileViews $value;Write-Activity '自动接替策略已保存并载入。';$dialog.Close()
    }catch{[void][Windows.Forms.MessageBox]::Show($dialog,$_.Exception.Message,'设置未完成','OK','Warning')}})
    [void]$dialog.ShowDialog($form)
    }catch{Write-Activity $_.Exception.Message}finally{if($dialog){$dialog.Dispose()};$script:DialogOpen=$false}
}
function Edit-SelectedProfile {
    if(-not $proxyList.SelectedItems.Count){Write-Activity '请先在代理管理中选中一个代理。';return}
    Show-ProfileEditor $proxyList.SelectedItems[0].Tag
}
function Confirm-ProxyRemoval($Profile) {
    [Windows.Forms.MessageBox]::Show($form,('从列表移除「'+$Profile.Name+'」？仅移除登记入口，不卸载或退出代理软件。正在被线路引用的入口会拒绝删除。'),'移除代理入口','OKCancel','Warning') -eq 'OK'
}
function Remove-SelectedProfile {
    if(-not $proxyList.SelectedItems.Count){Write-Activity '请先选择一个代理。';return}
    try{
        $selected=$proxyList.SelectedItems[0].Tag;$value=Read-ProfileSettings
        $value.Profiles=@($value.Profiles | Where-Object {$_.Id -ne $selected.Id})
        if($selected.Host -in @('127.0.0.1','::1','localhost')){$value.DiscoveryIgnored=@($value.DiscoveryIgnored)+@((Get-LocalEndpointId $selected.Host $selected.Port))}
        if($value.Routing.ProfileId -eq $selected.Id){$value.Routing=[pscustomobject]@{Adapter='none';ProfileId=''}}
        Save-ProfileSettings $value;Reload-ProfileViews;Write-Activity '该代理已从列表移除，修改前设置已备份。'
    }catch{Write-Activity $_.Exception.Message}
}
function Reload-ProfileViews($Settings=$null) {
    if($Settings){$script:Profiles=$Settings}elseif(-not $Demo){$script:Profiles=Read-ProfileSettings}
    $chosen=$null;if($networkChoice.SelectedItem){$chosen=$networkChoice.SelectedItem.Id}
    $networkChoice.Items.Clear();[void]$networkChoice.Items.Add([pscustomobject]@{Id='Direct';Name='直连出口 · 入口按当前模式'})
    foreach($p in $script:Profiles.Profiles){if($script:Profiles.Routing.Adapter -eq 'standalone' -and $p.Id -eq (Get-GatewayKey)){continue};[void]$networkChoice.Items.Add([pscustomobject]@{Id=$p.Id;Name=($p.Name+'  ·  '+$p.Protocol.ToUpperInvariant()+'  '+$p.Host+':'+$p.Port)})}
    $index=0;for($i=0;$i -lt $networkChoice.Items.Count;$i++){if($networkChoice.Items[$i].Id -eq $chosen){$index=$i}}
    $networkChoice.SelectedIndex=$index
    $probeChosen=$null;if($diagnosticChoice.SelectedItem){$probeChosen=$diagnosticChoice.SelectedItem.Id};$diagnosticChoice.Items.Clear()
    foreach($item in $networkChoice.Items){if($item.Id -ne 'Direct'){[void]$diagnosticChoice.Items.Add($item)}}
    if($diagnosticChoice.Items.Count){$diagnosticChoice.SelectedIndex=0;for($i=0;$i -lt $diagnosticChoice.Items.Count;$i++){if($diagnosticChoice.Items[$i].Id -eq $probeChosen){$diagnosticChoice.SelectedIndex=$i}}}
    Show-ProxyCatalog;Set-UiActionAvailability
}
function Show-ProxyCatalog {
    $items=New-Object 'Collections.Generic.List[Windows.Forms.ListViewItem]'
    foreach($p in $script:Profiles.Profiles){
        $item=New-Object Windows.Forms.ListViewItem($p.Name);$item.Name=$p.Id;$item.Tag=$p;$item.ForeColor=$ink;$item.ToolTipText=$p.Protocol+'://'+(Get-EndpointAddress $p)
        foreach($value in @($p.Protocol.ToUpperInvariant(),$p.Host,[string]$p.Port,$(if($script:Profiles.Routing.ProfileId -eq $p.Id){$(if($script:Profiles.Routing.Adapter -eq 'standalone'){'流向自有入口'}else{'外部分流引擎'})}else{'上游代理入口'}))){[void]$item.SubItems.Add($value)}
        $state=$script:LastState.Listeners | Where-Object {$_.Key -eq $p.Id} | Select-Object -First 1
        [void]$item.SubItems.Add($(if($state){if($state.Remote){'远程入口 · 可手动检测'}elseif($state.Ready){'本地端口正在监听'}elseif($null -eq $state.Ready){'监听状态未知'}else{'本地端口未监听'}}else{'等待检测'}));$items.Add($item)
    }
    $proxyList.ApplyRows($items.ToArray());$proxyEmpty.Visible=($proxyList.Items.Count -eq 0)
    if($proxyList.Items.Count -eq 0 -and $script:DiscoveryStatus -ne '正在自动识别'){$proxyEmpty.Text='暂未识别到可用 HTTP / SOCKS5 入口。可重新检测，或手动填写地址与端口。'}
    $intro.Text='先运行已有代理软件，再发现或填写 HTTP / SOCKS5 地址。登记、保存和检测不会切换网络。'+"`r`n"+'自动发现：'+$script:DiscoveryStatus+'。流向不提供代理节点。'
    $engineKey=Get-GatewayKey
    if($script:Profiles.Routing.Adapter -eq 'standalone'){$engineLabel.Text='独立分流入口 · 自动接替 '+$(if($script:Profiles.Routing.Failover.Enabled){'已开启'}else{'已关闭'})+' · '+$(if(Test-Path -LiteralPath (Get-IndependentSessionPath)){'托盘停止服务时恢复网络'}else{'服务未启动；统一切换或代理启动入口会检查并启动'});return}
    $engineLabel.Text=$(if($engineKey){'分流引擎：'+(Get-RouteName $engineKey)+$(if($script:Profiles.Routing.UnifiedMode -eq 'gateway'){' · 固定入口模式：引擎保持运行，出口由你选择。'}else{' · 系统入口模式；可编辑引擎启用固定入口。'})}else{'尚未建立流向固定入口。选择目标并点击「统一切换」会建立入口；普通程序选线也会检查接入。'})
}
function Export-Diagnostics {
    if(-not $script:LastState -or -not $script:LastApps){Write-Activity '请等待读取到状态后再导出。';return}
    $picker=New-Object Windows.Forms.SaveFileDialog;$picker.Filter='JSON 诊断报告 (*.json)|*.json';$picker.FileName='FlowSwitch-diagnostics-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json';$script:DialogOpen=$true
    try{if($picker.ShowDialog($form) -eq 'OK'){
        $report=New-SupportReport $script:LastState $script:LastApps
        $report|Add-Member NoteProperty SnapshotStale ([bool]$script:ObservationStale)
        if($script:NetworkDiagnosis){$report|Add-Member NoteProperty NetworkDiagnosis ([pscustomobject]@{CheckedAt=$script:NetworkDiagnosis.CheckedAt;IssueCodes=@($script:NetworkDiagnosis.Issues|ForEach-Object Code);Targets=@($script:NetworkDiagnosis.Targets);RepairAvailable=[bool]$script:NetworkDiagnosis.RepairAction})}
        Write-LocalJson $picker.FileName $report
        Write-Activity '诊断报告已导出：仅含线路、端口和规则数量，不含账号、节点、程序名称和本机路径。'
    }}catch{Write-Activity $_.Exception.Message}finally{$picker.Dispose();$script:DialogOpen=$false}
}
function Mark-ObservationStale {
    $script:ObservationStale=$true
    $statusLabel.Text='当前状态待重新核对 · 请刷新';$checkedLabel.Text='上次记录已过期'
    $entryValue.Text='待刷新';$entryValue.ForeColor=$muted
    $systemLabel.Text='系统入口：待重新读取';$portsLabel.Text='监听状态待刷新';$envLabel.Text='代理变量待重新读取'
    $ruleMeta.Text='规则生效状态待刷新';$ruleValue.ForeColor=$muted
    $noticeLabel.Text='上次观察已过期；请刷新后核对当前入口、实际连接和规则，不代表断网。'
    foreach($row in $liveList.Items){$row.SubItems[2].Text='读取失败 · 上次连接已过期';$row.SubItems[3].Text='请刷新后查看当前状态';$row.ForeColor=$muted}
}
function Show-Applications($Apps) {
    if($script:MenuOpen){$script:DeferredApps=$Apps;return}
    $items=New-Object 'Collections.Generic.List[Windows.Forms.ListViewItem]'
    $policies=@{Follow='跟随统一线路';Direct='直连'};foreach($p in $script:Profiles.Profiles){$policies[$p.Id]=$p.Name}
    $rows=@(Select-ApplicationRows $Apps.Rows $searchBox.Text.Trim() $savedOnly.Checked)
    foreach($app in $rows){
        $item=New-Object Windows.Forms.ListViewItem($app.Name);$item.Name=Get-ApplicationDisplayKey $app;$item.Tag=$app;$item.ForeColor=$ink;$item.ToolTipText=$app.Path
        [void]$item.SubItems.Add($(if($app.PolicyName){$app.PolicyName}else{Get-RouteName $app.Policy}));[void]$item.SubItems.Add($app.Actual)
        $note=$app.Status
        if($app.Mode -eq 'engine' -and -not $app.RequiresRepair -and $script:LastState.Key -ne (Get-GatewayKey)){$note+=' · 系统入口未接入引擎'}
        [void]$item.SubItems.Add($note)
        if($app.Policy -ne 'Follow'){$item.ForeColor=$accent;if(-not $app.Loaded -or $note -match '旧连接|失效|切回'){$item.ForeColor=[Drawing.ColorTranslator]::FromHtml('#DEC395')}}
        if($app.NeedsRelaunch -or $app.RequiresRepair){$item.ForeColor=[Drawing.ColorTranslator]::FromHtml('#DEC395')}
        $items.Add($item)
    }
    $liveList.ApplyRows($items.ToArray());$script:LastApps=$Apps;$emptyLabel.Visible=($rows.Count -eq 0)
    $countLabel.Text='显示 '+$rows.Count+' / '+@($Apps.Rows).Count+' 个程序   ·   Ctrl+F 搜索'
    $ruleValue.Text=[string]$Apps.RuleCount+' 条';$ruleValue.ForeColor=$ink
    $loaded=@($Apps.Rows | Where-Object {$_.Policy -ne 'Follow' -and $_.Loaded}).Count
    $ruleMeta.Text='已加载线路设置 '+$loaded+' 条 · 实际使用见连接列'
    if($Apps.DefaultRoute){$ruleMeta.Text='首选：'+(Get-RouteName $Apps.DefaultRoute)+' · '+$(if($Apps.EffectiveDefaultRoute){'当前：'+(Get-RouteName $Apps.EffectiveDefaultRoute)}elseif($Apps.DefaultLoaded){'已加载'}else{'待重载'})}
    elseif(-not (Get-GatewayKey)){$ruleMeta.Text='程序分流引擎未配置'}
    elseif(-not $Apps.Available){$ruleMeta.Text='引擎状态不可用 · 生效待确认';$ruleValue.ForeColor=$muted}
    if($Apps.LaunchRuleCount){$ruleMeta.Text='启动代理 '+$Apps.LaunchRuleCount+' 条 · 生效状态见程序列表'}
    if($Apps.ManagedRuleCount){$ruleMeta.Text='程序固定入口 '+$Apps.ManagedRuleCount+' 个 · 实际使用见连接列'}
    Set-UiActionAvailability
    if($Apps.RepairCount){$ruleMeta.Text+=' · '+$Apps.RepairCount+' 条路径待修复'}
    if(-not (Test-ObservationFlag $Apps 'TcpAvailable')){$countLabel.Text+=' · 连接采集失败'}
    if((Get-GatewayKey) -and -not (Test-ObservationFlag $Apps 'RulesAvailable' ([bool]$Apps.Available))){$ruleMeta.Text+=' · 规则读取未知'}
    if($Apps.DefaultRoute -and $Apps.DefaultLoaded -eq $false){$noticeLabel.Text='统一路由尚未加载，请检查分流引擎的规则模式并重载。'}
    if($script:Profiles.Routing.Adapter -eq 'standalone' -and $Apps.Available){
        $events=@($Apps.Failover.events | Where-Object {$_ -and $_.id})
        if($events.Count){
            $last=$events[-1]
            if($script:LastFailoverEvent -ne $last.id){
                $reason=switch($last.reason){'listener-closed'{'原代理已退出'};'probe-timeout'{'原线路连续检测超时'};'probe-failed'{'原线路连续检测失败'};default{'线路恢复可用'}}
                Write-Activity ('自动接替 '+$last.at+'：'+(Get-RouteName $last.from)+' → '+(Get-RouteName $last.to)+'（'+$reason+'）。新连接生效。')
                $script:LastFailoverEvent=$last.id
            }
        }
        if($Apps.EffectiveDefaultRoute -eq 'Unknown'){$noticeLabel.Text='当前出口读取失败，接替状态未知；请刷新后确认。'}
        elseif($Apps.EffectiveDefaultRoute -eq 'Blocked'){$noticeLabel.Text='默认代理出口已暂停。直连网站例外或其他程序线路可能继续可用，以各自的实际连接为准；请检查默认上游。'}
        elseif($Apps.EffectiveDefaultRoute -in (@('Direct')+(Get-ProfileKeys)) -and $Apps.EffectiveDefaultRoute -ne $Apps.DefaultRoute){$noticeLabel.Text='已自动接替：'+(Get-RouteName $Apps.DefaultRoute)+' → '+(Get-RouteName $Apps.EffectiveDefaultRoute)+'。旧连接如未恢复，可右键该程序预览重连。'}
        if($Apps.EffectiveDefaultRoute -ne 'Unknown' -and $Apps.Failover.updated -and ([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($Apps.Failover.updated)).TotalSeconds -gt 30){$noticeLabel.Text='自动检测记录已超过 30 秒未更新，暂不能确认接替状态；当前显示为内核实读出口。'}
        elseif($Apps.EffectiveDefaultRoute -ne 'Unknown' -and $Apps.Failover.details -and @($Apps.Failover.details.PSObject.Properties | Where-Object {$_.Value.healthy -eq $null -or $_.Value.selectionError}).Count){$noticeLabel.Text='自动检测或出口切换未完成；已保留当前线路，请查看诊断。'}
    }

    if($script:ObservationStale){Mark-ObservationStale}
}
function Open-Client([string]$Key) {
    try{$profile=Get-Profile $Key;if(-not $profile.AppPath -or -not (Test-Path -LiteralPath $profile.AppPath)){throw '客户端路径无效，请在「代理入口」选择入口并编辑，关联已安装的代理软件。'}
        Start-Process -FilePath $profile.AppPath -WindowStyle Hidden
        Write-Activity ('已请求打开 '+$profile.Name+'。连接完成后再点击「统一切换」。');$script:NextPoll=[DateTime]::MinValue
    }catch{Write-Activity $_.Exception.Message}
}
function Show-State($State) {
    $first=($null -eq $script:LastState);$script:LastState=$State;$headline='入口配置一致';$color=$accent
    if(-not $State.Aligned){$headline='系统入口与代理变量尚未统一';$color=[Drawing.ColorTranslator]::FromHtml('#DEC395')}
    if($State.Drift){$headline='当前入口与上次选择不同 · 保留当前设置';$color=$muted}
    if($State.EndpointReady -eq $false){$headline+=' · 入口未就绪';$color=[Drawing.ColorTranslator]::FromHtml('#E5A6A2')}
    $statusLabel.Text=$headline;$statusLabel.ForeColor=$color;$entryValue.Text=$State.NetworkName;$entryValue.ForeColor=$color
    $systemLabel.Text='系统入口：'+$(if($State.Key -eq 'Direct'){'直连'}else{$State.Server})
    $portsLabel.Text='代理 '+@($State.Listeners).Count+' 个 · 运行中 '+@($State.Listeners | Where-Object Ready).Count+' 个'
    $envLabel.Text='本地监听 '+@($State.Listeners | Where-Object Ready).Count+' 个 · 变量'+$(if($State.EnvConflict){'存在冲突'}elseif($State.Aligned){'已同步'}else{'未完整设置'})
    if(-not (Test-ObservationFlag $State 'TcpAvailable')){$portsLabel.Text='代理 '+@($State.Listeners).Count+' 个 · 监听状态未知';$envLabel.Text='端口采集失败 · 不代表断网'}
    $noticeLabel.Text='自动发现不改变网络选择；切换与程序分流照常使用。已有连接和启动器可能仍保留旧代理。'
    if(-not $State.EnvConflict -and -not $State.Aligned -and $State.EndpointReady -ne $false){$statusLabel.Text='系统入口已读取 · 命令行代理变量未完整设置';$statusLabel.ForeColor=$muted}
    if($script:Profiles.Routing.Adapter -eq 'standalone'){$noticeLabel.Text='独立入口的自动接替'+$(if($script:Profiles.Routing.Failover.Enabled){'已开启'}else{'已关闭'})+'；关闭窗口驻留托盘，托盘菜单可停止服务。已有连接由应用自行重连。'}
    if(@($State.Warnings).Count){$noticeLabel.Text=$State.Warnings -join ' '}
    if($State.EndpointReady -eq $false){$noticeLabel.Text='当前代理入口未就绪。请先启动并等待就绪后重试登录；已有应用可能保留旧代理地址，保存工作后完整重开。'}
    if($script:Profiles.Routing.Adapter -eq 'standalone' -and -not (Test-Path -LiteralPath (Get-IndependentSessionPath))){$statusLabel.Text+=' · 流向服务未启动';$noticeLabel.Text='流向服务未启动，本次打开未更改网络。点击「统一切换」或使用程序代理启动入口会检查并启动服务。'}
    if($script:ChoiceDirty){$noticeLabel.Text='下拉框是待应用目标；当前实际入口以上方卡片为准。'}
    if(-not $script:ChoiceDirty){$networkChoice.SelectedIndex=-1;for($i=0;$i -lt $networkChoice.Items.Count;$i++){if($networkChoice.Items[$i].Id -eq $State.NetworkKey){$networkChoice.SelectedIndex=$i;break}}}
    Show-ProxyCatalog;$checkedLabel.Text='最近读取 '+$State.CheckedAt
}
function Set-DemoCatalog {
    $script:DiscoveryStatus='已识别 2 个入口 · 演示数据'
    $script:Profiles=[pscustomobject]@{Version=3;Routing=[pscustomobject]@{Adapter='clash-verge';ProfileId='office';UnifiedMode='gateway'};Profiles=@(
        [pscustomobject]@{Id='office';Name='办公网络';Protocol='http';Host='127.0.0.1';Port=7890;CorePath='C:\Apps\Engine\mihomo.exe';AppPath='';AutoPort=$false},
        [pscustomobject]@{Id='backup';Name='备用网络';Protocol='socks5';Host='127.0.0.1';Port=1080;CorePath='';AppPath='';AutoPort=$false}
    )}
}
function Get-DemoState {
    [pscustomobject]@{Key='office';Current='办公网络';NetworkKey='office';NetworkName='办公网络';Server='127.0.0.1:7890';Aligned=$true;EnvConflict=$false;EndpointReady=$true;Drift=$false;Environment=@();Listeners=@([pscustomobject]@{Key='office';Ready=$true},[pscustomobject]@{Key='backup';Ready=$true});OldConnections=@();CheckedAt='12:30:00'}
}
function Get-DemoApps {
    [pscustomobject]@{Available=$true;Mode='rule';RuleCount=2;LaunchRuleCount=0;DefaultRoute='office';DefaultLoaded=$true;Rows=@(
        [pscustomobject]@{Name='浏览器';Path='C:\Apps\Browser\browser.exe';Policy='office';Loaded=$true;Actual='办公网络 ×8';Status='已观察到指定线路连接';PIDs='2200,2201';Mode='engine';CanLaunch=$false;ChildNames='network_helper'},
        [pscustomobject]@{Name='开发工具';Path='C:\Apps\Editor\editor.exe';Policy='Follow';PolicyName='未单独指定';Loaded=$false;Actual='运行中 · 未观察到 TCP 连接';Status='未设专用规则 · 以实际连接为准';PIDs='1200'},
        [pscustomobject]@{Name='本地工作台';Path='C:\Apps\Studio\studio.exe';Policy='Direct';Loaded=$true;Actual='直连 ×2';Status='已加载；新连接生效';PIDs='3300'},
        [pscustomobject]@{Name='文件同步';Path='C:\Apps\Sync\sync.exe';Policy='Follow';Loaded=$false;Actual='运行中 · 未观察到 TCP 连接';Status='跟随当前线路';PIDs='4400'}
    )}
}
function Format-Diagnostics($Items) {
    $lines=@()
    foreach($entry in $Items){
        $lines+='【' + $entry.Name + '】'
        if($entry.Error){$lines+=$entry.Error;continue}
        foreach($r in $entry.Results){$lines+=($r.Site + '：' + $r.Note + '  (' + $r.Seconds + ' s)')}
    }
    $lines+='只读探测不携带账户凭据。ChatGPT 403 不等同于断网，也不证明登录后可用。'
    return $lines -join "`r`n"
}
function Start-Work([string]$Kind,[string]$Key) {
    if($script:Worker){
        if($script:Worker.Kind -eq 'Status' -and $Kind -ne 'Status'){
            $script:PendingAction=[pscustomobject]@{Kind=$Kind;Key=$Key}
            $script:Worker.Cancellation.Cancel()
            Write-Activity '正在读取状态，随后执行你的选择…'
        }
        return
    }
    if($Kind -ne 'Status'){
        foreach($b in $script:Controls){$b.Enabled=$false}
        Write-Activity ('正在' + $(if($Kind -eq 'Switch'){'检测并统一设置'}elseif($Kind -eq 'Restore'){'恢复配置'}elseif($Kind -in @('AppRoute','ManagedAppRoute')){'切换程序线路'}elseif($Kind -eq 'WebsiteRules'){'读取网站规则'}elseif($Kind -eq 'WebsiteRulesSave'){'保存并应用网站规则'}elseif($Kind -eq 'Discover'){'查找本机端口'}else{'检测线路'}) + '，请稍候。界面仍可响应。')
    }
    $ps=[PowerShell]::Create();$progress=New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]';$cancellation=New-Object Threading.CancellationTokenSource
    $scan=($Kind -eq 'Discover')
    $automatic=($Kind -eq 'Status' -and $autoDiscovery.Checked -and -not $SmokeTest)
    $code={param($Root,$Kind,$Key,$DataDirectory,$Scan,$Automatic,$Cache,$Progress,$Cancellation)
        $ErrorActionPreference='Stop'
        try{. (Join-Path $Root 'ProxyBackend.ps1') -DataDirectory $DataDirectory}
        catch{return [pscustomobject]@{OK=$false;Kind=$Kind;Stage='initialization';Error='流向无法读取当前配置或运行组件，未执行操作。请检查配置与程序包完整性；原设置未被重置。'}}
        $script:OperationProgress=$Progress
        $result=$null;$discovery=$null;$discoveryError=''
        try {
            if($Scan){try{$discovery=Sync-LocalProxyDiscovery}catch{$discoveryError=$_.Exception.Message}}
            elseif($Automatic){try{$discovery=Sync-AutomaticProxyDiscovery $Cache $Cancellation}catch{$discoveryError=$_.Exception.Message}}
            if($Cancellation.IsCancellationRequested){return [pscustomobject]@{OK=$true;Cancelled=$true}}
            switch($Kind){
                'Switch'{$result=Set-UniversalProxy $Key}
                'Restore'{$result=Restore-ProxyBackup}
                'ConfigureGateway'{$result=Enable-LocalGateway}
                'Independent'{$result=Enable-IndependentGateway $PID}
                'Discover'{$result=$discovery}
                'AppRoute'{$change=$Key | ConvertFrom-Json;$result=Set-ApplicationRoute $change.path $change.route}
                'ManagedAppRoute'{$change=$Key | ConvertFrom-Json;$result=Set-ManagedApplicationRoute $change.path $change.route}
                'WebsiteRules'{$result=Get-WebsiteRules;$result|Add-Member NoteProperty ContextExecutable $Key -Force}
                'WebsiteRulesSave'{$change=$Key|ConvertFrom-Json;$result=Set-WebsiteRules -Entries @($change.Entries) -ExpectedRevision $change.Revision}
                'AppSync'{$result=Sync-ApplicationRoutes}
                'AppRepairPlan'{$result=Get-ProgramRuleRepairPlan -SavedPath $Key}
                'AppRepair'{$result=Repair-ProgramRule -Plan ($Key|ConvertFrom-Json)}
                'AppRemove'{$result=Remove-SavedProgramRule -SavedPath $Key}
                'AppLaunch'{
                    try{$configured=[bool](Get-ManagedProgramIngress $Key) -or @((Get-ProgramLaunchEntries)|Where-Object {$_.path -ieq $Key}).Count -gt 0}
                    catch{throw '程序线路记录无法读取，目标程序尚未启动。请在流向中修复或恢复本机规则后重试。'}
                    if(-not $configured){throw '此程序的代理入口已移除，请重新设置线路后再打开。'}
                    $result=Start-ManagedProgram $Key
                }
                'AppLaunchRoute'{$change=$Key|ConvertFrom-Json;$result=Set-ProgramLaunchRoute $change.path $change.route}
                'AppEntryRepair'{$result=Repair-ProgramProxyEntry $Key}
                'AppDesktopMode'{$change=$Key|ConvertFrom-Json;$result=Set-ProgramDesktopMode $change.Path $change.Mode $change.Revision}
                'AppReconnectPlan'{$result=Get-ApplicationReconnectPlan $Key}
                'AppReconnect'{$result=Invoke-ApplicationReconnect ($Key | ConvertFrom-Json)}
                'FamilyRoutePlan'{$change=$Key|ConvertFrom-Json;$result=Get-ProgramFamilyRoutePlan -Path $change.Path -Route $change.Route}
                'FamilyRouteApply'{$result=Set-ProgramFamilyRoute -Plan ($Key|ConvertFrom-Json) -Confirmed}
                'CleanStartPlan'{$change=$Key|ConvertFrom-Json;$result=Get-ProgramCleanStartPlan -Path $change.Path -DirectTest ([bool]$change.DirectTest)}
                'CleanStart'{$result=Start-ProgramCleanSession -Plan ($Key|ConvertFrom-Json) -Confirmed}
                'CleanStartStop'{$result=Stop-ProgramCleanSession}
                'LoginDiagnostic'{$result=Test-LoginChain $Key}
                'NetworkDiagnose'{$result=Get-NetworkDiagnosis -Probe}
                'NetworkRepair'{$result=Repair-NetworkDiagnosis $Key}
                'Diagnose'{
                    $result=@()
                    foreach($route in @($Key)){
                        try{$result+=Test-ProxyRoute $route}catch{$result+=[pscustomobject]@{Name=$route;Error=$_.Exception.Message}}
                    }
                }
            }
            # Display failure must never erase a successfully applied operation or its backup.
            try{
                $tcpSnapshot=Get-TcpObservationSnapshot;$tcpRows=$tcpSnapshot.Rows
                $apps=Get-ApplicationRoutes -TcpRows $tcpRows -TcpAvailable $tcpSnapshot.Available
                $state=Get-ProxyStatus $apps -TcpRows $tcpRows -TcpAvailable $tcpSnapshot.Available
                $cleanSession=$null;try{$cleanSession=Get-CleanStartSession}catch{}
                [pscustomobject]@{OK=$true;Kind=$Kind;Result=$result;State=$state;Apps=$apps;Settings=$script:Profiles;Discovery=$discovery;DiscoveryError=$discoveryError;Scanned=($Scan -or $Automatic);Automatic=$Automatic;RefreshError='';CleanSession=$cleanSession}
            }catch{
                if($Kind -eq 'Status' -or $null -eq $result){throw}
                [pscustomobject]@{OK=$true;Kind=$Kind;Result=$result;State=$null;Apps=$null;Settings=$script:Profiles;Discovery=$discovery;DiscoveryError=$discoveryError;Scanned=($Scan -or $Automatic);Automatic=$Automatic;RefreshError='状态刷新失败，请重试；操作结果已保留。'}
            }
        } catch { [pscustomobject]@{OK=$false;Kind=$Kind;Error=$_.Exception.Message} }
    }
    [void]$ps.AddScript($code.ToString()).AddArgument($script:UiRoot).AddArgument($Kind).AddArgument($Key).AddArgument($script:DataRoot).AddArgument($scan).AddArgument($automatic).AddArgument(@($script:DiscoveryCache)).AddArgument($progress).AddArgument($cancellation.Token)
    $script:Worker=[pscustomobject]@{PowerShell=$ps;Handle=$ps.BeginInvoke();Kind=$Kind;Progress=$progress;Started=[DateTime]::Now;Cancellation=$cancellation}
}

# Hide only the window; its message loop, status worker, supervisor and watchdog remain alive.
function Read-WindowPreferences {
    $closeToTray=$true
    try{$value=Get-Content -LiteralPath (Join-Path $script:DataRoot 'ui-settings.json') -Raw -Encoding UTF8|ConvertFrom-Json;if($value.CloseToTray -is [bool]){$closeToTray=$value.CloseToTray}}catch{}
    [pscustomobject]@{CloseToTray=$closeToTray}
}
function Show-FlowWindow {
    $form.ShowInTaskbar=$true;$form.Show();$form.WindowState='Normal';$form.Activate()
    Write-LifecycleEvent 'window-shown' 'user-request'
}
function Request-FlowExit {
    $script:ExitRequested=$true;$form.Close()
}
function Initialize-FlowTray {
    $script:ExitRequested=$false;$script:TrayHintShown=$false;$script:LastLifecycleNotice=''
    $script:WindowPreferences=Read-WindowPreferences
    $script:TrayMenu=New-Object Windows.Forms.ContextMenuStrip
    $script:TrayOpen=$script:TrayMenu.Items.Add('打开主界面');$script:TrayOpen.Add_Click({Show-FlowWindow})
    $script:TrayMode=$script:TrayMenu.Items.Add('关闭窗口后驻留托盘');$script:TrayMode.CheckOnClick=$true;$script:TrayMode.Checked=$script:WindowPreferences.CloseToTray
    $script:TrayMode.Add_CheckedChanged({
        try{Write-LocalJson (Join-Path $script:DataRoot 'ui-settings.json') ([pscustomobject]@{CloseToTray=$script:TrayMode.Checked});$script:WindowPreferences.CloseToTray=$script:TrayMode.Checked}
        catch{Write-Activity '托盘设置保存失败，本次使用原设置。'}
    })
    [void]$script:TrayMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $script:TrayExit=$script:TrayMenu.Items.Add('停止代理服务并退出');$script:TrayExit.Add_Click({Request-FlowExit})
    $script:Tray=New-Object Windows.Forms.NotifyIcon;$script:Tray.Icon=$form.Icon;$script:Tray.ContextMenuStrip=$script:TrayMenu
    $script:Tray.Text='FlowSwitch '+$script:ProductVersion+' · 正在读取状态';$script:Tray.Visible=$true
    $script:Tray.Add_DoubleClick({Show-FlowWindow});$script:Tray.Add_BalloonTipClicked({Show-FlowWindow})
    Write-LifecycleEvent 'window-start' 'tray-ready'
}
function Update-LifecycleNotice {
    if(-not $script:Tray){return}
    $life=Get-GatewayLifecycle;$recovery=$null
    try{$recovery=Get-Content -LiteralPath (Join-Path $script:DataRoot 'gateway\recovery-status.json') -Raw -Encoding UTF8|ConvertFrom-Json}catch{}
    $description='状态读取中';$notice='';$key=''
    if($script:LastState){$description=$(if($script:ObservationStale -or $null -eq $script:LastState.EndpointReady){'入口状态未知'}elseif($script:LastState.Key -eq 'Direct'){'系统直连'}elseif($script:LastState.EndpointReady){'入口可连接'}else{'入口未就绪'})}
    if($script:Profiles.Routing.Adapter -eq 'standalone'){
        if($life.phase -eq 'restarting'){$description='内核恢复中';$notice='内核意外停止，正在限次重启。入口恢复前请暂停登录。';$key='restarting-'+$life.attempt}
        elseif($life.phase -eq 'failed'){$description='内核恢复失败';$notice='内核恢复失败，正在尝试恢复本会话代理设置。已有应用可能保留旧地址；请打开主界面检查，保存工作后重开应用。';$key='failed-'+$life.startedAt}
        elseif($script:LastApps.EffectiveDefaultRoute -eq 'Blocked'){$description='默认代理已暂停';$notice='默认代理出口已暂停。直连网站例外或其他程序线路可能继续可用；不会把全部请求自动切为直连。';$key='blocked'}
        if($recovery.phase -eq 'restore-failed'){$description='设置恢复失败';$notice='网络设置或内核停止尚未通过校验。请打开主界面处理；会话记录已保留，请勿删除数据目录。';$key='restore-failed-'+$recovery.at}
    }
    if($recovery.phase -eq 'restored' -and $life.phase -eq 'failed'){$description='代理设置已恢复';$notice='内核恢复失败后，本会话代理设置已恢复。已运行应用仍可能缓存旧地址，请保存工作后完整重开应用。';$key='restored-'+$recovery.at}
    if(-not $notice -and $script:LastState.EndpointReady -eq $false -and $script:Profiles.Routing.Adapter -eq 'standalone'){$description='固定入口未就绪';$notice='固定入口不可用。请点击「统一切换」或使用程序代理启动入口检查并启动服务。恢复设置不会刷新已有应用缓存的代理地址。';$key='entry-unavailable'}
    $script:Tray.Text='FlowSwitch '+$script:ProductVersion+' · '+$description
    if($notice -and $key -ne $script:LastLifecycleNotice){
        $script:LastLifecycleNotice=$key;Write-Activity $notice
        $script:Tray.ShowBalloonTip(8000,'FlowSwitch 需要关注',$notice,[Windows.Forms.ToolTipIcon]::Warning)
    }
    if(-not $notice){$script:LastLifecycleNotice=''}
}
function Invoke-FlowWindowClose($Event) {
    if($PreviewPath -or $SmokeTest -or $Demo){return}
    if($Event.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing -and -not $script:ExitRequested -and $script:WindowPreferences.CloseToTray){
        $Event.Cancel=$true;$form.Hide();$form.ShowInTaskbar=$false
        Write-LifecycleEvent 'window-hidden' 'tray-resident'
        if(-not $script:TrayHintShown){$script:TrayHintShown=$true;$script:Tray.ShowBalloonTip(5000,'流向仍在后台运行','已启动的代理入口继续运行；服务未启动时可打开窗口选择线路。双击托盘图标可打开；右键可停止代理服务并退出。',[Windows.Forms.ToolTipIcon]::Info)}
        return
    }
    if($script:UpdateProcess){$Event.Cancel=$true;$script:ExitRequested=$false;Show-FlowWindow;Write-Activity '更新检查/暂存尚未结束，请在诊断与工具中取消或等待完成后退出。';return}
    if($script:Worker -and $script:Worker.Kind -ne 'Status'){$Event.Cancel=$true;$script:ExitRequested=$false;Show-FlowWindow;Write-Activity '正在完成网络操作，完成后再停止服务。';return}
    try{
        if($script:UpdateRequested){Prepare-FlowUpdateHandoff}
        if(Test-Path -LiteralPath (Get-IndependentSessionPath)){
            $session=Get-Content -LiteralPath (Get-IndependentSessionPath) -Raw -Encoding UTF8|ConvertFrom-Json
            $ownerState=Get-RecoveryOwnerState $session
            if($session.OwnerPID -eq $PID -and $ownerState -eq 'alive'){Restore-IndependentSession -ExpectedSession $session.Started -GracefulOnly:$script:UpdateRequested}
            elseif($ownerState -eq 'stopped'){Restore-IndependentSession -ExpectedSession $session.Started -AbandonedOnly}
            elseif($ownerState -eq 'unknown'){throw '会话身份无法核实，请先排查网络；旧记录保留。'}
        }
        if($script:UpdateRequested){Complete-FlowUpdateHandoff}
        Write-LifecycleEvent 'window-stop' 'explicit-or-system-close'
    }catch{
        $Event.Cancel=$true;$script:ExitRequested=$false;$script:UpdateRequested=$false;$script:UpdateHandoff=$null;Show-FlowWindow
        Write-Activity ('停止服务尚未完成，窗口与会话记录保留：'+$_.Exception.Message)
        $script:Tray.ShowBalloonTip(8000,'停止服务未完成','请查看主界面恢复结果。尚未确认停止，不会假报已退出。',[Windows.Forms.ToolTipIcon]::Error)
    }
}

function Invoke-PendingUiAction {
    if($script:PendingAction -and -not $script:Worker -and -not $script:DialogOpen -and -not $script:MenuOpen){
        $pending=$script:PendingAction;$script:PendingAction=$null
        Start-Work $pending.Kind $pending.Key
    }
}

$timer=New-Object Windows.Forms.Timer;$timer.Interval=150
$timer.Add_Tick({
    Update-FlowUpdateTick
    if($script:WindowLease -and $script:WindowLease.ConsumeWake()){Show-FlowWindow}
    if($script:WindowLease -and $script:WindowLease.ConsumeExpiredLaunchCount()){
        Write-Activity '启动请求等待已超过 30 秒，程序尚未启动。请等待当前操作完成后，再次打开代理启动入口。';Show-ToolResults
    }
    if($script:WindowLease -and -not $script:Worker -and -not $script:PendingAction -and -not $script:DialogOpen){
        $launchRequest=$script:WindowLease.ConsumeLaunch()
        if($launchRequest){
            try{Assert-ConfiguredLaunchRequest $launchRequest;Start-Work 'AppLaunch' $launchRequest}
            catch{Write-Activity $_.Exception.Message;Show-ToolResults}
        }
    }
    if(-not $script:NextLifePoll -or [DateTime]::UtcNow -ge $script:NextLifePoll){Update-LifecycleNotice;$script:NextLifePoll=[DateTime]::UtcNow.AddSeconds(2)}
    if($script:Worker -and $script:Worker.Kind -ne 'Status'){
        $message='';while($script:Worker.Progress.TryDequeue([ref]$message)){Write-Activity $message}
        $checkedLabel.Text='操作进行中 · '+[int]([DateTime]::Now-$script:Worker.Started).TotalSeconds+' 秒'
    }
    if($script:Worker -and $script:Worker.Handle.IsCompleted){
        $job=$script:Worker;$script:Worker=$null
        try{
            $messages=@($job.PowerShell.EndInvoke($job.Handle))
            $reply=$messages | Select-Object -Last 1
            if(-not $reply){throw '无法取得状态，请重试。'}
            if($reply.Cancelled){}elseif($reply.OK){
                $beforeSettings=$script:Profiles | ConvertTo-Json -Depth 8 -Compress
                $afterSettings=$reply.Settings | ConvertTo-Json -Depth 8 -Compress
                if($beforeSettings -ne $afterSettings -and -not $script:DialogOpen){Reload-ProfileViews $reply.Settings}
                if($reply.Scanned){
                    if($reply.Automatic -and $reply.Discovery){$script:DiscoveryCache=@($reply.Discovery.Cache)}
                    if($reply.DiscoveryError){$script:DiscoveryStatus='检测未完成，可重试';Write-Activity ('后台代理检测：'+$reply.DiscoveryError)}
                    else{
                        $script:DiscoveryStatus='已识别 '+$reply.Discovery.Detected+' 个入口 · '+$reply.Discovery.CheckedAt
                        if($reply.Discovery.Added -or $reply.Kind -eq 'Discover'){Write-Activity ('检测到 '+$reply.Discovery.Detected+' 个入口，新增 '+$reply.Discovery.Added+' 个代理。网络设置未更改。')}
                    }
                }
                if($reply.Kind -in @('Switch','Restore','AppRoute','ManagedAppRoute')){$script:ChoiceDirty=$false}
                if($reply.State -and $reply.Apps){$script:ObservationStale=$false;Show-State $reply.State;Show-Applications $reply.Apps}
                elseif($reply.RefreshError){Mark-ObservationStale;Write-Activity $reply.RefreshError}
                $script:CleanSession=$reply.CleanSession
                if($reply.CleanSession -and $reply.CleanSession.Status){$notice=$reply.CleanSession.Status.Phase+'|'+$reply.CleanSession.Status.Message;if($notice -cne $script:LastCleanStartNotice){$script:LastCleanStartNotice=$notice;Write-Activity $reply.CleanSession.Status.Message}}
                if($reply.Kind -eq 'CleanStartPlan'){Show-CleanStartDialog $reply.Result}
                elseif($reply.Kind -eq 'FamilyRoutePlan'){
                    $plan=$reply.Result;$stateNames=@{Missing='待补齐';Covered='已覆盖';Conflict='保留冲突'};$lines=@('待补齐 '+$plan.MissingCount+' · 已覆盖 '+$plan.CoveredCount+' · 保留冲突 '+$plan.ConflictCount+' · 身份待确认 '+@($plan.UnknownIds).Count);$lines+=@($plan.Members|ForEach-Object {$stateNames[[string]$_.State]+' · '+$_.Path+' · '+$_.Reason});if(@($plan.UnknownIds).Count){$lines+='身份尚未确认的进程不会添加规则；本次操作不代表整组已全部覆盖。'}
                    $script:DialogOpen=$true
                    try{if($plan.CanApply){if([Windows.Forms.MessageBox]::Show($form,($plan.Message+"`r`n`r`n"+($lines -join "`r`n")+"`r`n`r`n只添加已验证且遗漏的成员，已有冲突规则保留。"),'补齐整组程序规则','OKCancel','Information') -eq 'OK'){$script:PendingAction=[pscustomobject]@{Kind='FamilyRouteApply';Key=($plan|ConvertTo-Json -Depth 16 -Compress)}}}else{[void][Windows.Forms.MessageBox]::Show($form,($plan.Message+"`r`n"+($lines -join "`r`n")),'整组程序规则','OK','Information')}}finally{$script:DialogOpen=$false}
                }
                elseif($reply.Kind -eq 'WebsiteRules'){Show-WebsiteRulesEditor $reply.Result}
                elseif($reply.Kind -eq 'AppRepairPlan'){
                    $plan=$reply.Result;$script:DialogOpen=$true
                    try{if([Windows.Forms.MessageBox]::Show($form,($plan.Message+"`r`n`r`n旧路径："+$plan.SavedPath+"`r`n新路径："+$plan.CurrentPath+"`r`n`r`n"+$plan.Impact),'修复程序记录','OKCancel','Information') -eq 'OK'){$script:PendingAction=[pscustomobject]@{Kind='AppRepair';Key=($plan|ConvertTo-Json -Depth 12 -Compress)}}}finally{$script:DialogOpen=$false}
                }
                elseif($reply.Kind -eq 'AppReconnectPlan'){
                    $plan=$reply.Result;$number=@($plan.connections).Count
                    if(-not $number){Write-Activity '没有发现此 EXE 经过引擎的旧线路连接。未接管的连接和独立子程序不会被强制处理。'}
                    else{
                        $script:DialogOpen=$true
                        try{if([Windows.Forms.MessageBox]::Show($form,('将关闭「'+[IO.Path]::GetFileName($plan.path)+'」的 '+$number+' 条旧线路连接，让应用有机会重新连接。进行中的对话、下载或登录可能中断；不会退出应用，也不会关闭其他程序的连接。是否继续？'),'确认重连旧连接','OKCancel','Warning') -eq 'OK'){$script:PendingAction=[pscustomobject]@{Kind='AppReconnect';Key=($plan | ConvertTo-Json -Depth 6 -Compress)}}}finally{$script:DialogOpen=$false}
                    }
                }
                elseif($reply.Kind -eq 'NetworkDiagnose'){$script:NetworkDiagnosis=$reply.Result;Write-Activity $reply.Result.Message;Show-ToolResults}
                elseif($reply.Kind -eq 'NetworkRepair'){$script:NetworkDiagnosis=$reply.Result.Diagnosis;Write-Activity $reply.Result.Message;Show-ToolResults}
                elseif($reply.Kind -eq 'LoginDiagnostic'){Write-Activity ('本次检测：当前系统代理入口。'+$reply.Result.Message+' 浏览器回调是否到达 IDE、IDE 账号是否登录成功尚未验证。');Show-ToolResults}
                elseif($reply.Kind -eq 'Diagnose'){Write-Activity (Format-Diagnostics $reply.Result);Show-ToolResults}
                elseif($reply.Kind -notin @('Status','Discover')){
                    Write-Activity $reply.Result.Message
                    if($reply.Result.Backup){
                        if($reply.Kind -eq 'AppDesktopMode'){$logBox.AppendText("`r`n桌面入口已保存。解除绑定请在启动方式选择「仅在流向内打开」；线路保留。")}
                        elseif($reply.Kind -eq 'Independent'){$logBox.AppendText("`r`n独立入口迁移备份已保留；请按恢复说明处理服务和设置。")}
                        elseif($reply.Kind -in @('Switch','AppRoute','ManagedAppRoute','AppLaunchRoute')){$logBox.AppendText("`r`n线路切换前配置已保存，可用「撤回线路更改」恢复。")}
                    }
                    if($reply.Result.Test){$logBox.AppendText("`r`n" + (Format-Diagnostics @($reply.Result.Test)))}
                    if($reply.State.Warnings.Count){$logBox.AppendText("`r`n" + ($reply.State.Warnings -join "`r`n"))}
                }
            }else{throw $reply.Error}
        }catch{
            Write-Activity $_.Exception.Message
            Mark-ObservationStale
            if($job.Kind -ne 'Status'){Show-ToolResults}
        }
        finally{$job.PowerShell.Dispose();$job.Cancellation.Dispose();foreach($b in $script:Controls){$b.Enabled=$true};Set-UiActionAvailability;$script:NextPoll=[DateTime]::Now.AddSeconds(5)}
        if($SmokeTest){
            $brandProperties=@{5=[FlowSwitchDesktop]::AppId}
            if($script:TaskbarRelaunchReady){$brandProperties[4]='流向 · FlowSwitch';$brandProperties[3]=$iconPath+',0';$brandProperties[2]=$desktopCommand}
            foreach($propertyId in $brandProperties.Keys){
                if([FlowSwitchDesktop]::ReadWindowProperty($form.Handle,[uint32]$propertyId) -cne $brandProperties[$propertyId]){$script:SmokeFailed=$true}
            }
            if($desktopCommand -notlike ('*'+$script:DataRoot.TrimEnd('\')+'*')){$script:SmokeFailed=$true}
            $searchBox.Text='__no_match_proxy_switch__'
            if($liveList.Items.Count -ne 0){$script:SmokeFailed=$true}
            $searchBox.Clear();$savedOnly.Checked=$true
            if(@($liveList.Items | Where-Object {$_.Tag.Policy -eq 'Follow'}).Count){$script:SmokeFailed=$true}
            $savedOnly.Checked=$false
            $expected=@((Read-ProfileSettings).Profiles).Count
            if(-not $script:LastState -or $networkChoice.Items.Count -ne ($expected+1-$(if($script:Profiles.Routing.Adapter -eq 'standalone'){1}else{0})) -or @($script:LastState.Listeners).Count -ne $expected){$script:SmokeFailed=$true}
            $form.Close();return
        }
    }
    Invoke-PendingUiAction
    if(-not $script:Worker -and -not $script:MenuOpen -and -not $script:DialogOpen -and $autoRefresh.Checked -and [DateTime]::Now -ge $script:NextPoll){Start-Work 'Status' ''}
})
$form.Add_FormClosing({Invoke-FlowWindowClose $_})
$form.Add_FormClosed({
    if($script:Tray){$script:Tray.Visible=$false;$script:Tray.Dispose();$script:TrayMenu.Dispose()}
    if($script:WindowLease){$script:WindowLease.Dispose();$script:WindowLease=$null}
    $timer.Stop();$uiTips.Dispose();$appMenu.Dispose();$routeMenu.Dispose();$proxyServiceMenu.Dispose();$proxyMoreMenu.Dispose()
    if($script:Worker){$script:Worker.Cancellation.Cancel();$script:Worker.PowerShell.Stop();$script:Worker.PowerShell.Dispose();$script:Worker.Cancellation.Dispose();$script:Worker=$null}
    $timer.Dispose()
})
$navigation=@()
foreach($nav in @(@('程序线路',0,300),@('代理入口',1,356),@('检查与维护',2,412),@('网络切换',3,244))){
    $navButton=New-Button $sidebar $nav[0] 14 $nav[2] 152 44 {$tabs.SelectedIndex=[int]$this.Tag}
    $navButton.Tag=$nav[1];$navButton.Navigation=$true;$navButton.Glyph=[int]$nav[1];$navButton.BackColor=$sidebar.BackColor;$navigation+=$navButton
}
function Update-WorkspaceNavigation {
    foreach($n in $navigation){$n.Selected=([int]$n.Tag -eq $tabs.SelectedIndex);$n.Invalidate()}
    $brand.Text=$tabs.SelectedTab.Text
    $tagline.Text=@('选中程序 → 设置线路 → 按此线路打开。','先运行代理软件，再登记和检测它的入口。','先检查，再处理问题；每项操作都说明影响范围。','准备代理入口，再决定统一切换还是单独分流。')[$tabs.SelectedIndex]
}
function Set-UiActionAvailability {
    $busy=($script:Worker -and $script:Worker.Kind -ne 'Status')
    $app=$null;if($liveList.SelectedItems.Count){$app=$liveList.SelectedItems[0].Tag}
    $valid=($app -and $app.Path -and -not $app.RequiresRepair)
    $routeButton.Enabled=($valid -and -not $busy);$programMoreButton.Enabled=([bool]$app -and -not $busy);$detail.Enabled=([bool]$app -and -not $busy)
    $running=($app -and (@($app.PIDs|Where-Object {$_}).Count -gt 0 -or [bool]$app.Running))
    $programLaunchButton.Enabled=($valid -and [bool]$app.CanLaunch -and -not $running -and -not $busy)
    if($app){
        $programSelectionLabel.Text=$app.Name+'  ·  '+$app.Path;$uiTips.SetToolTip($programSelectionLabel,$programSelectionLabel.Text)
        if($app.RequiresRepair){$programHint.Text='程序路径已变化：请在「更多设置」修复路径记录，再更改线路。'}
        elseif($running -and $app.CanLaunch){$programHint.Text='所选程序正在运行。新连接按已保存线路生效；如保留旧代理，先保存工作并正常退出，再按此线路打开。'}
        elseif(-not $app.CanLaunch){$programHint.Text='先设置此程序线路以创建可用入口；桌面绑定是可选项。实际连接只展示当前 TCP 观察。'}
        else{$programHint.Text='仅更改所选程序；按此线路打开会检查入口就绪。桌面绑定与网站例外在更多设置中。'}
    }else{$programSelectionLabel.Text='先从列表选择一个程序';$programHint.Text='可搜索或添加 EXE / 快捷方式。空闲时未观察到 TCP 连接不代表断网。'}
    $profile=$null;if($proxyList.SelectedItems.Count){$profile=$proxyList.SelectedItems[0].Tag}
    foreach($button in @($proxyEditButton,$proxyProbeButton,$proxyMoreButton)){$button.Enabled=([bool]$profile -and -not $busy)}
    $proxyOpenButton.Enabled=([bool]$profile -and [bool]$profile.AppPath -and -not $busy)
    $proxySelectionLabel.Text=$(if($profile){$profile.Name+'  ·  '+$profile.Protocol.ToUpperInvariant()+' '+$profile.Host+':'+$profile.Port}else{'先选择一个代理入口；编辑和检测只作用于选中项'})
    $probeButton.Enabled=([bool]$diagnosticChoice.SelectedItem -and -not $busy)
    $networkRepairButton.Enabled=([bool]$script:NetworkDiagnosis.RepairAction -and -not $busy)
    $cleanStopButton.Enabled=([bool]$script:CleanSession -and -not $busy)
    $failoverItem.Enabled=($script:Profiles.Routing.Adapter -eq 'standalone' -and -not $busy)
}
$proxyList.Add_SelectedIndexChanged({Set-UiActionAvailability});$diagnosticChoice.Add_SelectedIndexChanged({Set-UiActionAvailability})
$tabs.Add_SelectedIndexChanged({Update-WorkspaceNavigation;Set-UiActionAvailability})
Update-WorkspaceNavigation
if(-not $PreviewPath -and -not $Demo -and -not $SmokeTest){$tabs.SelectedIndex=3}
$form.Add_Shown({if($tabs.SelectedIndex -lt 0){$tabs.SelectedIndex=3};Update-WorkspaceNavigation;Set-UiActionAvailability;if($PreviewPath){$navigation[$tabs.SelectedIndex].Focus()}})
[FlowSwitch.UI.Palette]::Apply($form)
$shellLayout.RowStyles.Clear();[void]$shellLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
foreach($grid in @($layout,$programGrid,$proxyGrid,$toolsGrid)){
    $grid.ColumnStyles.Clear();[void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
}
$networkChoice.FlatStyle='Flat'
$liveList.SetColumnWeights([double[]]@(0.21,0.19,0.30,0.30))
$proxyList.SetColumnWeights([double[]]@(0.22,0.10,0.23,0.09,0.15,0.21))
if($Demo){Set-DemoCatalog}
Reload-ProfileViews
if($PreviewPath){
    if($PreviewView -eq 'Home'){$tabs.SelectedTab=$homePage}
    if($PreviewView -in @('Settings','Proxies')){$tabs.SelectedTab=$proxyPage}
    if($Demo){Show-State (Get-DemoState);Show-Applications (Get-DemoApps);$checkedLabel.Text='演示数据 · 展示界面用法'}else{Show-State (Get-ProxyStatus);Show-Applications (Get-ApplicationRoutes)}
    if($PreviewView -eq 'Tools'){Show-ToolResults;Write-Activity '可检测所选代理、重载程序规则或导出匿名诊断报告。'}
    $form.Opacity=0;$form.ShowInTaskbar=$false;$form.Show()
    [Windows.Forms.Application]::DoEvents();$form.PerformLayout()
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try{
        $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
        if($PreviewMenu -and $liveList.Items.Count){
            $script:AppTarget=$liveList.Items[0].Tag
            $appMenu.Show($liveList,(New-Object Drawing.Point(260,30)))
            [Windows.Forms.Application]::DoEvents()
            $appMenu.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(505,470,$appMenu.Width,$appMenu.Height)))
            $appMenu.Close()
        }
        $bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png)
    }
    finally{$bitmap.Dispose();$form.Close();$form.Dispose()}
    return
}
if($SmokeTest){$form.Opacity=0;$form.ShowInTaskbar=$false}
Write-Activity '关闭窗口默认驻留系统托盘；停止服务后，已运行应用可能仍需重开。自动发现代理与程序连接观察已开启；发现结果只补充代理列表，不改系统入口或程序规则。'
# Passive opening never starts or reclaims a gateway. Explicit switching and
# managed launch requests start the service through their guarded worker paths.
if(-not $SmokeTest -and -not $Demo){Initialize-FlowTray}
$timer.Start();[Windows.Forms.Application]::Run($form);$form.Dispose()
if($SmokeTest){if($script:SmokeFailed){throw 'UI worker smoke test failed'};Write-Output 'PASS: UI background status worker completed.'}

$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'ProxyWindow.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw 'Window source parse failed'}
foreach($name in @('Test-FlowWindowObservationActive','Invoke-AutomaticUiRefresh','Invoke-PendingUiAction')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:checks=0;$script:starts=@()
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++}
function Start-Work([string]$Kind,[string]$Key){$script:starts+=@($Kind);$script:Worker=[pscustomobject]@{Kind=$Kind;Handle=[pscustomobject]@{IsCompleted=$false}}}
$form=[pscustomobject]@{Visible=$false;WindowState='Normal'};$autoRefresh=[pscustomobject]@{Checked=$true}
$script:Worker=$null;$script:NextPoll=[DateTime]::MinValue;$script:DialogOpen=$false;$script:MenuOpen=$false;$script:PendingAction=$null
1..100|ForEach-Object {Invoke-AutomaticUiRefresh}
Check ($script:starts.Count -eq 0 -and $script:ObservationPaused -and $script:ObservationStale) 'hidden window still schedules full status or automatic discovery'
$form.Visible=$true;$form.WindowState='Minimized'
1..100|ForEach-Object {Invoke-AutomaticUiRefresh}
Check ($script:starts.Count -eq 0 -and -not (Test-FlowWindowObservationActive)) 'minimized window still schedules full status'
$form.WindowState='Normal';$autoRefresh.Checked=$false;Invoke-AutomaticUiRefresh
Check ($script:starts.Count -eq 1 -and $script:starts[0] -eq 'Status' -and -not $script:ObservationPaused) 'restore does not immediately request fresh status when ordinary periodic refresh is disabled'
$activeWorker=$script:Worker;$form.Visible=$false;Invoke-AutomaticUiRefresh
Check ([object]::ReferenceEquals($script:Worker,$activeWorker)) 'hiding cancelled or replaced an in-flight worker'
$script:PendingAction=[pscustomobject]@{Kind='NetworkDiagnose';Key=''};Invoke-PendingUiAction
Check ($script:PendingAction -and $script:starts.Count -eq 1) 'queued explicit action did not wait for running worker'
$script:Worker=$null;Invoke-PendingUiAction
Check (-not $script:PendingAction -and $script:starts[-1] -eq 'NetworkDiagnose') 'hidden window dropped explicit pending action'
$script:Worker=$null;$form.Visible=$true;$script:DialogOpen=$true;Invoke-AutomaticUiRefresh
Check ($script:ResumeObservation -and $script:starts.Count -eq 2) 'restore bypassed open dialog or lost queued refresh'
$script:DialogOpen=$false;Invoke-AutomaticUiRefresh
Check ($script:starts.Count -eq 3 -and $script:starts[-1] -eq 'Status') 'restored window did not refresh once dialog closed'

# Execute the actual timer body with no form, process, Windows settings or network.
$tick=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$timer' -and $n.Member.Extent.Text -eq 'Add_Tick'},$true)
$body=[scriptblock]::Create($tick.Arguments[0].ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}'))
$script:updateTicks=0;$script:lifeTicks=0;$script:wakeReads=0;$script:launchReads=0;$script:shows=0
function Update-FlowUpdateTick {$script:updateTicks++}
function Update-LifecycleNotice {$script:lifeTicks++}
function Show-FlowWindow {$script:shows++;$form.Visible=$true;$form.WindowState='Normal';$script:ResumeObservation=$true}
function Assert-ConfiguredLaunchRequest($Request) {}
function Show-ToolResults {}
function Write-Activity($Message) {}
$lease=New-Object PSObject
$lease|Add-Member ScriptMethod ConsumeWake {$script:wakeReads++;$false}
$lease|Add-Member ScriptMethod ConsumeExpiredLaunchCount {0}
$lease|Add-Member ScriptMethod ConsumeLaunch {$script:launchReads++;$null}
$script:WindowLease=$lease;$script:Worker=$null;$script:PendingAction=$null;$script:NextLifePoll=[DateTime]::MinValue;$script:NextPoll=[DateTime]::MinValue;$autoRefresh.Checked=$true;$form.Visible=$false
& $body
Check ($script:updateTicks -eq 1 -and $script:lifeTicks -eq 1 -and $script:wakeReads -eq 1 -and $script:launchReads -eq 1 -and $script:starts.Count -eq 3) 'paused timer disabled update/lifecycle/wake/launch handling or started status'
$lease|Add-Member ScriptMethod ConsumeWake {$script:wakeReads++;$true} -Force
& $body
Check ($script:shows -eq 1 -and $script:starts.Count -eq 4 -and $script:starts[-1] -eq 'Status') 'wake signal failed to show window and schedule fresh status'

# The Start-Work dispatcher must gate discovery at the UI side, not in safety workers.
$dispatcher=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-Work'},$true)
$automaticAssignment=$dispatcher.Body.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$automatic'},$true)
$Kind='Status';$SmokeTest=$false;$autoDiscovery=[pscustomobject]@{Checked=$true};$form.Visible=$false
. ([scriptblock]::Create($automaticAssignment.Extent.Text))
Check (-not $automatic) 'explicit status while hidden still starts automatic discovery'
$form.Visible=$true;$form.WindowState='Normal';. ([scriptblock]::Create($automaticAssignment.Extent.Text))
Check $automatic 'visible automatic status lost existing discovery behavior'
$notice=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-LifecycleNotice'},$true)
. ([scriptblock]::Create($notice.Extent.Text))
$script:DataRoot=Join-Path $env:TEMP ('FlowSwitch-PausedLifecycle-'+[Guid]::NewGuid().ToString('N'))
$script:Tray=New-Object PSObject -Property @{Text=''};$script:balloons=0
$script:Tray|Add-Member ScriptMethod ShowBalloonTip {param($Delay,$Title,$Text,$Icon);$script:balloons++}
$script:Profiles=[pscustomobject]@{Routing=[pscustomobject]@{Adapter='standalone'}};$script:ProductVersion='fixture'
$script:LastState=[pscustomobject]@{EndpointReady=$false;Key='owned'};$script:LastApps=[pscustomobject]@{EffectiveDefaultRoute='Blocked'}
$script:ObservationPaused=$true;$script:ObservationStale=$true;$script:life=[pscustomobject]@{phase='ready'}
function Get-GatewayLifecycle {$script:life}
Update-LifecycleNotice
Check ($script:Tray.Text -match '观察已暂停' -and $script:balloons -eq 0) 'stale entry/default snapshots produced a current tray failure or health claim'
Add-Type -AssemblyName System.Windows.Forms
$script:life.phase='failed';Update-LifecycleNotice
Check ($script:balloons -eq 1 -and $script:Tray.Text -match '内核恢复失败') 'fresh lifecycle failure notification was suppressed while window observation paused'
Write-Output ('PASS: '+$script:checks+' tray observation scheduling checks; actual timer/dispatcher AST with isolated UI and worker stubs only.')

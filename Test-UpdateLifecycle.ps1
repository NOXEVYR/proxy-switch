$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$qa=Join-Path $env:TEMP ('FlowSwitch-update-close-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($qa)
$script:DataRoot=$qa;$script:Checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:Checks++}
function Import-Function($File,$Name){$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $File),[ref]$t,[ref]$e);$fn=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $Name},$true);if(-not $fn){throw $Name};return $fn.Extent.Text}
Invoke-Expression (Import-Function 'ProxyWindow.ps1' 'Invoke-FlowWindowClose')
Invoke-Expression (Import-Function 'Updates.ps1' 'Assert-FlowUpdateIdle')
function Get-CleanStartSession {$null}
function Get-IndependentSessionPath {Join-Path $qa 'gateway-session.json'}
function Get-RecoveryOwnerState {'alive'}
function Show-FlowWindow {$form.Show()}
function Write-Activity($Text){$script:Activity=$Text}
function Write-LifecycleEvent {}
function Prepare-FlowUpdateHandoff {Assert-FlowUpdateIdle;$script:Prepared++}
function Complete-FlowUpdateHandoff {$script:Committed++}
function Restore-IndependentSession {param($ExpectedSession,[switch]$GracefulOnly);Check $GracefulOnly.IsPresent 'update must request graceful recovery';if($script:FailRestore){throw 'simulated settings restoration failure'}}
$session=[pscustomobject]@{OwnerPID=$PID;Started='isolated'};$session|ConvertTo-Json|Set-Content (Get-IndependentSessionPath) -Encoding UTF8
$form=New-Object Windows.Forms.Form;$script:Tray=New-Object Windows.Forms.NotifyIcon
$script:WindowPreferences=[pscustomobject]@{CloseToTray=$true};$script:Prepared=0;$script:Committed=0
try{
    $script:ExitRequested=$true;$script:UpdateRequested=$true;$script:FailRestore=$true
    $event=New-Object Windows.Forms.FormClosingEventArgs([Windows.Forms.CloseReason]::UserClosing,$false)
    Invoke-FlowWindowClose $event
    Check ($event.Cancel -and $form.Visible -and -not $form.IsDisposed) 'restore failure retains visible window'
    Check ($script:Committed -eq 0 -and (Test-Path (Get-IndependentSessionPath))) 'restore failure never commits install or removes session'
    Check (-not $script:UpdateRequested -and -not $script:ExitRequested -and $script:Activity -match '尚未完成') 'failure clears exit intent and reports unfinished state'
    $script:FailRestore=$false;$script:ExitRequested=$true;$script:UpdateRequested=$true
    $event=New-Object Windows.Forms.FormClosingEventArgs([Windows.Forms.CloseReason]::UserClosing,$false);Invoke-FlowWindowClose $event
    Check (-not $event.Cancel -and $script:Committed -eq 1) 'successful stop permits update handoff'
    foreach($flag in 'DialogOpen','MenuOpen','ChoiceDirty','PendingAction'){
        Set-Variable -Scope Script -Name $flag -Value $true
        $blocked=$false;try{Assert-FlowUpdateIdle}catch{$blocked=$true};Check $blocked ($flag+' blocks install');Set-Variable -Scope Script -Name $flag -Value $false
    }
    $script:UpdateProcess=[pscustomobject]@{Active=$true};$event=New-Object Windows.Forms.FormClosingEventArgs([Windows.Forms.CloseReason]::UserClosing,$false);Invoke-FlowWindowClose $event
    Check $event.Cancel 'active download blocks explicit exit'
    # A cancelled/failed second check must not leave a Cancel caption on a staged install action.
    Invoke-Expression (Import-Function 'Updates.ps1' 'Update-FlowUpdateTick')
    $updateButton=New-Object Windows.Forms.Button;$script:UpdateUiReady=$true;$script:UpdateNextTick=[DateTime]::UtcNow.AddDays(1)
    foreach($phase in @('cancelled','current','failed')){
        foreach($readyPhase in @('staged','consent-required','')){
            $script:UpdateReady=$(if($readyPhase){[pscustomobject]@{phase=$readyPhase}}else{$null})
            $process=[pscustomobject]@{HasExited=$true;Disposed=$false};$process|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
            $script:UpdateProcess=[pscustomobject]@{Process=$process;Out=[pscustomobject]@{Result=('{"phase":"'+$phase+'","reason":"fixture"}')};Manual=$true}
            $updateButton.Text='取消检查/暂存';Update-FlowUpdateTick
            $expected=$(if($readyPhase -eq 'staged'){'安装更新…'}elseif($readyPhase -eq 'consent-required'){'下载更新…'}else{'检查更新'})
            Check ($null -eq $script:UpdateProcess -and $process.Disposed -and $updateButton.Text -ceq $expected) ($phase+' recomputes the caption for '+$readyPhase)
        }
    }
    $updateButton.Dispose()
    Write-Output ('PASS: '+$script:Checks+' update close/UI checks; restoration simulated, no network writes.')
}finally{$form.Dispose();$script:Tray.Dispose()}

param([string]$DataDirectory,[switch]$RecoverOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $DataDirectory
$path=Get-IndependentSessionPath
function Read-WatchdogSession([string]$Path) {
    # An exclusive journal claim is a temporary unknown, never proof of exit.
    for($readAttempt=0;$readAttempt -lt 3;$readAttempt++){
        try{
            $value=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json
            if(-not $value.Started -or -not $value.OwnerPID -or -not $value.OwnerStart -or -not $value.TargetSystem){throw 'Incomplete session'}
            return [pscustomobject]@{State='Ready';Session=$value}
        }catch [IO.FileNotFoundException]{return [pscustomobject]@{State='Missing';Session=$null}}
        catch [IO.DirectoryNotFoundException]{return [pscustomobject]@{State='Missing';Session=$null}}
        catch{if($readAttempt -lt 2){Start-Sleep -Milliseconds 150}}
    }
    [pscustomobject]@{State='Unknown';Session=$null}
}
$readWarning=$false
while($true){
    $reading=Read-WatchdogSession $path
    if($reading.State -eq 'Missing'){return}
    if($reading.State -eq 'Ready'){$session=$reading.Session;break}
    if(-not $readWarning){Write-LifecycleEvent 'watchdog-session-pending' 'journal-unavailable-unknown';$readWarning=$true}
    Start-Sleep -Milliseconds 500
}
if($RecoverOnly){
    # A delayed next-logon recovery must not terminate a fresh, live UI session.
    for($attempt=1;$attempt -le 3;$attempt++){
        if((Get-RecoveryOwnerState $session) -ne 'stopped'){Write-LifecycleEvent 'recovery-skipped' 'owner-alive-or-unknown';return}
        try{Restore-IndependentSession -ExpectedSession $session.Started -AbandonedOnly;return}catch{
            Write-LifecycleEvent 'logon-restore-failed' 'restore-retry' $attempt
            if($attempt -eq 3){Write-LifecycleEvent 'logon-recovery-exhausted' 'manual-action-required';throw}
            Start-Sleep -Seconds ([Math]::Pow(2,$attempt-1))
        }
    }
    return
}
Write-LocalJson (Join-Path $script:DataRoot 'gateway\watchdog-ready.json') ([pscustomobject]@{PID=$PID;StartTicks=(Get-ProcessStartTicks $PID);Session=$session.Started})
$misses=0;$restoreAttempts=0;$missingSince=$null
while($true){
    $reading=Read-WatchdogSession $path
    if($reading.State -eq 'Missing'){return}
    if($reading.State -eq 'Unknown'){
        if(-not $readWarning){Write-LifecycleEvent 'watchdog-session-pending' 'journal-unavailable-unknown';$readWarning=$true}
        Start-Sleep -Milliseconds 500;continue
    }
    $current=$reading.Session
    if($current.Started -ne $session.Started){return}
    $session=$current;$readWarning=$false
    # Failure to read process identity is not proof that the UI has exited.
    $alive=(Get-RecoveryOwnerState $session) -ne 'stopped'
    $listener=Test-RecoveryEndpoint $session.TargetSystem.Server
    if($session.SupervisorPID -and (Get-RecoveryOwnerState ([pscustomobject]@{OwnerPID=$session.SupervisorPID;OwnerStart=$session.SupervisorStart})) -eq 'stopped'){$listener=$false}
    if(-not $listener){$misses++;if(-not $missingSince){$missingSince=[DateTime]::UtcNow}}else{$misses=0;$missingSince=$null}
    $grace=Test-GatewayRecoveryGrace $session $misses
    if($missingSince -and ([DateTime]::UtcNow-$missingSince).TotalSeconds -ge 45){$grace=$false}
    if(-not $alive -or ($misses -ge 2 -and -not $grace)){
        Write-LifecycleEvent 'watchdog-recovery' $(if(-not $alive){'owner-exited'}else{'entry-unavailable'})
        try{Restore-IndependentSession -ExpectedSession $session.Started;return}catch{
            $restoreAttempts++;Write-LifecycleEvent 'watchdog-restore-failed' 'restore-retry' $restoreAttempts
            if($restoreAttempts -ge 3){Write-LifecycleEvent 'watchdog-recovery-exhausted' 'manual-action-required';return}
            Start-Sleep -Seconds ([Math]::Pow(2,$restoreAttempts-1));continue
        }
    }
    Start-Sleep -Seconds 1
}

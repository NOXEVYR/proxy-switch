$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FSCW-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($qa)
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory (Join-Path $qa 'initial')
$script:Checks=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
$harness=Join-Path $qa 'worker';[void][IO.Directory]::CreateDirectory($harness)
$workerSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'CleanStartWorker.ps1')).Replace('Local\FlowSwitch-CleanStart-','Local\FlowSwitch-Test-CleanStart-'+[Guid]::NewGuid().ToString('N')+'-')
[IO.File]::WriteAllText((Join-Path $harness 'CleanStartWorker.ps1'),$workerSource,(New-Object Text.UTF8Encoding($true)))
$backendPath=(Join-Path $PSScriptRoot 'ProxyBackend.ps1').Replace("'","''")
$backend=@'
param([string]$DataDirectory)
. '__BACKEND__' -DataDirectory $DataDirectory
$script:Root=$PSScriptRoot
function Get-CleanStartRecoveryRoot {Join-Path $script:DataRoot 'r'}
function Get-SystemSnapshot {Get-Content -LiteralPath (Join-Path $script:DataRoot 'system.json') -Raw -Encoding UTF8|ConvertFrom-Json}
function Get-CleanStartSystemSnapshot {Get-SystemSnapshot}
function Get-CleanStartRestoreEndpointState([string]$Endpoint){if([IO.File]::Exists((Join-Path $script:DataRoot 'endpoint-dead'))){return 'dead'};return 'live'}
function Set-SystemSnapshot($Snapshot){
    if(-not $script:FixtureLock){throw 'Fixture Windows write outside change lock'}
    Write-LocalJson (Join-Path $script:DataRoot 'system.json') $Snapshot
    [IO.File]::AppendAllText((Join-Path $script:DataRoot 'writes'),([string]$Snapshot.Flags+"`r`n"))
}
function Set-UserProxyEnv {throw 'Persistent environment writes forbidden'}
function Invoke-AppRouter {throw 'Real routing engine access forbidden'}
function Use-ChangeLock([scriptblock]$Action){
    $key=Get-RuleMaintenanceHash ([Text.Encoding]::UTF8.GetBytes($script:DataRoot))
    $mutex=New-Object Threading.Mutex($false,('Local\FlowSwitch-Test-CleanChange-'+$key));$held=$false
    try{try{$held=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$held=$true};if(-not $held){throw 'Fixture lock timeout'};$script:FixtureLock=$true;& $Action}
    finally{$script:FixtureLock=$false;if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Register-CleanStartRecovery($Registration){
    if($Registration.Command.Length -gt 260 -or (Read-RuleMaintenanceFile $Registration.StubPath).Hash -cne $Registration.StubHash){throw 'Invalid recovery entry'}
    Write-LocalJson (Join-Path $script:DataRoot 'runonce.json') $Registration
}
function Remove-CleanStartRecovery($Registration){if([IO.File]::Exists((Join-Path $script:DataRoot 'runonce.json'))){[IO.File]::Delete((Join-Path $script:DataRoot 'runonce.json'))}}
function Start-Sleep {param($Milliseconds,$Seconds)
    if($Mode -eq 'Monitor' -and [IO.File]::Exists((Join-Path $script:DataRoot 'hang')) -and $Milliseconds -eq 400){
        [IO.File]::WriteAllText((Join-Path $script:DataRoot 'hung'),'hung');$limit=[DateTime]::UtcNow.AddSeconds(30)
        while(-not [IO.File]::Exists((Join-Path $script:DataRoot 'release-monitor')) -and [DateTime]::UtcNow -lt $limit){[Threading.Thread]::Sleep(25)};return
    }
    if($Seconds){[Threading.Thread]::Sleep([int]($Seconds*1000))}else{[Threading.Thread]::Sleep([int]$Milliseconds)}
}
$script:OriginalFixtureWriter=${function:Write-LocalJson}
function Write-LocalJson($Path,$Value){
    if($Value.Phase -eq 'starting' -and [IO.File]::Exists((Join-Path $script:DataRoot 'fail-starting'))){
        $session=(Get-Content (Join-Path $script:DataRoot 'clean-start-current.json') -Raw|ConvertFrom-Json).Id
        $proof=Join-Path $script:DataRoot ('clean-start\'+$session+'\launched.json');$limit=[DateTime]::UtcNow.AddSeconds(10)
        while(-not [IO.File]::Exists($proof) -and [DateTime]::UtcNow -lt $limit){[Threading.Thread]::Sleep(25)}
        throw 'Fixture status write failed after target launch'
    }
    & $script:OriginalFixtureWriter $Path $Value
}
'@
[IO.File]::WriteAllText((Join-Path $harness 'ProxyBackend.ps1'),$backend.Replace('__BACKEND__',$backendPath),(New-Object Text.UTF8Encoding($true)))
$fixture=Join-Path $qa 'CleanWorkerFixture.exe'
$source=@'
using System;using System.IO;
public static class CleanWorkerFixture {
 public static void Main(){File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"launches"),DateTime.UtcNow.Ticks+Environment.NewLine);}
}
'@
Add-Type -TypeDefinition $source -OutputAssembly $fixture -OutputType WindowsApplication
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Wait-Condition([scriptblock]$Condition,[string]$Message,[int]$Seconds=20){$until=[DateTime]::UtcNow.AddSeconds($Seconds);do{if(& $Condition){return};Start-Sleep -Milliseconds 80}while([DateTime]::UtcNow -lt $until);throw $Message}
function New-FixtureSession([string]$Name,[int]$Duration=4,[int]$BeforeFlags=3){
    $data=Join-Path $qa $Name;[void][IO.Directory]::CreateDirectory($data)
    $before=[pscustomobject]@{Flags=$BeforeFlags;Server='127.0.0.1:19001';Bypass='fixture';AutomaticConfigFingerprint='fixture-pac'}
    Write-LocalJson (Join-Path $data 'system.json') $before
    $prior=$script:DataRoot;$script:DataRoot=$data
    try{
        $identity=Get-ProgramIdentityDescriptor $fixture (New-ProgramIdentityContext)
        $plan=[pscustomobject]@{Version=1;Path=$fixture;FileId=$identity.FileId;CanonicalPath=$identity.CanonicalPath;Revision=(Get-RuleMaintenanceSnapshot $fixture).Fingerprint;CreatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();DirectTest=$true;Elevate=$false;DurationSeconds=$Duration;System=$before}
    }finally{$script:DataRoot=$prior}
    $id=[Guid]::NewGuid().ToString('N');$directory=Join-Path $data ('clean-start\'+$id);[void][IO.Directory]::CreateDirectory($directory)
    Write-LocalJson (Join-Path $data 'clean-start-current.json') @{Id=$id}
    Write-LocalJson (Join-Path $directory 'request.json') @{Version=1;Id=$id;UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Plan=$plan;DataDirectory=$data;CreatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()}
    [pscustomobject]@{Data=$data;Id=$id;Directory=$directory;Before=$before;Process=$null}
}
function Start-FixtureMonitor($Session){
    $arguments='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-ProgramArgument (Join-Path $harness 'CleanStartWorker.ps1'))+' -DataDirectory '+(ConvertTo-ProgramArgument $Session.Data)+' -SessionId '+$Session.Id
    $Session.Process=Start-Process -FilePath $shell -WindowStyle Hidden -ArgumentList $arguments -PassThru
    $Session
}
function Read-FixtureStatus($Session){
    $path=Join-Path $Session.Directory 'status.json'
    if(-not [IO.File]::Exists($path)){return}
    for($attempt=0;$attempt -lt 6;$attempt++){
        try{return (Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json)}
        catch [IO.IOException]{
            # Concurrent atomic status replacement can briefly deny the reader.
            # Retry sharing/lock violations for at most 125 ms; all other failures
            # and invalid JSON still fail the test. The 20-second wait stays unchanged.
            if(($_.Exception.HResult -band 0xffff) -notin @(32,33) -or $attempt -eq 5){throw}
            [Threading.Thread]::Sleep(25)
        }
    }
}
function Stop-OwnedMonitor($Session){if($Session.Process){try{if(-not $Session.Process.HasExited){$Session.Process.Kill();[void]$Session.Process.WaitForExit(5000)}}finally{$Session.Process.Dispose()}}}
$sessions=@()
try{
    $normal=Start-FixtureMonitor (New-FixtureSession 'normal');$sessions+=@($normal)
    Wait-Condition {([IO.File]::Exists((Join-Path $normal.Directory 'recovery-done')))} 'Normal monitor/child/guard did not finish'
    $status=Read-FixtureStatus $normal
    Check ($status.LaunchOutcome -eq 'started' -and $status.RestoreOutcome -eq 'restored' -and $status.Phase -eq 'complete') 'Real isolated monitor and child launch, then restore through the shared Windows-write stub'
    Check ((Get-Content (Join-Path $normal.Data 'system.json') -Raw|ConvertFrom-Json).Flags -eq 3) 'Normal deadline restores the prior settings'
    Check ([IO.File]::Exists((Join-Path $normal.Directory 'guard-ready.json')) -and -not [IO.File]::Exists((Join-Path $normal.Data 'runonce.json'))) 'Real guard became ready before direct mode and completed registration is removed'
    $recovery=Get-Content (Join-Path $normal.Directory 'recovery.json') -Raw|ConvertFrom-Json
    Check ($recovery.Registration.Command.Length -le 260 -and $recovery.Registration.Name.StartsWith('!')) 'Persistent recovery command fits Windows RunOnce bounds and defers deletion'

    foreach($case in @(@{Name='dead-entry';Before=3;Expected=1},@{Name='dead-entry-auto';Before=7;Expected=5})){
        $fallback=New-FixtureSession $case.Name 6 $case.Before
        if($case.Before -eq 3){[IO.File]::WriteAllText((Join-Path $fallback.Data 'hang'),'hang')}
        $fallback=Start-FixtureMonitor $fallback;$sessions+=@($fallback)
        Wait-Condition {(Read-FixtureStatus $fallback).Phase -eq 'active'} 'Dead-entry fixture did not reach active comparison'
        if($case.Before -eq 3){Wait-Condition {[IO.File]::Exists((Join-Path $fallback.Data 'hung'))} 'Fallback monitor did not pause for deadline recovery'}
        [IO.File]::WriteAllText((Join-Path $fallback.Data 'endpoint-dead'),'dead')
        Wait-Condition {[IO.File]::Exists((Join-Path $fallback.Directory 'recovery-done'))} 'Dead-entry fallback did not finish'
        $status=Read-FixtureStatus $fallback
        Check ($status.RestoreOutcome -eq 'direct-fallback' -and $status.LaunchOutcome -eq 'started' -and $status.Message -match '未重新启用' -and $status.Message -notmatch '原系统代理已恢复') 'Completed fallback accurately reports the stopped local entry instead of claiming the original proxy was restored'
        $writes=@(Get-Content -LiteralPath (Join-Path $fallback.Data 'writes'))
        Check ((Get-Content (Join-Path $fallback.Data 'system.json') -Raw|ConvertFrom-Json).Flags -eq $case.Expected -and @($writes|Where-Object {[int]$_ -eq $case.Before}).Count -eq 0) 'Dead manual proxy is never re-enabled; pre-existing automatic configuration flags are retained'
        Check (-not [IO.File]::Exists((Join-Path $fallback.Data 'runonce.json'))) 'Successful dead-entry fallback removes its completed recovery registration'
        if($case.Before -eq 3){
            Check (-not $fallback.Process.HasExited -and [IO.File]::Exists((Join-Path $fallback.Directory 'restore-result.json'))) 'Guard records completed fallback while the original monitor is still alive'
            [IO.File]::Delete((Join-Path $fallback.Data 'endpoint-dead'))
            [IO.File]::WriteAllText((Join-Path $fallback.Data 'release-monitor'),'release')
            Wait-Condition {$fallback.Process.HasExited} 'Old monitor did not finish after deadline guard restored'
            $writes=@(Get-Content -LiteralPath (Join-Path $fallback.Data 'writes'))
            Check ((Read-FixtureStatus $fallback).RestoreOutcome -eq 'direct-fallback' -and (Get-Content (Join-Path $fallback.Data 'system.json') -Raw|ConvertFrom-Json).Flags -eq 1 -and @($writes|Where-Object {[int]$_ -eq 3}).Count -eq 0) 'A recovered old endpoint cannot make a late monitor undo an already completed fallback'
        }
    }

    $dead=Start-FixtureMonitor (New-FixtureSession 'dead' 60);$sessions+=@($dead)
    Wait-Condition {(Read-FixtureStatus $dead).Phase -eq 'active'} 'Crash fixture did not reach active'
    $dead.Process.Kill();[void]$dead.Process.WaitForExit(5000)
    Wait-Condition {(Read-FixtureStatus $dead).RestoreOutcome -eq 'restored'} 'Guard did not restore a terminated monitor'
    Check ((Get-Content (Join-Path $dead.Data 'system.json') -Raw|ConvertFrom-Json).Flags -eq 3) 'Real guard detects exact monitor death and restores without waiting for another Windows login'
    Check ((Read-FixtureStatus $dead).LaunchOutcome -eq 'started') 'Crash recovery preserves successful launch evidence independently from restoration'

    $hung=New-FixtureSession 'hung' 4;[IO.File]::WriteAllText((Join-Path $hung.Data 'hang'),'hang');$hung=Start-FixtureMonitor $hung;$sessions+=@($hung)
    Wait-Condition {[IO.File]::Exists((Join-Path $hung.Data 'hung'))} 'Hanging monitor fixture did not pause'
    Wait-Condition {(Read-FixtureStatus $hung).RestoreOutcome -eq 'restored'} 'Guard could not restore while the monitor remained alive'
    Check (-not $hung.Process.HasExited -and (Get-Content (Join-Path $hung.Data 'system.json') -Raw|ConvertFrom-Json).Flags -eq 3) 'Deadline guard restores even when the live monitor is stalled, without killing it or taking its long-lived mutex'
    Check ([IO.File]::Exists((Join-Path $hung.Directory 'cancel'))) 'Deadline restoration cancels late target launches'
    Stop-OwnedMonitor $hung;$hung.Process=$null

    $manual=Start-FixtureMonitor (New-FixtureSession 'manual' 60);$sessions+=@($manual)
    Wait-Condition {(Read-FixtureStatus $manual).Phase -eq 'active'} 'Explicit restoration fixture did not reach active'
    $guardIdentity=Get-Content (Join-Path $manual.Directory 'guard-ready.json') -Raw|ConvertFrom-Json
    Check ((Get-CleanStartProcessState $guardIdentity) -eq 'alive') 'Fixture guard is identified by PID, exact creation ticks and executable before simulated failure'
    $guardProcess=[Diagnostics.Process]::GetProcessById([int]$guardIdentity.PID)
    try{
        Check ($guardProcess.StartTime.ToUniversalTime().Ticks.ToString() -ceq [string]$guardIdentity.StartTicks) 'Only this fixture guard is selected for the intentional failure scenario'
        $guardProcess.Kill();[void]$guardProcess.WaitForExit(5000)
    }finally{$guardProcess.Dispose()}
    $manual.Process.Kill();[void]$manual.Process.WaitForExit(5000)
    $stopScript=Join-Path $qa 'stop-fixture.ps1'
    $stopText=". '"+(Join-Path $harness 'ProxyBackend.ps1').Replace("'","''")+"' -DataDirectory '"+$manual.Data.Replace("'","''")+"'`r`nStop-ProgramCleanSession | Out-Null"
    [IO.File]::WriteAllText($stopScript,$stopText,(New-Object Text.UTF8Encoding($true)))
    $manualStopLock=[IO.File]::Open((Join-Path $manual.Directory 'stop'),[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        & $shell -NoProfile -ExecutionPolicy Bypass -File $stopScript
        Check ($LASTEXITCODE -eq 0) 'Explicit Stop starts a fresh restoration worker despite a locked stop marker after both fixture monitors have exited'
        Wait-Condition {(Read-FixtureStatus $manual).RestoreOutcome -eq 'restored'} 'Explicit Stop did not restore the dead-monitor session'
        Check ((Get-Content (Join-Path $manual.Data 'system.json') -Raw|ConvertFrom-Json).Flags -eq 3) 'Explicit recovery restores the owned snapshot while the stop marker remains locked, without relaunching or ending the target'
    }finally{$manualStopLock.Dispose()}

    $metadata=New-FixtureSession 'metadata' 8;[IO.File]::WriteAllText((Join-Path $metadata.Data 'hang'),'hang');$metadata=Start-FixtureMonitor $metadata;$sessions+=@($metadata)
    Wait-Condition {[IO.File]::Exists((Join-Path $metadata.Data 'hung'))} 'Metadata failure fixture did not pause'
    [IO.File]::Delete((Join-Path $metadata.Directory 'launched.json'))
    [IO.File]::WriteAllText((Join-Path $metadata.Directory 'child-error.json'),'invalid JSON fixture')
    $stopLock=[IO.File]::Open((Join-Path $metadata.Directory 'stop'),[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $cancelLock=[IO.File]::Open((Join-Path $metadata.Directory 'cancel'),[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        Wait-Condition {(Read-FixtureStatus $metadata).RestoreOutcome -eq 'restored'} 'Metadata I/O blocked deadline recovery'
        Check ((Read-FixtureStatus $metadata).LaunchOutcome -eq 'unknown' -and (Get-Content (Join-Path $metadata.Data 'system.json') -Raw|ConvertFrom-Json).Flags -eq 3) 'Locked stop/cancel markers and malformed launch logs cannot block deadline restoration'
    }finally{$stopLock.Dispose();$cancelLock.Dispose();Stop-OwnedMonitor $metadata;$metadata.Process=$null}

    $statusFailure=New-FixtureSession 'status-failure' 15;[IO.File]::WriteAllText((Join-Path $statusFailure.Data 'fail-starting'),'fail');$statusFailure=Start-FixtureMonitor $statusFailure;$sessions+=@($statusFailure)
    Wait-Condition {[IO.File]::Exists((Join-Path $statusFailure.Directory 'recovery-done'))} 'Post-launch status failure did not finish recovery'
    Check ((Read-FixtureStatus $statusFailure).LaunchOutcome -eq 'started' -and (Read-FixtureStatus $statusFailure).RestoreOutcome -eq 'restored') 'A failed starting-status write after real Process.Start success retains the launch result and still restores'

    $inventoryReader=${function:Get-ProcessInventory}
    $identity=[pscustomobject]@{PID=49901;StartTicks='100';Path=$shell}
    function Get-ProcessInventory { @([pscustomobject]@{Id=49901;PathStatus='Available';Path=$shell;StartTime=[DateTime]::UtcNow}) }
    Check ((Get-CleanStartProcessState $identity) -eq 'stopped') 'PID reuse with another creation time does not count as the original monitor'
    function Get-ProcessInventory { @([pscustomobject]@{Id=49901;PathStatus='AccessDenied';Path='';StartTime=[DateTime]::MinValue}) }
    Check ((Get-CleanStartProcessState $identity) -eq 'unknown') 'Unreadable monitor identity remains unknown and never authorizes termination'
    Set-Item Function:Get-ProcessInventory $inventoryReader
}finally{
    foreach($session in $sessions){Stop-OwnedMonitor $session;try{[IO.File]::WriteAllText((Join-Path $session.Directory 'stop'),'stop')}catch{}}
}
Write-Output ('PASS: '+$script:Checks+' real isolated clean-start lifecycle checks; Monitor/Child/Guard processes are real, Windows and RunOnce writes use only temporary fixtures.')

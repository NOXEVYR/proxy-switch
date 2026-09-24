param([Parameter(Mandatory=$true)][string]$DataDirectory,[Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$SessionId,[ValidateSet('Monitor','Child','Restore','Guard')][string]$Mode='Monitor')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $DataDirectory
$directory=Join-Path $script:DataRoot ('clean-start\'+$SessionId)
$request=Get-Content -LiteralPath (Join-Path $directory 'request.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($request.Id -cne $SessionId -or $request.UserSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or [IO.Path]::GetFullPath([string]$request.DataDirectory) -ine [IO.Path]::GetFullPath($script:DataRoot)){throw '启动请求不属于当前 Windows 用户或配置目录。'}
$plan=$request.Plan
$script:LaunchOutcome='not-started';$script:RestoreOutcome='not-needed';$script:LaunchMessage=''
function Save-CleanStatus([string]$Phase,[string]$Message,$Extra=$null){Write-LocalJson (Join-Path $directory 'status.json') ([pscustomobject]@{Phase=$Phase;Message=$Message;Time=[DateTimeOffset]::UtcNow.ToString('o');LaunchOutcome=$script:LaunchOutcome;RestoreOutcome=$script:RestoreOutcome;Extra=$Extra})}
function Save-CleanChild([string]$File,$Value){Write-LocalJson (Join-Path $directory $File) $Value}
function Test-CleanCancelled {[IO.File]::Exists((Join-Path $directory 'stop')) -or [IO.File]::Exists((Join-Path $directory 'cancel'))}
function Assert-CleanSessionCurrent {
    # Status/launch logs are not recovery ownership evidence and may be damaged.
    $current=Get-Content -LiteralPath (Join-Path $script:DataRoot 'clean-start-current.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not $current -or $current.Id -cne $SessionId){throw '启动对照归属已改变，未覆盖其他会话。'}
}
function Save-CleanFinalStatus {
    $phase='complete';$message='对照已结束；登录结果需单独确认。'
    if($script:LaunchOutcome -eq 'failed'){$phase='launch-failed';$message=$script:LaunchMessage}
    elseif($script:LaunchOutcome -eq 'unknown'){$phase='launch-unknown';$message='未取得完整启动证据，请检查程序是否已经打开，避免重复启动。'}
    elseif($script:LaunchOutcome -eq 'cancelled'){$phase='cancelled';$message='已取消启动对照。'}
    elseif($script:LaunchOutcome -eq 'not-started'){$phase='failed';$message=$(if($script:LaunchMessage){$script:LaunchMessage}else{'未取得启动证据，程序状态需检查。'})}
    elseif($script:LaunchOutcome -eq 'started'){$message='程序启动已发生；实际出口与登录结果仍需单独验证。'}
    if($script:RestoreOutcome -eq 'restored'){$message+=' 原系统代理已恢复并核验。'}
    elseif($script:RestoreOutcome -eq 'external-change'){$phase='external-change';$message+=' 系统代理已由其他操作更改，保留外部设置。'}
    elseif($script:RestoreOutcome -eq 'failed'){$phase='recovery-failed';$message+=' 恢复尚未完成，快照已保留；可点击结束并恢复重试。'}
    Save-CleanStatus $phase $message
}
function Read-CleanLaunchOutcome {
    try{
        $launched=Join-Path $directory 'launched.json';$warning=Join-Path $directory 'child-warning.json';$errorPath=Join-Path $directory 'child-error.json'
        if([IO.File]::Exists($launched) -or [IO.File]::Exists($warning)){$script:LaunchOutcome='started';return}
        if([IO.File]::Exists($errorPath)){
            $errorState=Get-Content -LiteralPath $errorPath -Raw -Encoding UTF8|ConvertFrom-Json
            $script:LaunchOutcome=$(if($errorState.Outcome -eq 'cancelled'){'cancelled'}else{'failed'});$script:LaunchMessage=[string]$errorState.Message
        }
    }catch{$script:LaunchOutcome='unknown';$script:LaunchMessage='启动记录暂不可读取，请检查目标窗口，避免重复启动。'}
}
function Restore-CleanSession {
    $snapshotPath=Join-Path $directory 'recovery.json'
    if(-not [IO.File]::Exists($snapshotPath)){$script:RestoreOutcome='not-needed';return}
    $recovery=Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not $recovery.Before -or -not $recovery.Target -or $null -eq $recovery.Before.Flags -or $recovery.Target.Flags -ne 1 -or -not $recovery.Before.AutomaticConfigFingerprint -or -not $recovery.Target.AutomaticConfigFingerprint){throw '恢复快照不完整，未写入系统代理。'}
    $script:RestoreOutcome='pending'
    for($attempt=1;$attempt -le 3;$attempt++){
        try{Assert-CleanSessionCurrent;$script:RestoreOutcome=Restore-CleanStartSnapshot $recovery.Before $recovery.Target;break}
        catch{$script:RestoreOutcome='failed';if($attempt -lt 3){Start-Sleep -Milliseconds (250*$attempt)}}
    }
    if($script:RestoreOutcome -in @('restored','external-change')){try{Remove-CleanStartRecovery $recovery.Registration}catch{}}
}
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$baseArguments='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-ProgramArgument $PSCommandPath)+' -DataDirectory '+(ConvertTo-ProgramArgument $script:DataRoot)+' -SessionId '+$SessionId

if($Mode -eq 'Child'){
    $started=$false;$cancelled=$false
    try{
        Assert-CleanStartPlan $plan
        $start=New-CleanProgramStartInfo $plan.Path
        Save-CleanChild 'ready.json' ([pscustomobject]@{Ready=$true})
        $limit=[DateTime]::UtcNow.AddSeconds(90)
        while(-not [IO.File]::Exists((Join-Path $directory 'go'))){
            if((Test-CleanCancelled) -or [DateTime]::UtcNow -ge $limit){$cancelled=$true;throw '启动对照已取消。'}
            Start-Sleep -Milliseconds 200
        }
        $identity=Get-ProgramIdentityDescriptor $plan.Path (New-ProgramIdentityContext)
        if($identity.FileId -cne $plan.FileId -or $identity.CanonicalPath -ine $plan.CanonicalPath){throw '程序文件已改变，未启动。'}
        Assert-CleanProgramStopped $plan.Path
        Assert-CleanSessionCurrent
        if($request.UserSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw '当前用户身份已改变。'}
        if($plan.DirectTest){
            $recovery=Get-Content -LiteralPath (Join-Path $directory 'recovery.json') -Raw -Encoding UTF8|ConvertFrom-Json
            if([DateTime]::UtcNow -ge ([DateTime]$recovery.Deadline).ToUniversalTime() -or -not (Test-CleanStartSnapshot (Get-CleanStartSystemSnapshot) $recovery.Target)){$cancelled=$true;throw '系统代理已改变或对照已到期。'}
        }
        if((Test-CleanCancelled) -or [DateTime]::UtcNow -ge $limit -or ([DateTime]::UtcNow-[IO.File]::GetLastWriteTimeUtc((Join-Path $directory 'go'))).TotalSeconds -gt 30){$cancelled=$true;throw '启动对照已取消或过期。'}
        $process=[Diagnostics.Process]::Start($start);$started=$true
        try{Save-CleanChild 'launched.json' ([pscustomobject]@{PID=$process.Id;Time=[DateTimeOffset]::UtcNow.ToString('o');Environment='Proxy variables cleared; NO_PROXY=*'})}finally{$process.Dispose()}
    }catch{
        if($started){try{Save-CleanChild 'child-warning.json' ([pscustomobject]@{Outcome='started';Message='程序已经启动，但启动证据记录不完整；请检查窗口，不要重复启动。'})}catch{};return}
        $message=$(if($cancelled){'启动对照已取消，未启动程序。'}elseif($_.Exception.NativeErrorCode -eq 740 -or $_.Exception.InnerException.NativeErrorCode -eq 740){'此程序要求管理员权限，请重新预览并勾选管理员启动。'}else{'程序未启动，请检查是否完整退出、身份是否可读或额外网络参数。'})
        Save-CleanChild 'child-error.json' ([pscustomobject]@{Outcome=$(if($cancelled){'cancelled'}else{'failed'});Message=$message;ErrorType=$_.Exception.GetType().Name})
    }
    return
}

if($Mode -eq 'Guard'){
    Write-LocalJson (Join-Path $directory 'guard-ready.json') (Get-CleanStartProcessIdentity)
    $limit=[DateTime]::UtcNow.AddSeconds(420)
    while([DateTime]::UtcNow -lt $limit){
        if([IO.File]::Exists((Join-Path $directory 'recovery-done'))){return}
        $monitorPath=Join-Path $directory 'monitor.json'
        $identity=$null;if([IO.File]::Exists($monitorPath)){$identity=Get-Content -LiteralPath $monitorPath -Raw -Encoding UTF8|ConvertFrom-Json}
        $state=Get-CleanStartProcessState $identity
        if($state -eq 'stopped'){break}
        if([IO.File]::Exists((Join-Path $directory 'recovery.json'))){
            $recovery=Get-Content -LiteralPath (Join-Path $directory 'recovery.json') -Raw -Encoding UTF8|ConvertFrom-Json
            if([DateTime]::UtcNow -ge ([DateTime]$recovery.Deadline).ToUniversalTime()){
                # A stalled but living monitor must not prolong the temporary Windows change.
                # Both restorers use the common short change lock and current-session CAS.
                try{[IO.File]::WriteAllText((Join-Path $directory 'stop'),'stop')}catch{}
                try{[IO.File]::WriteAllText((Join-Path $directory 'cancel'),'cancel')}catch{}
                Read-CleanLaunchOutcome
                try{Restore-CleanSession}catch{$script:RestoreOutcome='failed'}
                Save-CleanFinalStatus
                if($script:RestoreOutcome -ne 'failed'){[IO.File]::WriteAllText((Join-Path $directory 'recovery-done'),'done')}
                return
            }
        }
        Start-Sleep -Milliseconds 400
    }
    # Unknown/live identities cannot authorize stealing the monitor's lock or terminating it.
    if($state -ne 'stopped'){return}
    $Mode='Restore'
}

$mutex=$null;$locked=$false;$armed=$false;$registration=$null
try{
    $mutex=New-Object Threading.Mutex($false,('Local\FlowSwitch-CleanStart-'+$request.UserSid))
    try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw '另一个启动对照正在运行；未更改系统代理。'}
    Assert-CleanSessionCurrent
    if($Mode -eq 'Restore'){
        Read-CleanLaunchOutcome
        $identityPath=Join-Path $directory 'monitor.json';$identity=$null
        if(-not [IO.File]::Exists($identityPath)){$identityPath=Join-Path $directory 'monitor-launch.json'}
        if([IO.File]::Exists($identityPath)){$identity=Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8|ConvertFrom-Json}
        if((Get-CleanStartProcessState $identity) -ne 'stopped'){throw '监护进程仍存在或身份未知，暂不重复恢复。'}
        Restore-CleanSession;Save-CleanFinalStatus
        if($script:RestoreOutcome -eq 'failed'){exit 1}
        [IO.File]::WriteAllText((Join-Path $directory 'recovery-done'),'done')
        return
    }
    Write-LocalJson (Join-Path $directory 'monitor.json') (Get-CleanStartProcessIdentity)
    Assert-CleanStartPlan $plan
    $childArguments=$baseArguments+' -Mode Child'
    if($plan.Elevate){$child=Start-Process -FilePath $shell -Verb RunAs -WindowStyle Hidden -ArgumentList $childArguments -PassThru}
    else{$child=Start-Process -FilePath $shell -WindowStyle Hidden -ArgumentList $childArguments -PassThru}
    $child.Dispose();$limit=[DateTime]::UtcNow.AddSeconds(75)
    while(-not [IO.File]::Exists((Join-Path $directory 'ready.json'))){
        Read-CleanLaunchOutcome
        if($script:LaunchOutcome -eq 'failed' -or (Test-CleanCancelled) -or [DateTime]::UtcNow -ge $limit){throw '启动准备取消或超时，未修改系统代理。'}
        Start-Sleep -Milliseconds 200
    }
    Assert-CleanStartPlan $plan
    $duration=300;if($plan.DurationSeconds){$duration=[Math]::Min(300,[Math]::Max(1,[int]$plan.DurationSeconds))}
    $deadline=[DateTime]::UtcNow.AddSeconds($duration)
    if($plan.DirectTest){
        $guard=Start-CleanStartRecoveryGuard $PSCommandPath $SessionId $directory
        $registration=New-CleanStartRecoveryRegistration $SessionId $PSCommandPath
        $owned=[pscustomobject]@{Armed=$false}
        try{
            Use-ChangeLock {
                Assert-CleanStartPlan $plan;Assert-CleanSessionCurrent
                if(Test-CleanCancelled){throw '启动对照已取消，系统代理未改变。'}
                $before=Get-CleanStartSystemSnapshot
                $target=[pscustomobject]@{Flags=1;Server=$before.Server;Bypass=$before.Bypass;AutomaticConfigFingerprint=$before.AutomaticConfigFingerprint}
                Write-LocalJson (Join-Path $directory 'recovery.json') ([pscustomobject]@{Before=$before;Target=$target;Deadline=$deadline.ToString('o');Registration=$registration})
                Register-CleanStartRecovery $registration
                if(-not (Test-CleanStartSnapshot (Get-CleanStartSystemSnapshot) $before)){throw '系统代理在准备期间已改变，未应用旧预览。'}
                $owned.Armed=$true;Set-SystemSnapshot $target
                if(-not (Test-CleanStartSnapshot (Get-CleanStartSystemSnapshot) $target)){throw '系统直连状态未通过回读核验。'}
            }
        }finally{$armed=$owned.Armed}
        $script:RestoreOutcome='pending'
    }
    if(Test-CleanCancelled){$script:LaunchOutcome='cancelled';throw '启动对照已取消。'}
    [IO.File]::WriteAllText((Join-Path $directory 'go'),'go');$script:LaunchOutcome='unknown'
    Save-CleanStatus 'starting' '正在启动，等待新进程证据。'
    $launchDeadline=[DateTime]::UtcNow.AddSeconds(30)
    do{
        Read-CleanLaunchOutcome
        if($script:LaunchOutcome -in @('failed','cancelled')){throw $script:LaunchMessage}
        if($script:LaunchOutcome -eq 'started'){break}
        if(Test-CleanCancelled){$script:LaunchOutcome='unknown';throw '已请求取消；启动结果需检查。'}
        if([DateTime]::UtcNow -ge $launchDeadline){$script:LaunchOutcome='unknown';throw '尚未取得启动证据，请检查程序是否已经打开。'}
        Start-Sleep -Milliseconds 200
    }while($true)
    Save-CleanStatus $(if($plan.DirectTest){'active'}else{'complete'}) $(if($plan.DirectTest){'直连对照进行中，到期自动恢复。请自行验证登录，可提前结束。'}else{'程序已在干净环境启动；系统代理未改变，登录仍需验证。'}) ([pscustomobject]@{Deadline=$deadline.ToString('o')})
    if($plan.DirectTest){while([DateTime]::UtcNow -lt $deadline -and -not (Test-CleanCancelled)){
        $recovery=Get-Content -LiteralPath (Join-Path $directory 'recovery.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if(-not (Test-CleanStartSnapshot (Get-CleanStartSystemSnapshot) $recovery.Target)){break}
        Start-Sleep -Milliseconds 400
    }}
}catch{
    $script:LaunchMessage=$_.Exception.Message
    if($script:LaunchOutcome -eq 'not-started' -and (Test-CleanCancelled)){$script:LaunchOutcome='cancelled'}
    if($Mode -eq 'Restore'){$script:RestoreOutcome='failed';try{Save-CleanFinalStatus}catch{};exit 1}
}finally{
    try{
        # A failed status/cancel write must never prevent restoration or mutex release.
        if($locked){try{[IO.File]::WriteAllText((Join-Path $directory 'cancel'),'cancel')}catch{}}
        if($Mode -eq 'Monitor' -and $locked){
            if($armed){try{Restore-CleanSession}catch{$script:RestoreOutcome='failed'}}
            elseif($registration){try{Remove-CleanStartRecovery $registration}catch{}}
            Read-CleanLaunchOutcome
            Save-CleanFinalStatus
            if($script:RestoreOutcome -ne 'failed'){[IO.File]::WriteAllText((Join-Path $directory 'recovery-done'),'done')}
        }
    }finally{if($locked){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
}


# Explicit launch/diagnostic actions only. Never called by passive status refresh.
. (Join-Path $PSScriptRoot 'ProgramFamilyTracking.ps1')
function Get-CleanStartSystemSnapshot {
    $native=Get-SystemSnapshot
    # Hash the exact PAC value without saving or displaying its possibly private URL.
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings')
    try{$pac=$(if($key){$key.GetValue('AutoConfigURL',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}else{$null})}
    finally{if($key){$key.Dispose()}}
    [pscustomobject]@{Flags=$native.Flags;Server=$native.Server;Bypass=$native.Bypass;AutomaticConfigFingerprint=(Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes @($pac)))}
}
function Test-CleanStartSnapshot($A,$B) {
    if(-not (Test-SameSnapshot $A $B)){return $false}
    return [string]$A.AutomaticConfigFingerprint -ceq [string]$B.AutomaticConfigFingerprint
}
function Get-CleanStartProcessIdentity($Process=$null) {
    $owned=$false;if(-not $Process){$Process=[Diagnostics.Process]::GetCurrentProcess();$owned=$true}
    try{[pscustomobject]@{PID=$Process.Id;StartTicks=$Process.StartTime.ToUniversalTime().Ticks.ToString();Path=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')}}finally{if($owned){$Process.Dispose()}}
}
function Get-CleanStartProcessState($Identity) {
    if(-not $Identity -or -not $Identity.PID -or -not $Identity.StartTicks -or -not $Identity.Path){return 'unknown'}
    try{$rows=@(Get-ProcessInventory ([int]$Identity.PID))}catch{return 'unknown'}
    $rows=@($rows|Where-Object Id -eq ([int]$Identity.PID))
    if(-not $rows.Count){return 'stopped'}
    if($rows.Count -ne 1 -or $rows[0].PathStatus -ne 'Available' -or -not $rows[0].StartTime -or [DateTime]$rows[0].StartTime -eq [DateTime]::MinValue){return 'unknown'}
    if(([DateTime]$rows[0].StartTime).ToUniversalTime().Ticks.ToString() -cne [string]$Identity.StartTicks -or $rows[0].Path -ine $Identity.Path){return 'stopped'}
    return 'alive'
}
function Get-CleanStartRecoveryRoot {Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'FlowSwitch\Recovery'}
function New-CleanStartRecoveryRegistration([string]$SessionId,[string]$WorkerPath) {
    $root=Get-CleanStartRecoveryRoot
    $stub=Join-Path $root ($SessionId.Substring(0,16)+'.ps1')
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command=(ConvertTo-ProgramArgument $shell)+' -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File '+(ConvertTo-ProgramArgument $stub)
    if($command.Length -gt 260){throw '恢复入口路径超过 Windows RunOnce 限制，未修改系统代理。请使用较短的用户数据路径。'}
    if(-not [IO.File]::Exists($WorkerPath)){throw '恢复程序不存在，未修改系统代理。'}
    $contents='$ErrorActionPreference="Stop"'+"`r`n"+'& '''+$WorkerPath.Replace("'","''")+''' -DataDirectory '''+$script:DataRoot.Replace("'","''")+''' -SessionId '+$SessionId+' -Mode Restore'+"`r`n"+'if($LASTEXITCODE){exit $LASTEXITCODE}'+"`r`n"
    [void][IO.Directory]::CreateDirectory($root)
    if([IO.File]::Exists($stub) -and [IO.File]::ReadAllText($stub) -cne $contents){throw '恢复入口已经存在不同内容，未覆盖。'}
    [IO.File]::WriteAllText($stub,$contents,(New-Object Text.UTF8Encoding($true)))
    [pscustomobject]@{Name=('!FlowSwitch-CleanStart-'+$SessionId);Command=$command;StubPath=$stub;StubHash=(Read-RuleMaintenanceFile $stub).Hash}
}
function Register-CleanStartRecovery($Registration) {
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if(-not (Test-Path $key)){[void](New-Item $key -Force)}
    if($Registration.Command.Length -gt 260 -or (Read-RuleMaintenanceFile $Registration.StubPath).Hash -cne $Registration.StubHash){throw '恢复入口校验失败，未修改系统代理。'}
    New-ItemProperty -LiteralPath $key -Name $Registration.Name -Value $Registration.Command -PropertyType String -Force|Out-Null
    if((Get-ItemPropertyValue -LiteralPath $key -Name $Registration.Name) -cne $Registration.Command){throw '恢复注册未通过回读，未修改系统代理。'}
}
function Remove-CleanStartRecovery($Registration) {
    if(-not $Registration){return}
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    $value=Get-ItemPropertyValue -LiteralPath $key -Name $Registration.Name -ErrorAction SilentlyContinue
    if($value -ceq $Registration.Command){Remove-ItemProperty -LiteralPath $key -Name $Registration.Name}
}
function Start-CleanStartRecoveryGuard([string]$WorkerPath,[string]$SessionId,[string]$Directory) {
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-ProgramArgument $WorkerPath)+' -DataDirectory '+(ConvertTo-ProgramArgument $script:DataRoot)+' -SessionId '+$SessionId+' -Mode Guard'
    $guard=Start-Process -FilePath $shell -WindowStyle Hidden -ArgumentList $arguments -PassThru
    try{$identity=Get-CleanStartProcessIdentity $guard}finally{$guard.Dispose()}
    $limit=[DateTime]::UtcNow.AddSeconds(12)
    while(-not [IO.File]::Exists((Join-Path $Directory 'guard-ready.json'))){if([DateTime]::UtcNow -ge $limit -or (Get-CleanStartProcessState $identity) -eq 'stopped'){throw '独立恢复守护未就绪，未修改系统代理。'};Start-Sleep -Milliseconds 100}
    if((Get-CleanStartProcessState $identity) -ne 'alive'){throw '独立恢复守护身份不可确认，未修改系统代理。'}
    return $identity
}
function New-CleanProgramStartInfo([string]$Path) {
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$Path;$start.WorkingDirectory=[IO.Path]::GetDirectoryName($Path);$start.UseShellExecute=$false
    foreach($key in @($start.EnvironmentVariables.Keys)){
        if([string]$key -match '^(?i:HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|FTP_PROXY|NO_PROXY)$'){$start.EnvironmentVariables.Remove([string]$key)}
    }
    $start.EnvironmentVariables['NO_PROXY']='*'
    if([string]$start.EnvironmentVariables['QTWEBENGINE_CHROMIUM_FLAGS'] -match '(?i)--proxy|--host-resolver'){throw '程序存在额外的网络启动参数，未覆盖它们。请先检查该程序的专用代理设置。'}
    return $start
}
function Assert-CleanProgramStopped([string]$Path) {
    $processes=@(Get-ProcessInventory)
    $family=Get-ProgramFamilyTrackingSnapshot $Path $processes (New-ProgramIdentityContext -Processes $processes)
    if(-not $family.Available -or @($family.UnknownIds).Count){throw '程序进程身份尚不可确认，未启动。请完整退出启动器和相关进程后刷新。'}
    if(@($family.Members).Count){throw '启动器或已识别子进程仍在运行。请正常退出整组程序后重试；流向不会结束现有进程。'}
    $name=[IO.Path]::GetFileNameWithoutExtension($Path)
    if(@($processes|Where-Object {$_.ProcessName -ieq $name -and -not $_.Path}).Count){throw '存在同名但身份不可读取的运行进程，未重复启动。请先确认程序已完整退出。'}
}
function Get-ProgramCleanStartPlan([string]$Path,[bool]$DirectTest=$false) {
    $path=Resolve-ProgramTarget $Path
    $context=New-ProgramIdentityContext
    foreach($profile in $script:Profiles.Profiles){if((Test-ProgramPathEquivalent $path $profile.CorePath $context) -or (Test-ProgramPathEquivalent $path $profile.AppPath $context)){throw '代理客户端与内核不能作为干净启动的目标。'}}
    $identity=Get-ProgramIdentityDescriptor $path $context
    if(-not $identity.Exists -or -not $identity.FileId -or $identity.PathStatus -ne 'Available'){throw '程序文件身份不可确认，未准备启动。'}
    $snapshot=Get-RuleMaintenanceSnapshot $path
    $state=Get-CleanStartSystemSnapshot
    $message='清理本次启动链的 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / FTP_PROXY，设置 NO_PROXY=*。不会修改持久环境变量或自动退出程序。系统代理、专用代理和外部 VPN 仍可能影响联网；需要观察实际连接。'
    if($DirectTest){$message='在干净启动基础上，临时关闭当前用户系统代理（最长 5 分钟），会影响其他遵循系统代理的新连接。独立恢复进程会在到期或你点击结束时核对并恢复原设置；他人修改会被保留。流向内核继续运行。请只在需要登录对照时使用。'}
    [pscustomobject]@{Version=1;Path=$path;FileId=$identity.FileId;CanonicalPath=$identity.CanonicalPath;Revision=$snapshot.Fingerprint;CreatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();DirectTest=$DirectTest;Elevate=$false;DurationSeconds=300;System=$state;Message=$message}
}
function Assert-CleanStartPlan($Plan) {
    if($Plan.Version -ne 1 -or $Plan.DirectTest -isnot [bool] -or $Plan.Elevate -isnot [bool]){throw '启动计划无效，请重新预览。'}
    $age=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-[long]$Plan.CreatedAt
    if($age -lt 0 -or $age -gt 90){throw '启动预览已过期，请重新打开。'}
    $current=Get-ProgramCleanStartPlan $Plan.Path $Plan.DirectTest
    if($Plan.DurationSeconds -and ([int]$Plan.DurationSeconds -lt 1 -or [int]$Plan.DurationSeconds -gt 300)){throw '直连对照期限无效。'}
    if($current.FileId -cne $Plan.FileId -or $current.CanonicalPath -ine $Plan.CanonicalPath -or $current.Revision -cne $Plan.Revision -or -not (Test-CleanStartSnapshot $current.System $Plan.System)){throw '程序文件、线路或系统代理已改变，请重新预览。'}
    Assert-CleanProgramStopped $Plan.Path
    [void](New-CleanProgramStartInfo $Plan.Path)
}
function Get-CleanStartSession {
    $path=Join-Path $script:DataRoot 'clean-start-current.json'
    if(-not [IO.File]::Exists($path)){return $null}
    $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$record.Id -notmatch '^[a-f0-9]{32}$'){throw '启动诊断记录损坏，请检查本机记录。'}
    $directory=Join-Path $script:DataRoot ('clean-start\'+$record.Id)
    $resultPath=Join-Path $directory 'status.json';$status=$null
    if([IO.File]::Exists($resultPath)){$status=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json}
    [pscustomobject]@{Id=$record.Id;Directory=$directory;Status=$status}
}
function Start-ProgramCleanSession($Plan,[switch]$Confirmed) {
    if(-not $Confirmed){throw '请先确认干净启动或直连对照的范围。'}
    Use-ChangeLock {
        Assert-CleanStartPlan $Plan
        $previous=Get-CleanStartSession
        if($previous -and (-not $previous.Status -or $previous.Status.Phase -notin @('complete','failed','external-change','launch-failed','launch-unknown','cancelled') -or $previous.Status.RestoreOutcome -in @('pending','failed'))){throw '已有启动对照尚未结束；请先结束并恢复原设置。'}
        $id=[Guid]::NewGuid().ToString('N');$directory=Join-Path $script:DataRoot ('clean-start\'+$id)
        [void][IO.Directory]::CreateDirectory($directory)
        $request=[pscustomobject]@{Version=1;Id=$id;Plan=$Plan;UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;DataDirectory=$script:DataRoot;CreatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()}
        Write-LocalJson (Join-Path $directory 'request.json') $request
        Write-LocalJson (Join-Path $script:DataRoot 'clean-start-current.json') ([pscustomobject]@{Id=$id})
        Write-LocalJson (Join-Path $directory 'status.json') ([pscustomobject]@{Phase='preparing';Message='正在准备启动；尚未更改系统代理。'})
        $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-ProgramArgument (Join-Path $script:Root 'CleanStartWorker.ps1'))+' -DataDirectory '+(ConvertTo-ProgramArgument $script:DataRoot)+' -SessionId '+$id
        try{$worker=Start-Process -FilePath $shell -WindowStyle Hidden -ArgumentList $arguments -PassThru}
        catch{Write-LocalJson (Join-Path $directory 'status.json') ([pscustomobject]@{Phase='failed';Message='恢复监护进程未能启动，系统代理未更改。'});throw}
        try{Write-LocalJson (Join-Path $directory 'monitor-launch.json') (Get-CleanStartProcessIdentity $worker)}
        catch{return [pscustomobject]@{Message='启动监护已提交，但进程记录未完成。请查看诊断状态，不要重复提交。';SessionId=$id;ObservationUnknown=$true}}
        finally{$worker.Dispose()}
        [pscustomobject]@{Message='已提交启动准备；请在诊断页查看状态。若需要管理员权限，请完成正常 UAC 确认。启动成功不等于登录成功。';SessionId=$id}
    }
}
function Stop-ProgramCleanSession {
    $session=Get-CleanStartSession
    if(-not $session){throw '没有启动对照记录。'}
    $notified=$true;try{[IO.File]::WriteAllText((Join-Path $session.Directory 'stop'),'stop')}catch{$notified=$false}
    $identityPath=Join-Path $session.Directory 'monitor.json'
    if(-not [IO.File]::Exists($identityPath)){$identityPath=Join-Path $session.Directory 'monitor-launch.json'}
    $identity=$null;if([IO.File]::Exists($identityPath)){$identity=Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8|ConvertFrom-Json}
    $state=Get-CleanStartProcessState $identity
    if($state -eq 'unknown'){return [pscustomobject]@{Message=$(if($notified){'已请求结束；监护进程身份暂不可核验，请刷新查看恢复结果。未结束任何进程。'}else{'结束请求未能写入，且监护进程身份暂不可核验；请查看恢复状态。未结束任何进程。'})}}
    if($state -eq 'stopped'){
        $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-ProgramArgument (Join-Path $script:Root 'CleanStartWorker.ps1'))+' -DataDirectory '+(ConvertTo-ProgramArgument $script:DataRoot)+' -SessionId '+$session.Id+' -Mode Restore'
        $recovery=Start-Process -FilePath $shell -WindowStyle Hidden -ArgumentList $arguments -PassThru;$recovery.Dispose()
    }
    elseif(-not $notified){return [pscustomobject]@{Message='结束请求未能写入，监护仍在运行；独立守护会在对照期限到时恢复。请查看恢复结果。'}}
    [pscustomobject]@{Message='已请求结束对照并恢复仍属于本次操作的系统设置。请查看恢复结果；游戏不会被结束。'}
}
function Get-CleanStartRestoreEndpointState([string]$Endpoint) {
    # Reuse the strict local-endpoint parser. Never probe remote/complex addresses.
    $parsed=Get-LocalEndpointObservation $Endpoint ([pscustomobject]@{Available=$false;Rows=@()})
    if(-not $parsed){return 'not-local'}
    try{
        $tcp=Get-TcpObservationSnapshot
        if(-not $tcp.Available){return 'unknown'}
        $listeners=@($tcp.Rows|Where-Object {$_.State -eq 'Listen' -and $_.LocalPort -eq $parsed.Port -and $_.LocalAddress -in @('127.0.0.1','0.0.0.0','::','::1')})
        $endpointHost=(($Endpoint -replace '^(?:http|https|socks5|socks5h)://','') -replace ':[0-9]+/?$','').Trim('[',']').ToLowerInvariant()
        $matching=$listeners
        if($endpointHost -eq '127.0.0.1'){
            $matching=@($listeners|Where-Object {$_.LocalAddress -in @('127.0.0.1','0.0.0.0')})
            # The TCP table cannot reveal whether an IPv6 wildcard is dual-stack.
            if(-not $matching.Count -and @($listeners|Where-Object LocalAddress -eq '::').Count){return 'unknown'}
        }elseif($endpointHost -eq '::1'){$matching=@($listeners|Where-Object {$_.LocalAddress -in @('::1','::')})}
        if(-not $matching.Count){return 'dead'}
        $observed=Get-LocalEndpointObservation $Endpoint ([pscustomobject]@{Available=$true;Rows=@($matching)})
        if($observed.Ready -eq $true){return 'live'}
        # A listener with unreadable/exited ownership is not proven dead.
        return 'unknown'
    }catch{return 'unknown'}
}
function Restore-CleanStartSnapshot($Before,$Target) {
    Use-ChangeLock {
        $current=Get-CleanStartSystemSnapshot
        $fallback=$null
        if([int]$Before.Flags -band 2){
            # Disable only the dead manual proxy; retain original PAC/autodetect modes.
            $fallback=[pscustomobject]@{Flags=(([int]$Before.Flags -band (-bnot 2)) -bor 1);Server=$Before.Server;Bypass=$Before.Bypass;AutomaticConfigFingerprint=$Before.AutomaticConfigFingerprint}
        }
        # A concurrent Guard/Monitor may have already completed this safe fallback.
        if($fallback -and -not (Test-CleanStartSnapshot $fallback $Target) -and (Test-CleanStartSnapshot $current $fallback)){return 'direct-fallback'}
        if(Test-CleanStartSnapshot $current $Target){
            $desired=$Before;$outcome='restored'
            if($fallback){
                $state=Get-CleanStartRestoreEndpointState $Before.Server
                if($state -eq 'unknown'){throw '原本地代理入口状态未知，未重新启用；恢复快照已保留，请重试。'}
                if($state -eq 'dead'){$desired=$fallback;$outcome='direct-fallback'}
            }
            # TCP/owner inspection can yield. Preserve a change made during that read.
            $latest=Get-CleanStartSystemSnapshot
            if(-not (Test-CleanStartSnapshot $latest $Target)){return 'external-change'}
            if(-not (Test-CleanStartSnapshot $latest $desired)){Set-SystemSnapshot $desired}
            if(-not (Test-CleanStartSnapshot (Get-CleanStartSystemSnapshot) $desired)){throw '原系统代理尚未通过恢复核验。'}
            return $outcome
        }
        if(Test-CleanStartSnapshot $current $Before){return 'restored'}
        return 'external-change'
    }
}

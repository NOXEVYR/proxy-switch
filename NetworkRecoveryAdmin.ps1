# The main UI stays unelevated. Only a fixed compiled helper may change machine proxy settings.
function Get-NetworkRecoveryAdminHelper {Join-Path $PSScriptRoot 'FlowSwitch.Recovery.exe'}
function Get-NetworkRecoveryAdminStatus {
    try {
        $helper=Get-NetworkRecoveryAdminHelper
        if(-not (Test-Path -LiteralPath $helper -PathType Leaf)){throw 'missing'}
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$helper;$start.Arguments='--inspect';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $process=[Diagnostics.Process]::Start($start)
        try {
            if(-not $process.WaitForExit(5000)){try{$process.Kill()}catch{};return [pscustomobject]@{State='Unavailable';NeedsRepair=$false;EnvironmentNames=@();WinHttpState='Unknown';Revision='';Elevated=$false;Message='机器级检查尚未完成，请稍后重试。'}}
            $text=$process.StandardOutput.ReadToEnd();if($process.ExitCode -ne 0 -or $text.Length -gt 8192){throw 'inspect'}
            $value=$text|ConvertFrom-Json
            if($value.State -ne 'Available' -or $value.Revision -notmatch '^[A-F0-9]{64}$' -or $value.WinHttpState -notin @('Direct','Proxy') -or @($value.EnvironmentNames|Where-Object {$_ -notin @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')}).Count){throw 'schema'}
            $value|Add-Member NoteProperty Message '机器代理与当前用户代理分开检查；已运行程序可能保留旧环境。' -Force
            $value
        }finally{$process.Dispose()}
    }catch{[pscustomobject]@{State='Unavailable';NeedsRepair=$false;EnvironmentNames=@();WinHttpState='Unknown';Revision='';Elevated=$false;Message='机器级代理读取不完整；请使用完整程序包检查，未将未知视为正常。'}}
}
function Get-NetworkRecoveryAdminPlan {
    $status=Get-NetworkRecoveryAdminStatus;$helper=Get-NetworkRecoveryAdminHelper
    $hash=if(Test-Path -LiteralPath $helper -PathType Leaf){(Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash}else{''}
    [pscustomobject]@{Kind='RecoveryAdmin';CreatedAt=[DateTimeOffset]::UtcNow.ToString('o');CanApply=($status.State -eq 'Available' -and $status.NeedsRepair);Revision=$status.Revision;HelperHash=$hash;ClearEnvironment=(@($status.EnvironmentNames).Count -gt 0);ResetWinHttp=($status.WinHttpState -eq 'Proxy');Status=$status;Message=$(if($status.State -ne 'Available'){$status.Message}elseif(-not $status.NeedsRepair){'未发现已设置的机器级代理，无需提权重置。'}else{'将备份并清除机器级代理变量、将已设置的 WinHTTP 默认代理恢复为直连。影响本机使用这些设置的新连接；不停止程序、服务或网卡，不清除 NO_PROXY。需要管理员权限，取消授权不会执行此步骤。'})}
}
function New-NetworkRecoveryAdminRequest($Plan) {
    $directory=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'FlowSwitch\RecoveryAdmin'
    $cursor=[IO.Path]::GetFullPath($directory)
    while($cursor){if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw '恢复记录目录不允许使用重解析路径。'};$cursor=[IO.Path]::GetDirectoryName($cursor)}
    [void][IO.Directory]::CreateDirectory($directory)
    $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    foreach($who in @($sid,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')),(New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))){
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($who,'FullControl','ContainerInherit,ObjectInherit','None','Allow');$acl.AddAccessRule($rule)
    }
    [IO.Directory]::SetAccessControl($directory,$acl)
    $id=[Guid]::NewGuid().ToString('N');$self=[Diagnostics.Process]::GetCurrentProcess()
    try{$ticks=$self.StartTime.ToUniversalTime().Ticks.ToString()}finally{$self.Dispose()}
    $request=[ordered]@{Schema=1;Id=$id;UserSid=$sid.Value;CreatedAt=$Plan.CreatedAt;ParentId=$PID;ParentStartTicks=$ticks;Revision=$Plan.Revision;ClearEnvironment=[bool]$Plan.ClearEnvironment;ResetWinHttp=[bool]$Plan.ResetWinHttp}
    $path=Join-Path $directory ($id+'.request.json')
    $bytes=[Text.Encoding]::UTF8.GetBytes(($request|ConvertTo-Json -Compress));$stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    [pscustomobject]@{Path=$path;Hash=(Get-FileHash -LiteralPath $path).Hash;Result=(Join-Path $directory ($id+'.result.json'))}
}
function Start-NetworkRecoveryAdminHelper([string]$Helper,$Request) {
    # Values are generated locally; no raw proxy values or command fragments are arguments.
    Start-Process -FilePath $Helper -ArgumentList @('--apply',('"'+$Request.Path+'"'),$Request.Hash) -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
}
function Invoke-NetworkRecoveryAdminPlan($Plan,[switch]$Confirmed) {
    if(-not $Confirmed){throw '机器级恢复需要先确认具体范围。'}
    $at=[DateTimeOffset]::MinValue
    if(-not $Plan -or $Plan.Kind -ne 'RecoveryAdmin' -or -not $Plan.CanApply -or -not [DateTimeOffset]::TryParse($Plan.CreatedAt,[ref]$at) -or ([DateTimeOffset]::UtcNow-$at).TotalSeconds -gt 120 -or ([DateTimeOffset]::UtcNow-$at).TotalSeconds -lt -5){return [pscustomobject]@{State='Rejected';Code='PlanExpired';Message='机器级方案已过期或不可用，请重新检查。'}}
    $fresh=Get-NetworkRecoveryAdminPlan
    if(-not $fresh.CanApply -or $fresh.Revision -cne $Plan.Revision -or $fresh.HelperHash -cne $Plan.HelperHash -or [bool]$fresh.ClearEnvironment -ne [bool]$Plan.ClearEnvironment -or [bool]$fresh.ResetWinHttp -ne [bool]$Plan.ResetWinHttp){return [pscustomobject]@{State='Rejected';Code='StateChanged';Message='机器设置或助手文件已变化，请重新预览；没有执行旧方案。'}}
    $request=$null;$process=$null
    try {
        $request=New-NetworkRecoveryAdminRequest $Plan
        if((Get-FileHash -LiteralPath (Get-NetworkRecoveryAdminHelper)).Hash -cne $Plan.HelperHash){throw 'helper-changed'}
        $process=Start-NetworkRecoveryAdminHelper (Get-NetworkRecoveryAdminHelper) $request
        if(-not $process.WaitForExit(45000)){return [pscustomobject]@{State='Unknown';Code='HelperPending';Message='管理员助手尚未返回。不要重复执行，请稍后重新检查；本次未宣称成功。'}}
        if(-not (Test-Path -LiteralPath $request.Result)){return [pscustomobject]@{State='Failed';Code='HelperNoReceipt';Message='未取得管理员恢复收据，请重新检查机器级设置；不能确认已恢复。'}}
        $result=Get-Content -LiteralPath $request.Result -Raw -Encoding UTF8|ConvertFrom-Json
        if($result.State -notin @('Applied','Failed','Rejected')){throw 'result'}
        $after=Get-NetworkRecoveryAdminStatus
        $verified=($process.ExitCode -eq 0 -and $result.State -eq 'Applied' -and $result.SettingsVerified -and $after.State -eq 'Available' -and -not $after.NeedsRepair)
        $result|Add-Member NoteProperty Message $(if($verified){'机器级代理设置已重置并复读确认。普通网站和实际应用仍需检测；已有程序可能需保存工作后正常重开或重新登录 Windows。'}else{'机器级恢复未完成或设置再次变化。保留备份与收据，请重新检查；没有自动停止其他程序。'}) -Force
        if(-not $verified -and $result.State -eq 'Applied'){$result.State='Partial';$result.Code='PostCheckChanged'}
        $result
    }catch{
        $errorCode=$_.Exception.NativeErrorCode
        if(-not $errorCode -and $_.Exception.InnerException){$errorCode=$_.Exception.InnerException.NativeErrorCode}
        [pscustomobject]@{State=$(if($errorCode -eq 1223){'Cancelled'}else{'Failed'});Code=$(if($errorCode -eq 1223){'ElevationCancelled'}else{'ElevationFailed'});Message=$(if($errorCode -eq 1223){'已取消管理员授权，机器级步骤未执行；已完成的用户代理恢复保持不变。'}else{'管理员助手未完成。请重新检查权限与机器设置；不会反复弹窗或强制结束程序。'})}
    }finally{if($process){$process.Dispose()}}
}

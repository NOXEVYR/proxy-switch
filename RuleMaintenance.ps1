param([switch]$OfflineRepairWorker)
# Explicit user actions only. Display refresh must never invoke these writers.
if(-not ('LocalProxySwitch.RuleFileExchange' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
namespace LocalProxySwitch {
    public static class RuleFileExchange {
        [StructLayout(LayoutKind.Sequential)] struct Disposition { [MarshalAs(UnmanagedType.Bool)] public bool Delete; }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle file,int kind,ref Disposition value,uint size);
        public static string Hash(byte[] bytes) {using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","").ToLowerInvariant();}
        static void MarkDelete(FileStream stream){var value=new Disposition{Delete=true};if(!SetFileInformationByHandle(stream.SafeFileHandle,4,ref value,4))throw new IOException("Cannot safely remove the unchanged shortcut.");}
        public static void Apply(string path,string expectedHash,byte[] bytes,bool remove) {
            bool created=expectedHash=="<missing>";
            if(created&&remove){if(File.Exists(path))throw new IOException("File changed after the preview.");return;}
            // DELETE access allows a verified removal on this very handle, without reopening a raced path.
            using(var handle=CreateFileW(path,0xC0010000,0,IntPtr.Zero,created?1u:3u,0,IntPtr.Zero)) {
            if(handle.IsInvalid)throw new IOException("Cannot exclusively open the expected file ("+Marshal.GetLastWin32Error()+").");
            using(var file=new FileStream(handle,FileAccess.ReadWrite)) {
                byte[] before=new byte[file.Length];int offset=0;
                while(offset<before.Length){int count=file.Read(before,offset,before.Length-offset);if(count==0)throw new IOException("Incomplete file read.");offset+=count;}
                if(!created&&Hash(before)!=expectedHash)throw new IOException("File changed after the preview.");
                if(remove){MarkDelete(file);return;}
                try{file.Position=0;file.Write(bytes,0,bytes.Length);file.SetLength(bytes.Length);file.Flush(true);}
                catch{
                    // The exclusive handle still excludes outside writes while a partial write is undone.
                    if(created)MarkDelete(file);else{file.Position=0;file.Write(before,0,before.Length);file.SetLength(before.Length);file.Flush(true);}throw;
                }
            }
            }
        }
    }
}
'@
}
function Get-RuleMaintenanceHash([byte[]]$Bytes){[LocalProxySwitch.RuleFileExchange]::Hash($Bytes)}
function ConvertTo-RuleMaintenanceBytes($Value){[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 16))}
function Read-RuleMaintenanceFile([string]$Path){
    if(-not [IO.File]::Exists($Path)){return [pscustomobject]@{Path=$Path;Exists=$false;Bytes=[byte[]]@();Hash='<missing>';TextHash='<missing>'}}
    $bytes=[IO.File]::ReadAllBytes($Path);$text=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff)
    [pscustomobject]@{Path=$Path;Exists=$true;Bytes=$bytes;Hash=(Get-RuleMaintenanceHash $bytes);TextHash=(Get-RuleMaintenanceHash ([Text.Encoding]::UTF8.GetBytes($text)))}
}
function Read-RuleMaintenanceJson($Image,$Default){if(-not $Image.Exists){return $Default};try{[Text.Encoding]::UTF8.GetString($Image.Bytes).TrimStart([char]0xfeff)|ConvertFrom-Json}catch{throw '程序保存记录无法读取，请先检查或恢复备份。'}}
function Get-RuleMaintenanceSnapshot([string]$SavedPath){
    $files=@{};foreach($name in @('app-rules.json','program-proxies.json','program-shortcuts.json','config.json')){$files[$name]=Read-RuleMaintenanceFile (Join-Path $script:DataRoot $name)}
    $engine=Read-RuleMaintenanceJson $files['app-rules.json'] ([pscustomobject]@{version=2;installed=$false;entries=@();defaultRoute=$null})
    $launch=Read-RuleMaintenanceJson $files['program-proxies.json'] ([pscustomobject]@{version=1;entries=@()})
    $shortcuts=Read-RuleMaintenanceJson $files['program-shortcuts.json'] ([pscustomobject]@{version=1;entries=@()})
    if($engine.version -notin @(1,2,3) -or $launch.version -ne 1 -or $shortcuts.version -ne 1){throw '程序保存记录版本不兼容，未进行修改。'}
    $links=@{};foreach($entry in @($shortcuts.entries|Where-Object {$_.program -ieq $SavedPath})){
        $path=[string]$entry.shortcut;if(-not [IO.Path]::IsPathRooted($path) -or $path -notmatch '(?i)\.lnk$'){throw '快捷方式记录路径无效。'}
        $links[$path]=Read-RuleMaintenanceFile $path
    }
    $fingerprint=@();foreach($name in @($files.Keys|Sort-Object)){$fingerprint+=($name+'='+$files[$name].Hash)}
    foreach($path in @($links.Keys|Sort-Object)){$fingerprint+=($path.ToLowerInvariant()+'='+$links[$path].Hash)}
    [pscustomobject]@{Files=$files;Engine=$engine;Launch=$launch;Shortcuts=$shortcuts;Links=$links;Fingerprint=(Get-RuleMaintenanceHash ([Text.Encoding]::UTF8.GetBytes(($fingerprint -join "`n"))))}
}
function Get-RuleMaintenanceIdentityFingerprint($Resolution){
    $identity=$Resolution.Identity
    $value=[ordered]@{Path=[string]$Resolution.CurrentPath;Reason=[string]$Resolution.Reason;Confidence=[string]$Resolution.Confidence;FileId=[string]$identity.FileId;CanonicalPath=[string]$identity.CanonicalPath;PackageFamilyName=[string]$identity.PackageFamilyName;PackageFullName=[string]$identity.PackageFullName;RelativeExecutable=[string]$identity.RelativeExecutable}
    Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes $value)
}
function Get-RuleMaintenanceProfiles($Snapshot){
    $value=Read-RuleMaintenanceJson $Snapshot.Files['config.json'] $null
    if($null -eq $value){$value=Get-Content -LiteralPath (Join-Path $script:Root 'config.defaults.json') -Raw -Encoding UTF8|ConvertFrom-Json}
    ConvertTo-ValidProfileSettings (Convert-LegacySettings $value)
}
function Get-RuleMaintenanceServiceObservation($Snapshot){
    $profiles=Get-RuleMaintenanceProfiles $Snapshot
    if($profiles.Routing.Adapter -ne 'standalone'){return [pscustomobject]@{State='unknown';Fingerprint=''}}
    $images=@{};$parts=@();$states=@();$invalid=$false
    foreach($name in @('gateway-session.json','gateway\process.json','gateway\supervisor.lock','gateway\runtime.yaml','gateway\generation.json','gateway\health.json','selection.json')){
        $image=Read-RuleMaintenanceFile (Join-Path $script:DataRoot $name);$images[$name]=$image;$parts+=($name+'='+$image.Hash)
    }
    foreach($name in @('gateway-session.json','gateway\process.json','gateway\supervisor.lock')){
        if(-not $images[$name].Exists){continue}
        try{
            $record=Read-RuleMaintenanceJson $images[$name] $null
            if($name -eq 'gateway-session.json'){$identities=@(,@($record.SupervisorPID,$record.SupervisorStart));if($record.CorePID -or $record.CoreStart){$identities+=,@($record.CorePID,$record.CoreStart)}}
            elseif($name -eq 'gateway\process.json'){$identities=@(@($record.supervisor,$record.supervisorStartTicks),@($record.core,$record.coreStartTicks))}
            else{$identities=@(,@($record.pid,$record.startTicks))}
            foreach($identity in $identities){
                if([string]$identity[0] -notmatch '^[1-9][0-9]*$' -or [decimal]$identity[0] -gt [int]::MaxValue -or [string]$identity[1] -notmatch '^[1-9][0-9]*$'){$invalid=$true;continue}
                $states+=Get-RecoveryOwnerState ([pscustomobject]@{OwnerPID=$identity[0];OwnerStart=$identity[1]})
            }
        }catch{$invalid=$true}
    }
    $gateway=@($profiles.Profiles|Where-Object Id -eq $profiles.Routing.ProfileId|Select-Object -First 1)[0]
    if(-not $gateway){$invalid=$true}
    $ports=@([int]$gateway.Port)+@($Snapshot.Engine.programIngresses|Where-Object {$_}|ForEach-Object {[int]$_.port})
    try{
        $tcp=Get-TcpObservationSnapshot
        if(-not $tcp.Available -or $null -eq $tcp.Rows){$invalid=$true}
        elseif(@($tcp.Rows|Where-Object {$_.State -eq 'Listen' -and [int]$_.LocalPort -in $ports}).Count -or @($tcp.Rows|Where-Object {$_.State -in @('Established','SynSent') -and ((([int]$_.LocalPort -in $ports) -and (Test-RuleMaintenanceLoopback $_.LocalAddress)) -or (([int]$_.RemotePort -in $ports) -and (Test-RuleMaintenanceLoopback $_.RemoteAddress)))}).Count){$states+='alive'}
        $processes=@(Get-ProcessInventory);$coreName=[IO.Path]::GetFileNameWithoutExtension([string]$gateway.CorePath)
        if(-not @($processes|Where-Object Id -eq $PID).Count){$invalid=$true}
        if(-not $gateway.CorePath){$invalid=$true}
        foreach($process in $processes){
            if($process.Path -and (Test-ProgramPathEquivalent $process.Path $gateway.CorePath)){$states+='alive'}
            elseif($coreName -and $process.ProcessName -ieq $coreName -and (-not $process.Path -or $process.PathStatus -ne 'Available')){$invalid=$true}
        }
    }catch{$invalid=$true}
    foreach($name in $images.Keys){if((Read-RuleMaintenanceFile $images[$name].Path).Hash -cne $images[$name].Hash){$invalid=$true}}
    $state=if($states -contains 'alive'){'alive'}elseif($invalid -or $states -contains 'unknown'){'unknown'}else{'stopped'}
    [pscustomobject]@{State=$state;Fingerprint=(Get-RuleMaintenanceHash ([Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))));Images=$images}
}
function Assert-RuleMaintenanceOfflineIdentity($Resolution){
    if($Resolution.Reason -cne 'PackageIdentity' -or $Resolution.Confidence -cne 'Verified' -or -not $Resolution.Identity.PackageVerified -or -not $Resolution.Identity.Exists -or -not $Resolution.Identity.FileId){throw '离线记录操作只接受已保存并重新核验的唯一 Windows 包身份；候选、歧义或不可读路径须先核对，未修改记录。'}
}
function Get-ProgramRuleRepairPlan([string]$SavedPath,[switch]$ReleaseOnly){
    $path=ConvertTo-ProgramIdentityPath $SavedPath;if(-not $path -or $path -notmatch '(?i)\.exe$'){throw '请选择有效的已保存程序记录。'}
    $snapshot=Get-RuleMaintenanceSnapshot $path
    $engine=@(@($snapshot.Engine.entries)+@($snapshot.Engine.programIngresses)|Where-Object {$_.path -ieq $path});$launch=@($snapshot.Launch.entries|Where-Object {$_.path -ieq $path})
    if(-not ($engine.Count+$launch.Count)){throw '该程序没有需要修复的保存记录。'}
    if($engine.Count -gt 1 -or $launch.Count -gt 1){throw '相同路径存在重复记录，请先移除冲突记录。'}
    $savedIdentity=$null;if($engine.Count){$savedIdentity=$engine[0].identity};if(-not $savedIdentity -and $launch.Count){$savedIdentity=$launch[0].identity}
    $processes=@(Get-ProcessInventory);$context=New-ProgramIdentityContext -Processes $processes -RefreshPackages
    $resolution=Resolve-ProgramIdentity $path -Processes $processes -Context $context -SavedIdentity $savedIdentity
    if($ReleaseOnly){
        $currentVerified=$resolution.Reason -in @('ExactPath','NotRunning','SameFile') -and $resolution.Identity.Exists -and $resolution.Identity.FileId -and $resolution.Identity.CanonicalPath -and $resolution.Identity.PathStatus -eq 'Available'
        if(-not $currentVerified){Assert-RuleMaintenanceOfflineIdentity $resolution}
        if(-not $resolution.CurrentPath){throw '程序路径或记录身份未知，未取消保存专线。'}
    }elseif(-not $resolution.CanRepair -or -not $resolution.RequiresRepair -or -not $resolution.CurrentPath){throw '没有唯一、可核对的新程序路径；请先解决路径不可读或多个候选的情况。'}
    if(@(@($snapshot.Engine.entries)+@($snapshot.Engine.programIngresses)+@($snapshot.Launch.entries)|Where-Object {$_.path -ine $path -and (Test-ProgramPathEquivalent $_.path $resolution.CurrentPath $context)}).Count){throw '新程序路径已经存在保存记录，请先处理冲突，未合并线路。'}
    if($launch.Count -and -not (Test-ProgramLaunchAdapterCompatibility $resolution.CurrentPath $launch[0].adapter)){throw '新版本不再符合原启动代理适配方式，未迁移记录。'}
    $profiles=Get-RuleMaintenanceProfiles $snapshot
    foreach($profile in $profiles.Profiles){if((Test-ProgramPathEquivalent $resolution.CurrentPath $profile.AppPath $context) -or (Test-ProgramPathEquivalent $resolution.CurrentPath $profile.CorePath $context)){throw '不能把代理程序自身的路径作为修复目标。'}}
    $mode=$(if($engine.Count -and $launch.Count){'mixed'}elseif($engine.Count){'engine'}else{'launch'})
    $execution=if($engine.Count){'apply-live'}else{'launch-only'};$serviceFingerprint=''
    if($engine.Count -and $profiles.Routing.Adapter -eq 'standalone'){
        $service=Get-RuleMaintenanceServiceObservation $snapshot
        if($service.State -eq 'unknown'){throw '独立服务停止证据未知；不能把控制接口不可用当作已停止，未修改程序记录。'}
        if($service.State -eq 'stopped'){
            if(-not $ReleaseOnly){Assert-RuleMaintenanceOfflineIdentity $resolution}
            if($launch.Count -or @($snapshot.Shortcuts.entries|Where-Object {$_.program -ieq $path}).Count){throw '离线修复暂不迁移启动代理或快捷方式记录；请核对相关入口，未修改原生快捷方式。'}
            $execution='saved-only';$serviceFingerprint=$service.Fingerprint
        }
    }
    $impact=$(if($engine.Count){'保留线路和默认出口，仅替换该程序路径并核对已运行引擎；新连接生效。'}else{'保留目标线路，更新仍归本工具的代理启动入口；已运行程序需要自行保存任务后重新打开。'})
    if($execution -eq 'saved-only'){$impact='仅迁移此程序的保存路径与已验证包身份，保留线路、默认出口、固定入口标识/端口和网站规则；独立服务已停止，规则尚未载入。不会启动服务、修改系统代理、重开程序或改写原生快捷方式。'}
    [pscustomobject]@{Version=2;Action='repair-path';Execution=$execution;ServiceFingerprint=$serviceFingerprint;DataDirectory=[IO.Path]::GetFullPath($script:DataRoot);SavedPath=$path;CurrentPath=$resolution.CurrentPath;Mode=$mode;CreatedAt=[DateTime]::UtcNow.ToString('o');SnapshotFingerprint=$snapshot.Fingerprint;IdentityFingerprint=(Get-RuleMaintenanceIdentityFingerprint $resolution);Identity=$resolution.Identity;Message=('将保存记录从 '+$path+' 修复为 '+$resolution.CurrentPath+'。');Impact=$impact}
}
function Get-ProgramOfflineReleasePlan([string]$SavedPath){
    $plan=Get-ProgramRuleRepairPlan $SavedPath -ReleaseOnly
    if($plan.Execution -cne 'saved-only' -or $plan.Mode -cne 'engine'){throw '仅能取消已经明确停止的独立服务中的程序专线；在线服务请使用原有移除流程。'}
    $snapshot=Get-RuleMaintenanceSnapshot $plan.SavedPath
    $ids=@($snapshot.Engine.programIngresses|Where-Object {$_.path -ieq $plan.SavedPath}|ForEach-Object id)
    if(@($snapshot.Engine.siteRules|Where-Object {$_.scope -in $ids}).Count){throw '此程序仍有网站例外；请先核对网站规则，未移除程序入口或相关策略。'}
    if($snapshot.Fingerprint -cne $plan.SnapshotFingerprint){throw '程序记录在预览期间变化，请重新预览。'}
    $plan.Action='release-system';$plan.Message='仅取消此程序保存在已停止流向服务中的旧专线，使它不再单独设置流向线路。'
    $plan.Impact='仅移除精确旧路径的程序规则或固定入口记录。保留其他程序、默认出口、网站规则、选择记录与 Windows 系统代理；不会启动服务或重开软件。软件是否采用当前系统代理仍需实际连接核对；这不是“跟随流向统一线路”。'
    $plan
}
function New-RuleMaintenanceBackup($Snapshot,[string]$Action,[string]$SavedPath,[string]$CurrentPath){
    $directory=Join-Path $script:DataRoot ('backups\program-maintenance\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory);$records=@();$index=0
    foreach($image in @($Snapshot.Files.Values)+@($Snapshot.Links.Values)){
        $name=('{0:D3}.bin' -f $index++);if($image.Exists){[IO.File]::WriteAllBytes((Join-Path $directory $name),$image.Bytes)}
        $records+=@([pscustomobject]@{Path=$image.Path;Exists=$image.Exists;Hash=$image.Hash;BackupFile=$(if($image.Exists){$name}else{''})})
    }
    $manifest=Join-Path $directory 'record.json';Write-LocalJson $manifest ([pscustomobject]@{Version=1;Action=$Action;SavedPath=$SavedPath;CurrentPath=$CurrentPath;CreatedAt=[DateTime]::UtcNow.ToString('o');Files=$records})
    [pscustomobject]@{Directory=$directory;Path=$manifest}
}
function Get-RuleMaintenanceArguments([string]$Executable){
    '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File '+(ConvertTo-ProgramArgument (Join-Path $script:Root 'ProxySwitch.ps1'))+' -DataDirectory '+(ConvertTo-ProgramArgument $script:DataRoot)+' -LaunchProgram '+(ConvertTo-ProgramArgument $Executable)
}
function New-RuleMaintenanceShortcutChanges($Snapshot,[string]$SavedPath,[string]$CurrentPath,$Backup,[switch]$Remove){
    $changes=@();$records=@();$preserved=0;$restoredUpdated=0
    foreach($entry in @($Snapshot.Shortcuts.entries)){
        if($entry.program -ine $SavedPath){$records+=@($entry);continue}
        $image=$Snapshot.Links[[string]$entry.shortcut];$owned=$false
        if($image.Exists){
            Initialize-ProgramShortcutSupport
            $link=[FlowSwitchShellShortcut]::Read($entry.shortcut)
            $owned=$link.TargetPath -ieq $entry.managedTarget -and $link.Arguments -ceq $entry.managedArguments
        }
        $next=$entry|ConvertTo-Json -Depth 12|ConvertFrom-Json
        if(-not $Remove){$next.program=$CurrentPath;$next|Add-Member NoteProperty previousProgramPaths (@(@(Get-ProgramIdentityValue $entry 'previousProgramPaths' @())+@($SavedPath))|Select-Object -Unique) -Force}
        if($owned){
            if($Remove){
                if($entry.originalBackup){
                    $original=Read-RuleMaintenanceFile ([string]$entry.originalBackup);if(-not $original.Exists){throw '原快捷方式备份已缺失，保留现有入口；请先检查备份。'}
                    $restoredBytes=$original.Bytes
                    # Keep the original backup immutable. A previously confirmed repair also records
                    # its old program path, so removing the proxy need not restore a dead versioned launcher.
                    if(@(Get-ProgramIdentityValue $entry 'previousProgramPaths' @()).Count -and [IO.File]::Exists($SavedPath)){
                        $stage=Join-Path $Backup.Directory ([Guid]::NewGuid().ToString('N')+'.lnk');[IO.File]::WriteAllBytes($stage,$original.Bytes)
                        $restored=[FlowSwitchShellShortcut]::Read($stage)
                        $oldTarget=[string]$restored.TargetPath
                        if($oldTarget -in @(Get-ProgramIdentityValue $entry 'previousProgramPaths' @()) -and -not [IO.File]::Exists($oldTarget)){
                            $restored.TargetPath=$SavedPath
                            if($restored.WorkingDirectory -ieq [IO.Path]::GetDirectoryName($oldTarget)){$restored.WorkingDirectory=[IO.Path]::GetDirectoryName($SavedPath)}
                            if($restored.IconLocation.StartsWith($oldTarget+',',[StringComparison]::OrdinalIgnoreCase)){$restored.IconLocation=$SavedPath+$restored.IconLocation.Substring($oldTarget.Length)}
                            [FlowSwitchShellShortcut]::Write($stage,$restored);$restoredBytes=[IO.File]::ReadAllBytes($stage);$restoredUpdated++
                        }
                    }
                    $changes+=@([pscustomobject]@{Before=$image;Bytes=$restoredBytes;Remove=$false})
                }else{$changes+=@([pscustomobject]@{Before=$image;Bytes=[byte[]]@();Remove=$true})}
            }else{
                $stage=Join-Path $Backup.Directory ([Guid]::NewGuid().ToString('N')+'.lnk');[IO.File]::WriteAllBytes($stage,$image.Bytes)
                $link=[FlowSwitchShellShortcut]::Read($stage)
                $next.managedTarget=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe';$next.managedArguments=Get-RuleMaintenanceArguments $CurrentPath
                $link.TargetPath=$next.managedTarget;$link.Arguments=$next.managedArguments;$link.WorkingDirectory=[IO.Path]::GetDirectoryName($CurrentPath)
                if($link.IconLocation.StartsWith($SavedPath+',',[StringComparison]::OrdinalIgnoreCase)){$link.IconLocation=$CurrentPath+$link.IconLocation.Substring($SavedPath.Length)}
                [FlowSwitchShellShortcut]::Write($stage,$link)
                $changes+=@([pscustomobject]@{Before=$image;Bytes=[IO.File]::ReadAllBytes($stage);Remove=$false})
            }
        }elseif($image.Exists){$preserved++}
        if(-not $Remove){$records+=@($next)}
    }
    [pscustomobject]@{Changes=$changes;Records=$records;Preserved=$preserved;RestoredUpdated=$restoredUpdated}
}
function Set-RuleMaintenanceFile($Before,[byte[]]$Bytes,[bool]$Remove=$false){[LocalProxySwitch.RuleFileExchange]::Apply($Before.Path,$Before.Hash,$Bytes,$Remove)}
function Assert-RuleMaintenanceEngine($Snapshot){
    $live=Invoke-AppRouter @{action='status'}
    if(-not $live.available -or -not (Get-ProgramIdentityValue $live 'rulesAvailable' $false) -or $live.mode -ne 'rule'){throw '分流引擎尚未运行或规则无法核对；请先启动已配置引擎。此次操作不会启动引擎或切换系统代理。'}
    if((Read-RuleMaintenanceFile $Snapshot.Files['app-rules.json'].Path).Hash -cne $Snapshot.Files['app-rules.json'].Hash){throw '引擎检查期间保存记录发生变化，请重新预览。'}
}
function Test-RuleMaintenanceLoopback([string]$Address){
    $parsed=$null
    if(-not [Net.IPAddress]::TryParse($Address,[ref]$parsed)){return $false}
    if($parsed.IsIPv4MappedToIPv6){$parsed=$parsed.MapToIPv4()}
    return [Net.IPAddress]::IsLoopback($parsed)
}
function Assert-ManagedIngressRemoval($Snapshot,[string]$SavedPath,$Entries){
    $ids=@($Entries|ForEach-Object id);$ports=@($Entries|ForEach-Object {[int]$_.port});$names=@($ids|ForEach-Object {'FS-Program-'+$_})
    if(@($Snapshot.Engine.siteRules|Where-Object {$_.scope -in $ids}).Count){throw '此程序仍有网站例外，请先在网站规则中移除对应规则，再移除程序入口。'}
    . (Join-Path $PSScriptRoot 'ProgramFamilyTracking.ps1')
    try{
        $processes=@(Get-ProcessInventory)
        $family=Get-ProgramFamilyTrackingSnapshot $SavedPath $processes (New-ProgramIdentityContext -Processes $processes)
    }catch{throw '进程身份读取失败，无法确认程序入口无人使用；未移除入口。请等待或刷新后重试。'}
    if(@($family.Members).Count){throw '此程序或已确认的后台进程仍在运行，移除固定入口会中断它。请先保存任务并完整退出；只想取消专用线路可选择“跟随统一线路”。'}
    if(-not $family.Available -or @($family.UnknownIds).Count){throw '部分后台进程身份不可读，程序入口使用状态未知；未移除入口。请等待或刷新后重试。'}
    try{$live=Invoke-AppRouter @{action='status'}}catch{throw '入口连接读取失败，无法确认无人使用；未移除固定入口。'}
    if(-not $live.available -or -not (Test-ObservationFlag $live 'connectionsAvailable' $false) -or $null -eq $live.PSObject.Properties['connections'] -or $null -eq $live.connections){throw '入口连接状态未知，无法确认无人使用；未移除固定入口。'}
    if(@($live.connections|Where-Object {$_.ingressId -in $ids -or $_.inboundName -in $names}).Count){throw '固定入口仍有活动连接，可能来自后台服务；未移除入口。请先保存任务并完整退出相关程序，或选择“跟随统一线路”。'}
    try{$tcp=Get-TcpObservationSnapshot}catch{throw 'TCP 连接读取失败，无法确认入口无人使用；未移除固定入口。'}
    if(-not $tcp.Available -or $null -eq $tcp.Rows){throw 'TCP 连接状态未知，无法确认入口无人使用；未移除固定入口。'}
    $active=@($tcp.Rows|Where-Object {
        if([string]$_.State -notin @('Established','SynSent')){return $false}
        return (([int]$_.RemotePort -in $ports) -and (Test-RuleMaintenanceLoopback ([string]$_.RemoteAddress))) -or (([int]$_.LocalPort -in $ports) -and (Test-RuleMaintenanceLoopback ([string]$_.LocalAddress)))
    })
    if($active.Count){throw '固定入口仍有活动或正在建立的 TCP 连接；未移除入口。请先保存任务并完整退出相关程序，或选择“跟随统一线路”。'}
}
function Invoke-RuleMaintenanceChange($Snapshot,[string]$SavedPath,[string]$CurrentPath,$Identity,[switch]$Remove,$OfflinePlan=$null){
    # Invoke-AppRouter exports this object; bind it to exactly the previewed configuration bytes.
    $script:Profiles=Get-RuleMaintenanceProfiles $Snapshot
    $engineEntries=@(@($Snapshot.Engine.entries)+@($Snapshot.Engine.programIngresses)|Where-Object {$_.path -ieq $SavedPath});$launchEntries=@($Snapshot.Launch.entries|Where-Object {$_.path -ieq $SavedPath})
    $managedEntries=@($Snapshot.Engine.programIngresses|Where-Object {$_.path -ieq $SavedPath})
    if($managedEntries.Count -and $Remove -and -not $OfflinePlan){
        Assert-ManagedIngressRemoval $Snapshot $SavedPath $managedEntries
    }
    if($managedEntries.Count -and -not $Remove){
        $adapter=Get-ProgramProxyAdapter $CurrentPath
        $environmentCompatible=$launchEntries.Count -eq 1 -and $launchEntries[0].adapter -ceq 'environment' -and (Test-ProgramLaunchAdapterCompatibility $CurrentPath 'environment')
        if($adapter -notin @('chromium','qtwebengine') -and -not $environmentCompatible){throw '新程序路径不再支持原固定入口启动适配，未迁移规则。'}
    }
    if($engineEntries.Count -and -not $OfflinePlan){Assert-RuleMaintenanceEngine $Snapshot}
    $backup=New-RuleMaintenanceBackup $Snapshot $(if($Remove){'remove'}else{'repair'}) $SavedPath $CurrentPath
    $shortcutPlan=if($OfflinePlan){[pscustomobject]@{Changes=@();Records=@($Snapshot.Shortcuts.entries);Preserved=0;RestoredUpdated=0}}else{New-RuleMaintenanceShortcutChanges $Snapshot $SavedPath $CurrentPath $backup -Remove:$Remove}
    $nextLaunch=$Snapshot.Launch|ConvertTo-Json -Depth 16|ConvertFrom-Json;$nextEngine=@()
    foreach($entry in @($Snapshot.Engine.entries)){
        if($entry.path -ine $SavedPath){$nextEngine+=@($entry);continue};if($Remove){continue}
        $next=$entry|ConvertTo-Json -Depth 16|ConvertFrom-Json;$next.path=$CurrentPath;$next|Add-Member NoteProperty identity $Identity -Force;$nextEngine+=@($next)
    }
    $nextIngresses=@(foreach($entry in @($Snapshot.Engine.programIngresses|Where-Object {$_})){
        if($entry.path -ine $SavedPath){$entry;continue};if($Remove){continue}
        $next=$entry|ConvertTo-Json -Depth 16|ConvertFrom-Json;$next.path=$CurrentPath;$next|Add-Member NoteProperty identity $Identity -Force;$next
    })
    $nextLaunch.entries=@(foreach($entry in @($Snapshot.Launch.entries)){
        if($entry.path -ine $SavedPath){$entry;continue};if($Remove){continue}
        $next=$entry|ConvertTo-Json -Depth 16|ConvertFrom-Json;$next.path=$CurrentPath;$next|Add-Member NoteProperty identity $Identity -Force;$next
    })
    $changes=@($shortcutPlan.Changes)
    if(@($Snapshot.Shortcuts.entries|Where-Object {$_.program -ieq $SavedPath}).Count){
        $nextShortcuts=$Snapshot.Shortcuts|ConvertTo-Json -Depth 16|ConvertFrom-Json;$nextShortcuts.entries=@($shortcutPlan.Records)
        $changes+=@([pscustomobject]@{Before=$Snapshot.Files['program-shortcuts.json'];Bytes=(ConvertTo-RuleMaintenanceBytes $nextShortcuts);Remove=$false})
    }
    if($launchEntries.Count){$changes+=@([pscustomobject]@{Before=$Snapshot.Files['program-proxies.json'];Bytes=(ConvertTo-RuleMaintenanceBytes $nextLaunch);Remove=$false})}
    if($OfflinePlan){
        $nextState=$Snapshot.Engine|ConvertTo-Json -Depth 16|ConvertFrom-Json;$nextState.entries=@($nextEngine)
        if($nextState.PSObject.Properties['programIngresses']){$nextState.programIngresses=@($nextIngresses)}
        $changes=@([pscustomobject]@{Before=$Snapshot.Files['app-rules.json'];Bytes=(ConvertTo-RuleMaintenanceBytes $nextState);Remove=$false})
    }
    $written=@();$engineHash='';$rollbackProblems=@();$preserved=0
    try{
        if((Get-RuleMaintenanceSnapshot $SavedPath).Fingerprint -cne $Snapshot.Fingerprint){throw '记录或快捷方式在准备期间发生变化，请重新预览。'}
        if($engineEntries.Count -and -not $OfflinePlan){
            $response=Invoke-AppRouter @{action='replace';entries=$nextEngine;defaultRoute=$Snapshot.Engine.defaultRoute;programIngresses=$nextIngresses;siteRules=@($Snapshot.Engine.siteRules|Where-Object {$_});expectedStateHash=$Snapshot.Files['app-rules.json'].TextHash;expectedSettingsHash=$Snapshot.Files['config.json'].TextHash}
            $engineHash=[string](Get-ProgramIdentityValue $response 'stateHash' '')
            if(-not $engineHash){throw '引擎未返回写入归属校验，已保留备份；请刷新核对，不继续改写启动入口。'}
        }
        foreach($change in $changes){
            if($OfflinePlan){Assert-RuleMaintenanceOfflineState $Snapshot $OfflinePlan.ServiceFingerprint}
            Set-RuleMaintenanceFile $change.Before $change.Bytes $change.Remove
            $written+=@([pscustomobject]@{Before=$change.Before;AfterHash=$(if($change.Remove){'<missing>'}else{Get-RuleMaintenanceHash $change.Bytes})})
        }
        foreach($item in $written){if((Read-RuleMaintenanceFile $item.Before.Path).Hash -cne $item.AfterHash){throw '写入后发现外部更改，保留外部内容。'}}
        if($OfflinePlan){
            Assert-RuleMaintenanceOfflineState $Snapshot $OfflinePlan.ServiceFingerprint
            foreach($name in @('config.json','program-proxies.json','program-shortcuts.json')){if((Read-RuleMaintenanceFile $Snapshot.Files[$name].Path).Hash -cne $Snapshot.Files[$name].Hash){throw '离线记录操作期间配置发生外部修改，未确认完成。'}}
        }
    }catch{
        $message=$_.Exception.Message
        for($index=$written.Count-1;$index -ge 0;$index--){$item=$written[$index]
            try{
                $current=Read-RuleMaintenanceFile $item.Before.Path
                if($current.Hash -cne $item.AfterHash){$preserved++;continue}
                Set-RuleMaintenanceFile $current $item.Before.Bytes (-not $item.Before.Exists)
            }catch{$rollbackProblems+='本机记录或快捷方式'}
        }
        if($engineHash){
            try{
                $current=Read-RuleMaintenanceFile $Snapshot.Files['app-rules.json'].Path
                if($current.TextHash -ceq $engineHash){Invoke-AppRouter @{action='replace';entries=@($Snapshot.Engine.entries);defaultRoute=$Snapshot.Engine.defaultRoute;programIngresses=@($Snapshot.Engine.programIngresses|Where-Object {$_});siteRules=@($Snapshot.Engine.siteRules|Where-Object {$_});expectedStateHash=$engineHash;expectedSettingsHash=$Snapshot.Files['config.json'].TextHash}|Out-Null}else{$preserved++}
            }catch{$rollbackProblems+='引擎规则'}
        }
        $suffix='；已回滚仍归本次写入的内容。';if($preserved){$suffix+=' 已保留外部修改。'};if($rollbackProblems.Count){$suffix='；部分回滚未完成，请使用本机备份检查。'}
        throw ($message+$suffix+' 备份：'+$backup.Path)
    }
    $message=$(if($Remove){'已移除所选程序的保存记录，并恢复仍归本工具的原入口。'}else{'已修复程序路径，保留原目标线路与快捷方式备份。'})
    if($shortcutPlan.Preserved){$message+=' '+$shortcutPlan.Preserved+' 个快捷方式已由其他程序或用户修改，保持原样。'}
    if($shortcutPlan.RestoredUpdated){$message+=' 已将恢复的原入口指向此前确认的新版本；最初备份仍保留。'}
    if(-not $Remove -and $launchEntries.Count){$message+=' 当前运行会话未重启；请自行保存任务并完整退出后，使用修复后的代理入口重开。'}
    if($OfflinePlan){$message=$(if($Remove){'已取消此程序保存在已停止服务中的旧专线；Windows 系统代理保持原样。'}else{'已迁移此程序的保存路径与身份，原线路和固定入口保持；规则尚未载入。'});$message+=' 未启动服务、未重开软件、未改原生快捷方式；实际连接请另行核对。'}
    elseif(-not $Remove -and $engineEntries.Count){$message+=' 引擎规则已核对，新连接生效；已有连接未中断。'}
    [pscustomobject]@{Message=$message;Impact=$(if($OfflinePlan){$OfflinePlan.Impact}else{''});Backup=$backup.Path;PreservedShortcuts=$shortcutPlan.Preserved;RepairedPath=$CurrentPath;Removed=[bool]$Remove;EngineChanged=($engineEntries.Count -gt 0);LaunchChanged=($launchEntries.Count -gt 0);RulesLoaded=($engineEntries.Count -gt 0 -and -not $OfflinePlan);Execution=$(if($OfflinePlan){'saved-only'}else{'apply-live'})}
}
function Assert-RuleMaintenanceOfflineState($Snapshot,[string]$Fingerprint){
    $service=Get-RuleMaintenanceServiceObservation $Snapshot
    if($service.State -cne 'stopped' -or -not $Fingerprint -or $service.Fingerprint -cne $Fingerprint){throw '独立服务状态、入口连接或受保护记录已变化，未执行旧离线方案；请重新预览。'}
}
function Assert-RuleMaintenancePlan($Plan,$Fresh){
    $created=[DateTime]::MinValue
    if(-not $Plan -or $Plan.Version -notin @(1,2) -or [string]$Plan.DataDirectory -ine [IO.Path]::GetFullPath($script:DataRoot) -or -not [DateTime]::TryParse([string]$Plan.CreatedAt,[ref]$created) -or [DateTime]::UtcNow.Subtract($created.ToUniversalTime()).TotalSeconds -gt 120 -or $created.ToUniversalTime() -gt [DateTime]::UtcNow.AddSeconds(5)){throw '修复预览已过期或来自其他配置目录，请重新预览后确认。'}
    if($Fresh.SnapshotFingerprint -cne $Plan.SnapshotFingerprint -or $Fresh.IdentityFingerprint -cne $Plan.IdentityFingerprint -or $Fresh.CurrentPath -ine $Plan.CurrentPath -or $Fresh.Mode -ne $Plan.Mode -or ($Plan.Version -eq 2 -and ($Fresh.Action -cne $Plan.Action -or $Fresh.Execution -cne $Plan.Execution -or $Fresh.ServiceFingerprint -cne $Plan.ServiceFingerprint)) -or ($Fresh.Execution -eq 'saved-only' -and $Plan.Version -ne 2)){throw '程序身份、线路、执行范围或快捷方式已经变化，请重新预览后确认。'}
}
function Repair-ProgramRule($Plan){
    if($Plan.Execution -ceq 'saved-only'){
        if($Plan.Action -cne 'repair-path' -or $Plan.Version -ne 2){throw '请重新预览并确认明确的离线路径修复动作。'}
        return Invoke-AppRouter @{action='program-record-offline';plan=$Plan}
    }
    Use-ChangeLock {
        Assert-RuleMaintenancePlan $Plan $Plan
        $fresh=Get-ProgramRuleRepairPlan $Plan.SavedPath
        Assert-RuleMaintenancePlan $Plan $fresh
        $snapshot=Get-RuleMaintenanceSnapshot $fresh.SavedPath
        if($snapshot.Fingerprint -cne $fresh.SnapshotFingerprint){throw '保存记录已变化，请重新预览后确认。'}
        Invoke-RuleMaintenanceChange $snapshot $fresh.SavedPath $fresh.CurrentPath $fresh.Identity
    }
}
function Remove-ProgramOfflineRule($Plan,[switch]$Confirmed){
    if(-not $Confirmed -or $Plan.Version -ne 2 -or $Plan.Action -cne 'release-system' -or $Plan.Execution -cne 'saved-only'){throw '请先预览并明确确认仅取消已停止服务中的此程序专线。'}
    Invoke-AppRouter @{action='program-record-offline';plan=$Plan}
}
function Assert-RuleMaintenanceNodeLocks($Locks){
    $parent=@(Get-ProcessInventory -Id $PID|Select-Object -First 1)[0].ParentId
    foreach($name in @('start','mutation')){
        $expected=$Locks.$name;$actual=Read-RuleMaintenanceJson (Read-RuleMaintenanceFile (Join-Path $script:DataRoot ('gateway\'+$name+'.lock'))) $null
        if(-not $expected.token -or $actual.token -cne $expected.token -or $actual.pid -ne $expected.pid -or [string]$actual.startTicks -cne [string]$expected.startTicks -or $parent -ne $actual.pid -or (Get-RecoveryOwnerState ([pscustomobject]@{OwnerPID=$actual.pid;OwnerStart=$actual.startTicks})) -cne 'alive'){throw '离线操作未持有本次独立服务共享锁，未写入保存记录。'}
    }
}
function Invoke-ProgramOfflineRecordWorker($Plan,$Locks){
    Assert-RuleMaintenanceNodeLocks $Locks
    Use-ChangeLock {
        if($Plan.Version -ne 2 -or $Plan.Execution -cne 'saved-only' -or $Plan.Action -notin @('repair-path','release-system')){throw '离线记录动作不明确，请重新预览。'}
        Assert-RuleMaintenancePlan $Plan $Plan
        $fresh=if($Plan.Action -ceq 'release-system'){Get-ProgramOfflineReleasePlan $Plan.SavedPath}else{Get-ProgramRuleRepairPlan $Plan.SavedPath}
        Assert-RuleMaintenancePlan $Plan $fresh
        $snapshot=Get-RuleMaintenanceSnapshot $fresh.SavedPath
        if($snapshot.Fingerprint -cne $fresh.SnapshotFingerprint){throw '保存记录已变化，请重新预览后确认。'}
        Assert-RuleMaintenanceOfflineState $snapshot $fresh.ServiceFingerprint
        Invoke-RuleMaintenanceChange $snapshot $fresh.SavedPath $fresh.CurrentPath $fresh.Identity -Remove:($fresh.Action -ceq 'release-system') -OfflinePlan $fresh
    }
}
function Remove-SavedProgramRule([string]$SavedPath){
    Use-ChangeLock {
        $path=ConvertTo-ProgramIdentityPath $SavedPath;if(-not $path -or $path -notmatch '(?i)\.exe$'){throw '请选择有效的已保存程序记录。'}
        $snapshot=Get-RuleMaintenanceSnapshot $path
        if(-not @(@($snapshot.Engine.entries)+@($snapshot.Engine.programIngresses)+@($snapshot.Launch.entries)|Where-Object {$_.path -ieq $path}).Count){throw '该程序没有可移除的保存记录。'}
        Invoke-RuleMaintenanceChange $snapshot $path '' $null -Remove
    }
}
if($OfflineRepairWorker){
    try{
        $inputText=[Console]::In.ReadToEnd();if($inputText.Length -gt 32768){throw '离线预览过大，未修改记录。'}
        $offlineBoundRequest=$inputText|ConvertFrom-Json
        if(-not [IO.Path]::IsPathRooted([string]$offlineBoundRequest.Plan.DataDirectory)){throw '离线配置目录无效。'}
        . (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $offlineBoundRequest.Plan.DataDirectory
        $result=Invoke-ProgramOfflineRecordWorker $offlineBoundRequest.Plan $offlineBoundRequest.Locks
        [Console]::Out.Write(($result|ConvertTo-Json -Depth 8 -Compress))
    }catch{[Console]::Out.Write((@{ok=$false;error=$_.Exception.Message}|ConvertTo-Json -Compress));exit 1}
}

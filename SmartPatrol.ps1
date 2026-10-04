# Six passive checks; explicit repair uses the shared revision/ownership transaction.
param([switch]$Fix,[switch]$Yes,[switch]$MachineOnly,[string]$DataDirectory='',[switch]$Library,[switch]$KeepOpen)
$ErrorActionPreference='Stop'
function Get-SmartPatrolLaunchPlan([string]$DataDirectory,[string]$ScriptPath=(Join-Path $PSScriptRoot 'SmartPatrol.ps1')) {
    $path=[IO.Path]::GetFullPath($ScriptPath);$data=[IO.Path]::GetFullPath($DataDirectory)
    if($path.Contains('"') -or $data.Contains('"')){throw 'Invalid launch path'}
    [pscustomobject]@{FilePath=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=('-NoProfile -NoExit -ExecutionPolicy Bypass -File "'+$path+'" -DataDirectory "'+$data+'" -KeepOpen');WorkingDirectory=[IO.Path]::GetDirectoryName($path)}
}
function Start-SmartPatrolConsole([string]$DataDirectory,[string]$ScriptPath=(Join-Path $PSScriptRoot 'SmartPatrol.ps1')) {
    if(-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)){throw '未找到智能体检脚本，请使用完整程序包。'}
    $plan=Get-SmartPatrolLaunchPlan $DataDirectory $ScriptPath
    [void](Start-Process -FilePath $plan.FilePath -ArgumentList $plan.Arguments -WorkingDirectory $plan.WorkingDirectory)
}
function Get-SmartPatrolMachineValue([string]$Name) {[Environment]::GetEnvironmentVariable($Name,'Machine')}
function Get-SmartPatrolValueState([string]$Value,$Tcp) {
    if([string]::IsNullOrWhiteSpace($Value)){return 'Unset'}
    $observed=Get-LocalEndpointObservation $Value $Tcp
    if(-not $observed -or $null -eq $observed.Ready){return 'Unknown'}
    if($observed.Ready -eq $true){return 'Listening'}
    'Dead'
}
function Get-SmartPatrolHostsState {
    $path=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    try {
        $item=Get-Item -LiteralPath $path -ErrorAction Stop
        if($item.Length -gt 256KB){return [pscustomobject]@{State='Unknown';Mappings=0}}
        $lines=[IO.File]::ReadAllLines($path)
        $count=@($lines|Where-Object {$_ -match '^\s*[^#\s]+\s+[^#\s]+'}).Count
        [pscustomobject]@{State='Observed';Mappings=$count}
    }catch{[pscustomobject]@{State='Unknown';Mappings=0}}
}
function Get-SmartPatrolReport {
    $diagnosis=Get-NetworkDiagnosis;$tcp=Get-TcpObservationSnapshot
    $users=Get-UserProxyEnv;$machineAvailable=$true;$rows=@()
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) {
        $rows+=[pscustomobject]@{Scope='User';Name=$name;State=(Get-SmartPatrolValueState ([string]$users.$name) $tcp)}
        try{$value=Get-SmartPatrolMachineValue $name;$state=Get-SmartPatrolValueState $value $tcp}
        catch{$machineAvailable=$false;$state='Unknown'}
        $rows+=[pscustomobject]@{Scope='Machine';Name=$name;State=$state}
    }
    $system=Get-SystemSnapshot
    $bypass=@(([string]$system.Bypass -split ';')|Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    [pscustomobject]@{Version=$script:ProductVersion;CapturedAt=[DateTimeOffset]::UtcNow.ToString('o');Diagnosis=$diagnosis;Environment=@($rows);MachineAvailable=$machineAvailable;SystemSetting=$(if($system.Flags -band 2){'ProxyConfigured'}else{'ManualProxyOff'});BypassEntries=$bypass.Count;Hosts=(Get-SmartPatrolHostsState);EndpointCount=@($diagnosis.Endpoints).Count;Topology=(Get-NetworkTopologyObservation)}
}
function Get-SmartPatrolSummary($Report,[bool]$Repaired=$false) {
    # Exclude raw diagnostics, endpoint values, IPs and paths from persistence.
    [pscustomobject]@{schema=1;version=$Report.Version;checkedAt=$Report.CapturedAt;repaired=$Repaired;checks=6;environment=@($Report.Environment|Select-Object Scope,Name,State);machineAvailable=[bool]$Report.MachineAvailable;systemSetting=$Report.SystemSetting;bypassEntries=[int]$Report.BypassEntries;hostsState=$Report.Hosts.State;hostsMappings=[int]$Report.Hosts.Mappings;endpointCount=[int]$Report.EndpointCount;topologyState=$Report.Topology.State;ipv4=$Report.Topology.IPv4;ipv6=$Report.Topology.IPv6;issueCount=@($Report.Diagnosis.Issues).Count;repairAvailable=[bool]$Report.Diagnosis.RepairAction;authenticationVerified=$false}
}
function Save-SmartPatrolReport($Report,[bool]$Repaired=$false) {
    $directory=Join-Path $script:DataRoot 'patrol';[void][IO.Directory]::CreateDirectory($directory)
    $path=Join-Path $directory 'patrol-latest.json'
    Write-LocalJson $path (Get-SmartPatrolSummary $Report $Repaired)
    $path
}
function Format-SmartPatrolReport($Report) {
    $lines=@('流向智能体检：六类本地检查（未发送外部探测）','1. 代理环境变量（机器级仅只读）：')
    foreach($row in $Report.Environment){$lines+=('   '+$row.Scope+' / '+$row.Name+'：'+$row.State)}
    $lines+=('2. 系统手动代理设置：'+$Report.SystemSetting+'；关闭不等于物理网络直连。')
    $lines+=('3. 系统绕过条目：'+$Report.BypassEntries+'；保留现有条目，不补通用游戏域名。')
    $lines+=('4. hosts 文件：'+$Report.Hosts.State+'；映射记录 '+$Report.Hosts.Mappings+'，不验证其正确性，不写入。')
    $lines+=('5. 已配置入口：'+$Report.EndpointCount+'；监听不代表目标可达或应用已接入。')
    $lines+=('6. 双栈隧道路由证据：'+$Report.Topology.State+'（IPv4 '+$Report.Topology.IPv4+' / IPv6 '+$Report.Topology.IPv6+'）。未见证据不等于 TUN 已关闭。')
    $lines+='Unknown 包含读取失败、远程或复杂入口；不会按死亡入口处理。机器级残留需人工核对原设置来源，不自动提权。'
    $lines+='未验收真实 IP、Codex/OAuth、游戏或登录结果；已运行程序可能仍需保存工作后正常重开。'
    if($Report.Diagnosis.RepairAction){$lines+=('共享网络检查提供可处理项：'+$Report.Diagnosis.RepairText)}
    else{$lines+='当前没有共享检查允许的自动修复；未知状态保留。到「连接检查」查看具体建议。'}
    $lines -join [Environment]::NewLine
}
function Invoke-SmartPatrolRepair($Report,[switch]$Confirmed) {
    if(-not $Confirmed){throw '未确认修复。'}
    $at=[DateTimeOffset]::Parse($Report.CapturedAt);$age=([DateTimeOffset]::UtcNow-$at).TotalSeconds
    if($age -lt 0 -or $age -gt 120){throw '修复预览已过期，请重新体检。'}
    $allowed=@('repair-dead-entry','clear-dead-environment','recover-session','recover-stopped-service','align-environment')
    $before=$Report.Diagnosis
    if(-not $before.Revision -or $before.RepairAction -notin $allowed){throw '没有可处理的修复计划。'}
    $fresh=Get-NetworkDiagnosis
    if($fresh.Revision -cne $before.Revision -or $fresh.RepairAction -cne $before.RepairAction){throw '网络配置或修复计划已变化，请重新体检。'}
    Repair-NetworkDiagnosis -Revision $before.Revision -ExpectedAction $before.RepairAction
}
function Invoke-SmartPatrolCommand([switch]$Fix,[switch]$Yes) {
    $committed=$false
    try {
        $report=Get-SmartPatrolReport;Write-Host (Format-SmartPatrolReport $report);$null=Save-SmartPatrolReport $report
        if($Fix -and $report.Diagnosis.RepairAction) {
            if(-not $Yes -and (Read-Host '仅执行上述共享修复；保持机器变量、hosts、游戏绕过和第三方 TUN。确认请输入 Y') -cnotin @('Y','y')){Write-Host '已取消，网络设置未修改。';return 0}
            $null=Invoke-SmartPatrolRepair $report -Confirmed;$committed=$true
            $after=Get-SmartPatrolReport;$null=Save-SmartPatrolReport $after $true
            Write-Host '共享修复已完成并复检；真实应用登录仍需验证。';Write-Host (Format-SmartPatrolReport $after)
        } elseif(-not $Fix) {Write-Host '默认只读。需要处理时到「检查与维护 → 连接检查 → 修复配置」，或显式运行智能体检.cmd -Fix。'}
        return 0
    }catch{
        if($committed){Write-Host '共享修复已提交，但后续复检或摘要保存失败；请重新排查，不要重复执行旧计划。';return 0}
        Write-Host '体检或修复未完成，请重新检查配置与系统证据；没有把失败或未知报告为联网成功。';return 1
    }
}
if($Library){return}
if($MachineOnly){Write-Host '机器级变量仅支持只读检查，不执行提权清理。';exit 2}
try {
    # Pass the original choice so Preferences can preserve default legacy migration.
    . (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $DataDirectory
    $code=Invoke-SmartPatrolCommand -Fix:$Fix -Yes:$Yes
}catch{Write-Host '配置初始化失败，体检未执行。';$code=1}
if($KeepOpen){[Environment]::ExitCode=$code;return}
exit $code

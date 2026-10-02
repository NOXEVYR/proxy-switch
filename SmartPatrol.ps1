# FlowSwitch SmartPatrol - 智能体检与分级修复 (v1, 2026-10-02)
# 独立巡检脚本：只读为默认；-Fix 才允许修复，修复前完整备份。
# 覆盖 NetworkDiagnostics.ps1 未覆盖的盲区：机器级环境变量、游戏域名 bypass、
# hosts/IP 回显联动。遵循流向原则：监听状态未知不动作、外部客户端只告警不对抗。
param(
    [switch]$Fix,          # 允许修复
    [switch]$Yes,          # 跳过交互确认（自动化用）
    [switch]$MachineOnly   # 内部：提权子进程只清理机器级死变量
)
$ErrorActionPreference='Stop'

$PatrolDir = Join-Path $env:USERPROFILE '.proxyswitch\patrol'
$PatrolLog = $null
$ProxyVarNames = @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')
$InternetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

# 已知端口归属指纹（用于报告归属，不据此对抗）
$KnownPorts = @{
    7897='Clash Verge (verge-mihomo)'; 9097='Clash 控制端口'; 57777='365VPN';
    7892='chaoshihui'; 29757='Upnet SOCKS5'; 29758='Upnet HTTP'; 58800='临时探针(历史)';
    18790='流向网关独立入口'; 19080='流向程序入口(Antigravity)'; 19081='流向程序入口(Codex)'; 19082='流向程序入口(卡拉彼丘)'
}
# 内网基础 bypass（恒保，缺失会被修复动作重建）
$BaseBypass = @('localhost','127.*','192.168.*','10.*','172.16.*','172.17.*','172.18.*','172.19.*','172.20.*','172.21.*','172.22.*','172.23.*','172.24.*','172.25.*','172.26.*','172.27.*','172.28.*','172.29.*','172.30.*','172.31.*')
# 游戏 + IP 探测域名 bypass（2026-10-02 00:55 验证版）
$RequiredBypass = @(
    '*.gxpan.cn','*.idreamsky.com','*.qq.com','*.qlogo.cn','*.qpic.cn','*.gtimg.cn','*.gtimg.com',
    '*.myqcloud.com','*.tencent.com','*.tencent-cloud.com','*.dnsv1.com','*.anticheatexpert.com',
    '*.anticheatexpert.cn','*.uu.cc','*.dnse1.com','*.alicloudapi.com','*.aliyunga0017.com',
    'api.ipify.org','api64.ipify.org','www.ipify.org','ipify.org','ifconfig.me','icanhazip.com','checkip.amazonaws.com'
)

function Write-Patrol([string]$Line){ Write-Host $Line; if($PatrolLog){ Add-Content -LiteralPath $PatrolLog -Value $Line -Encoding UTF8 } }

function Get-ListenPorts {
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    try { Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object { [void]$set.Add([int]$_.LocalPort) } } catch {}
    return $set
}

function ConvertTo-Endpoint([string]$Value) {
    # 返回 $null（无法解析）或 @{Host;Port;Local}
    if([string]::IsNullOrWhiteSpace($Value)){ return $null }
    $v = $Value.Trim()
    $scheme = $null
    foreach($s in @('http://','https://','socks5://','socks://')){ if($v.StartsWith($s)){ $scheme=$s; $v=$v.Substring($s.Length); break } }
    $idx = $v.LastIndexOf(':')
    if($idx -lt 0){ return $null }
    $epHost = $v.Substring(0,$idx); $portText = $v.Substring($idx+1)
    $cut = $epHost.IndexOf('/')
    if($cut -ge 0){ $epHost = $epHost.Substring(0,$cut) }
    $port = 0
    if(-not [int]::TryParse($portText,[ref]$port) -or $port -le 0 -or $port -gt 65535){ return $null }
    $local = ($epHost -eq '127.0.0.1' -or $epHost -eq 'localhost' -or $epHost -eq '::1')
    return @{Host=$epHost;Port=$port;Local=$local;Scheme=$scheme}
}

# tri-state 判定：Alive / Dead / Unknown / Remote。本地端口无监听才判 Dead。
function Test-ProxyValue([string]$Value,$ListenPorts) {
    $ep = ConvertTo-Endpoint $Value
    if($null -eq $ep){ return @{State='Unknown';Detail='无法解析'} }
    if(-not $ep.Local){ return @{State='Remote';Detail=("远程 {0}:{1}" -f $ep.Host,$ep.Port)} }
    if($ListenPorts.Count -eq 0){ return @{State='Unknown';Detail='监听快照不可用'} }
    if($ListenPorts.Contains($ep.Port)){ return @{State='Alive';Detail=("本地 :{0} 有监听" -f $ep.Port)} }
    return @{State='Dead';Detail=("本地 :{0} 无监听" -f $ep.Port)}
}

function Get-PortOwner([int]$Port){
    if($KnownPorts.ContainsKey($Port)){ return $KnownPorts[$Port] }
    return "未识别(端口 $Port)"
}

function Get-EnvScan($ListenPorts) {
    $rows = @()
    foreach($level in @('User','Machine')){
        foreach($name in $ProxyVarNames){
            $val = [Environment]::GetEnvironmentVariable($name,$level)
            if([string]::IsNullOrEmpty($val)){ continue }
            $t = Test-ProxyValue $val $ListenPorts
            $rows += [pscustomobject]@{Level=$level;Name=$name;Value=$val;State=$t.State;Detail=$t.Detail}
        }
    }
    return $rows
}

function Get-WinINetSnapshot {
    $snap = @{Enable=$false;Server='';Override=''}
    try {
        $k = Get-ItemProperty -LiteralPath $InternetKey -ErrorAction Stop
        $snap.Enable = ($k.ProxyEnable -eq 1)
        $snap.Server = [string]$k.ProxyServer
        $snap.Override = [string]$k.ProxyOverride
    } catch { $snap.Enable = $null }
    return $snap
}

function Test-BypassCoverage([string]$Override){
    $have = @()
    if(-not [string]::IsNullOrWhiteSpace($Override)){
        $have = $Override.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    $missing = @($RequiredBypass | Where-Object { $d = $_; -not ($have | Where-Object { $_ -eq $d -or $_.TrimStart('*') -eq $d.TrimStart('*') }) })
    return @{Have=$have;Missing=$missing}
}

function Test-LocalIpEcho {
    $hostsOk = $false
    try {
        $hostsText = [IO.File]::ReadAllText("$env:SystemRoot\System32\drivers\etc\hosts")
        $hostsOk = ($hostsText -match '127\.0\.0\.1\s+api\.ipify\.org')
    } catch {}
    $echoIp = $null
    try {
        $resp = Invoke-WebRequest -Uri 'http://127.0.0.1/' -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        $ip = $resp.Content.Trim()
        if($ip -match '^\d{1,3}(\.\d{1,3}){3}$'){ $echoIp = $ip }
    } catch {}
    return @{HostsOk=$hostsOk;EchoIp=$echoIp}
}

function Test-TunnelTakeover {
    # TUN 接管检测：存在 Up 状态的隧道网卡或 fake-ip(198.18.0.0/15) 路由即判定。
    # TUN 一开，WinINET bypass 与 hosts 劫持在网络层全部失效（2026-10-02 实证）。
    try {
        $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Meta|Mihomo|Clash|wintun|TAP|TUN' }
        if($adapters){ return @{On=$true;Detail=($adapters | ForEach-Object { $_.Name }) -join ','} }
        $routes = Get-NetRoute -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -like '198.18.*' -or $_.DestinationPrefix -like '198.19.*' }
        if($routes){ return @{On=$true;Detail='fake-ip 路由存在'} }
    } catch {}
    return @{On=$false;Detail=''}
}

function Test-ProbeConsistency {
    # 模拟游戏 IP 探测：经系统默认路径(WinINET+TUN)请求 http://api.ipify.org。
    # hosts 优先于一切 DNS 劫持 → 127.0.0.1:80 → ip_echo；返回真实 IP 即整链一致。
    try {
        $r = Invoke-WebRequest -Uri 'http://api.ipify.org' -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop
        $ip = $r.Content.Trim()
        if($ip -match '^\d{1,3}(\.\d{1,3}){3}$'){ return $ip }
    } catch {}
    return $null
}

function Get-PatrolReport {
    $listen = Get-ListenPorts
    $envRows = Get-EnvScan $listen
    $win = Get-WinINetSnapshot
    $bypass = Test-BypassCoverage $win.Override
    $ipEcho = Test-LocalIpEcho
    $gatewayAlive = $listen.Contains(18790)
    $tun = Test-TunnelTakeover
    $probeIp = Test-ProbeConsistency
    return @{Listen=$listen;Env=$envRows;Win=$win;Bypass=$bypass;IpEcho=$ipEcho;GatewayAlive=$gatewayAlive;Tun=$tun;ProbeIp=$probeIp}
}

function Save-PatrolBackup([object]$Payload){
    if(-not (Test-Path -LiteralPath $PatrolDir)){ New-Item -ItemType Directory -Path $PatrolDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $PatrolDir "backup-$stamp.json"
    $Payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

Add-Type -Namespace Patrol -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
[DllImport("wininet.dll", SetLastError=true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@

# 广播环境变量变更，让 explorer 之后启动的新进程拿到新环境（不广播则删除不生效于新程序）
function Broadcast-EnvChange {
    $result = [UIntPtr]::Zero
    [void][Patrol.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}

# 通知 WinINET 设置已变更（否则已运行的应用不重读代理设置）
function Refresh-WinINet {
    [void][Patrol.Native]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)  # INTERNET_OPTION_SETTINGS_CHANGED
    [void][Patrol.Native]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)  # INTERNET_OPTION_REFRESH
}

function Show-Report($Report){
    Write-Patrol ''
    Write-Patrol '================ 流向智能体检报告 ================'
    # 1. 环境变量
    if($Report.Env.Count -eq 0){
        Write-Patrol '  [正常] 代理环境变量（用户级+机器级）：无残留'
    } else {
        Write-Patrol '  代理环境变量扫描（用户级 + 机器级）：'
        foreach($row in $Report.Env){
            $tag = switch($row.State){
                'Dead'   {'[危险]'; break}
                'Alive'  {'[正常]'; break}
                default  {'[未知]'; break}
            }
            $lv = if($row.Level -eq 'User'){'用户级'}else{'机器级'}
            Write-Patrol ("    {0} {1} {2} = {3}  ({4})" -f $tag,$lv,$row.Name,$row.Value,$row.Detail)
        }
    }
    # 2. 系统代理
    if($null -eq $Report.Win.Enable){ Write-Patrol '  [未知] 系统代理设置读取失败'
    } elseif(-not $Report.Win.Enable){ Write-Patrol '  [正常] 系统代理：关闭（直连）'
    } else {
        $ep = ConvertTo-Endpoint $Report.Win.Server
        if($null -ne $ep -and $ep.Local){
            $alive = $Report.Listen.Contains($ep.Port)
            $tag = if($alive){'[正常]'}else{'[危险]'}
            Write-Patrol ("  {0} 系统代理：开启 -> {1}（归属：{2}）" -f $tag,$Report.Win.Server,(Get-PortOwner $ep.Port))
        } else {
            Write-Patrol ("  [未知] 系统代理：开启 -> {0}" -f $Report.Win.Server)
        }
    }
    # 3. 游戏 bypass
    if($Report.Bypass.Missing.Count -eq 0){ Write-Patrol '  [正常] 游戏/IP 探测域名 bypass：已覆盖'
    } else {
        Write-Patrol ("  [建议] 系统 bypass 缺少 {0} 条游戏/探测域名（如 {1}...）" -f $Report.Bypass.Missing.Count,$Report.Bypass.Missing[0])
    }
    # 4. hosts + ip_echo
    if($Report.IpEcho.HostsOk -and $Report.IpEcho.EchoIp){
        Write-Patrol ("  [正常] IP 一致性地基：hosts 劫持在位，本地回显真实 IP {0}" -f $Report.IpEcho.EchoIp)
    } elseif(-not $Report.IpEcho.HostsOk){ Write-Patrol '  [建议] hosts 未劫持 IP 探测域名（游戏 IP 一致性无保障）'
    } else { Write-Patrol '  [建议] hosts 已劫持但本地回显服务(127.0.0.1:80)未响应' }
    # 5. 流向网关
    if($Report.GatewayAlive){ Write-Patrol '  [正常] 流向网关独立入口 18790：监听中'
    } else { Write-Patrol '  [未知] 流向网关独立入口 18790：未监听（网关未开或已停止）' }
    # 6. TUN 接管 × 游戏 IP 探测一致性（2026-10-02 终局认知：
    #    TUN 是 Codex 后端出海的生命线（其 OAuth 绕过系统代理，仅 TUN 能接管，含 IPv6）；
    #    游戏安全由 hosts(优先于 TUN 的 DNS 劫持) + 代理端国内直连规则保障。二者共存。）
    if($Report.Tun.On -and $Report.ProbeIp){
        Write-Patrol ("  [正常] TUN 接管中（{0}，Codex 出海拓扑在位）；游戏探测链路返回真实 IP {1}，共存正常" -f $Report.Tun.Detail,$Report.ProbeIp)
    } elseif($Report.Tun.On){
        Write-Patrol ("  [危险] TUN 接管中（{0}）且游戏 IP 探测拿不到真实 IP——hosts 劫持或本地回显失效，游戏登录有风控风险" -f $Report.Tun.Detail)
    } elseif($Report.ProbeIp){
        Write-Patrol ("  [正常] TUN 未接管（游戏全直连安全）；注意 Codex OAuth 此状态下可能遭地区拒绝，需要时再开 Clash Tun" )
    } else {
        Write-Patrol '  [危险] TUN 未接管且游戏 IP 探测拿不到真实 IP，请核对 hosts 与本地回显服务(127.0.0.1:80)'
    }
    Write-Patrol '=================================================='
}

# ---------- 提权子流程：只清机器级死变量 ----------
if($MachineOnly){
    if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        Write-Host '需要管理员权限'; exit 2
    }
    $listen = Get-ListenPorts
    $removed = @()
    foreach($name in $ProxyVarNames){
        $val = [Environment]::GetEnvironmentVariable($name,'Machine')
        if([string]::IsNullOrEmpty($val)){ continue }
        $t = Test-ProxyValue $val $listen
        if($t.State -eq 'Dead'){
            $removed += @{Name=$name;Value=$val}
            [Environment]::SetEnvironmentVariable($name,$null,'Machine')
        }
    }
    $out = Join-Path $PatrolDir 'machine-clean-result.json'
    @{Removed=$removed} | ConvertTo-Json | Set-Content -LiteralPath $out -Encoding UTF8
    exit 0
}

# ---------- 主流程 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not (Test-Path -LiteralPath $PatrolDir)){ New-Item -ItemType Directory -Path $PatrolDir -Force | Out-Null }
$PatrolLog = Join-Path $PatrolDir ('patrol-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

$Report = Get-PatrolReport
Show-Report $Report

$deadUser   = @($Report.Env | Where-Object { $_.State -eq 'Dead' -and $_.Level -eq 'User' })
$deadMachine= @($Report.Env | Where-Object { $_.State -eq 'Dead' -and $_.Level -eq 'Machine' })
$needBypass = ($Report.Bypass.Missing.Count -gt 0)

if(-not $Fix){
    if($deadUser.Count -or $deadMachine.Count -or $needBypass){
        Write-Patrol ''
        Write-Patrol '发现可修复项。修复方式：双击「智能体检.cmd」（推荐，自动请求所需权限），'
        Write-Patrol '或运行: powershell -ExecutionPolicy Bypass -File app\SmartPatrol.ps1 -Fix'
    } else {
        Write-Patrol ''
        Write-Patrol '未发现需修复项。'
    }
    exit 0
}

# ---------- 修复 ----------
$plan = @()
if($deadUser.Count){ $plan += ("删除用户级死代理变量 x{0}（{1}）" -f $deadUser.Count,(($deadUser | ForEach-Object {$_.Name+':'+$_.Value}) -join '、')) }
if($deadMachine.Count){ $plan += ("删除机器级死代理变量 x{0}（{1}）" -f $deadMachine.Count,(($deadMachine | ForEach-Object {$_.Name+':'+$_.Value}) -join '、')) }
if($needBypass){ $plan += ("系统 bypass 补入游戏/IP 探测域名 x{0} 条" -f $Report.Bypass.Missing.Count) }

if($plan.Count -eq 0){ Write-Patrol ''; Write-Patrol '没有可自动修复的项（外部客户端/未知状态不动，见上方标记）。'; exit 0 }

Write-Patrol ''
Write-Patrol '修复计划：'
foreach($p in $plan){ Write-Patrol ("  - " + $p) }
if(-not $Yes){
    $ans = Read-Host '确认执行修复？输入 Y 继续'
    if($ans -notmatch '^[Yy]'){ Write-Patrol '已取消。'; exit 0 }
}

# 备份所有将被修改的值
$backup = @{ Time=(Get-Date -Format 's'); UserEnv=@{}; MachineEnv=@{}; ProxyOverride=$Report.Win.Override }
foreach($deadRow in $deadUser){ $backup.UserEnv[$deadRow.Name] = $deadRow.Value }
foreach($deadRow in $deadMachine){ $backup.MachineEnv[$deadRow.Name] = $deadRow.Value }
$bkPath = Save-PatrolBackup $backup
Write-Patrol ("已备份 -> {0}" -f $bkPath)

# L1：用户级死变量
foreach($deadRow in $deadUser){
    [Environment]::SetEnvironmentVariable($deadRow.Name,$null,'User')
    Write-Patrol ("已删除 用户级 {0}（原值 {1}）" -f $deadRow.Name,$deadRow.Value)
}

# L1：机器级死变量（必要时弹 UAC 子进程）
if($deadMachine.Count){
    if($isAdmin){
        foreach($mRow in $deadMachine){
            [Environment]::SetEnvironmentVariable($mRow.Name,$null,'Machine')
            Write-Patrol ("已删除 机器级 {0}（原值 {1}）" -f $mRow.Name,$mRow.Value)
        }
    } else {
        Write-Patrol '机器级变量需要管理员权限，正在请求（请在弹出的 UAC 窗口点“是”）...'
        $script = $PSCommandPath
        $p = Start-Process powershell -Verb RunAs -PassThru -Wait -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script`"",'-MachineOnly','-Yes')
        $resPath = Join-Path $PatrolDir 'machine-clean-result.json'
        if((Test-Path -LiteralPath $resPath) -and $p.ExitCode -eq 0){
            $res = Get-Content -LiteralPath $resPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach($m in $res.Removed){ Write-Patrol ("已删除 机器级 {0}（原值 {1}）" -f $m.Name,$m.Value) }
            Remove-Item -LiteralPath $resPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-Patrol ('机器级清理未完成（退出码 {0}），可稍后以管理员身份重跑。' -f $p.ExitCode)
        }
    }
}

# 广播环境变更：关键步骤，否则 explorer 启动的新程序仍继承旧变量
Broadcast-EnvChange
Write-Patrol '已广播环境变更（新启动的程序将不再继承被删除的变量）'

# L2：补游戏 bypass（基础内网段恒保，避免从空值恢复时丢失）
if($needBypass){
    $keep = @($Report.Bypass.Have | Where-Object { $_ -ne '<local>' })
    $merged = @($BaseBypass + $RequiredBypass + $keep | Select-Object -Unique)
    $merged += '<local>'
    $newOverride = ($merged -join ';')
    Set-ItemProperty -LiteralPath $InternetKey -Name ProxyOverride -Value $newOverride
    Refresh-WinINet
    Write-Patrol ("已重建 bypass：基础内网 {0} + 游戏/探测 {1} 条（现共 {2} 条），并刷新 WinINET" -f $BaseBypass.Count,$RequiredBypass.Count,$merged.Count)
}

# 复检
Write-Patrol ''
Write-Patrol '>> 修复后复检：'
$Report2 = Get-PatrolReport
Show-Report $Report2
@{ Time=(Get-Date -Format 's'); Plan=$plan; Backup=$bkPath; Before=@{DeadUser=$deadUser.Count;DeadMachine=$deadMachine.Count}; After=@{EnvRows=$Report2.Env.Count;BypassMissing=$Report2.Bypass.Missing.Count} } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PatrolDir 'patrol-latest.json') -Encoding UTF8
Write-Patrol ''
Write-Patrol '完成。建议：重新打开游戏验证登录（已运行的游戏/浏览器需重开才会读到新设置）。'
